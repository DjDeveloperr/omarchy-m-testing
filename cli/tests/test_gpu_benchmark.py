"""Synthetic host/protocol fixtures only; none is a GPU runtime measurement."""
import copy
import gzip
import json
from pathlib import Path
import unittest
import tempfile
import subprocess
import importlib.util
from omarchy_m_test import signing
from omarchy_m_test.host import RealHost

from omarchy_m_test import gpu_benchmark as gpu, gpu_schema, bundled
from omarchy_m_test.app import main
from omarchy_m_test.host import CommandResult, SigningError

SCHEMA=json.loads(bundled.gpu_document_schema())
HASH='1'*64
GPU='Apple M3 Pro (G15S C1)'
HEALTH={'temperatures_mc':[45000],'cpu_frequency_khz':[1800000],'devfreq_hz':[618000000],
        'ac':'online','memory_total_bytes':16*1024**3,'memory_available_bytes':12*1024**3}

def probe(work='compute',negative=False,timestamps=True):
    """Invented protocol values, never labelled as recorded hardware evidence."""
    result={'status':'pass','reason':'negative-control-detected' if negative else 'completed',
      'identity':{'protocol':1,'suite':1,'device_name':GPU,'vendor_id':0x10005,'device_id':6030,'device_type':1,
        'driver_id':26,'api_version':4206592,'driver_version':1,'timestamp_bits':64 if timestamps else 0,
        'timestamp_period_ps':1000,'source_sha256':HASH},
      'result':{'mismatches':1 if negative else 0,'width':1920 if work in ('raster','texture') else 0,
        'height':1080 if work in ('raster','texture') else 0,
        'operations':gpu.OPERATIONS[work]//gpu.QUERIES[work] if negative else gpu.OPERATIONS[work],
        'record_ns':1000,'submit_wait_ns':10000,'thread_cpu_ns':2000,'gpu_timestamp_ns':5000 if timestamps else 0,
        'gpu_timestamp_queries':(1 if negative else gpu.QUERIES[work]) if timestamps else 0,
        'gpu_timestamp_status':'supported' if timestamps else 'unsupported','bo_lifetime_ns':20000 if work=='bo-lifetime' else 0,
        'owned_bytes_peak':64*1024**2 if work=='copy' else 1024**2},
      'helper_sha256':HASH,'driver_libraries':[{'role':'implementation','sha256':HASH,'system_provider':True}],
      'before':HEALTH,'after':HEALTH,'samples':[HEALTH],'kernel_fault_log_available':True}
    return copy.deepcopy(result)

class Mac:
    def __init__(self,answer='y',fault=None):
        self.answer=answer;self.fault=fault;self.calls=[];self.written={};self.output=[];self.posts=[];self.signs=[];self.private=[]
    def run(self,args):
        self.calls.append(list(args))
        if args==['uname','-m']:return CommandResult(0,'aarch64\n','')
        if args==['uname','-r']:return CommandResult(0,'7.2.11-fixture\n','')
        if args==gpu.PACKAGE_QUERY:return CommandResult(0,'mesa-aurora 1:26.3.0-1\nvulkan-aurora 1:26.3.0-1\n','')
        raise AssertionError('unexpected operation: '+str(args))
    def read_file(self,path):
        data={'/proc/device-tree/model':b'Apple MacBook Pro (16-inch, M3 Pro, 2023)\0',
              '/proc/device-tree/compatible':b'apple,j516s\0apple,t6030\0apple,arm-platform\0',
              '/proc/config.gz':gzip.compress(b'CONFIG_DRM_ASAHI=y\n'),'/etc/hostname':b'private-owner-laptop\n'}
        if path not in data:raise FileNotFoundError(path)
        return data[path]
    def list_dir(self,path):
        if path=='/home':return ['private-owner']
        raise FileNotFoundError(path)
    def run_bundled(self,name,args):
        self.calls.append(['bundled:'+name,*args]);assert name=='gpu-benchmark'
        if args==['snapshot']:return CommandResult(0,json.dumps({'status':'pass','snapshot':HEALTH}),'')
        result=probe(args[0],len(args)==2)
        if self.fault:result=self.fault(result,args)
        return CommandResult(0,json.dumps(result),'')
    def prompt(self,_):return self.answer
    def env(self,key):return '/home/private-owner' if key=='HOME' else None
    def show(self,s):self.output.append(s)
    def sleep(self,_):pass
    def write_file(self,path,text,private=False):self.written[path]=text;self.private.append(private)
    def machine_sign(self,key_path,namespace,message):
        self.signs.append((namespace,message))
        raise SigningError('deliberately absent fixture key /home/private-owner/10.0.0.7')

class ProtocolTests(unittest.TestCase):
    def test_full_success_and_exact_dimensions(self):
        self.assertEqual(gpu.parse_run(json.dumps(probe('raster')),'raster')['status'],'pass')
        bad=probe('raster');bad['result']['width']=1919
        self.assertEqual(gpu.parse_run(json.dumps(bad),'raster')['status'],'fail')
    def test_wrong_pixels_software_and_mixed_provider_cannot_pass(self):
        mutations=[lambda p:p['result'].update(mismatches=1),lambda p:p['identity'].update(device_name='llvmpipe'),
                   lambda p:p['driver_libraries'][0].update(system_provider=False)]
        for mutate in mutations:
            p=probe();mutate(p);self.assertEqual(gpu.parse_run(json.dumps(p),'compute')['status'],'fail')
    def test_mesa_honeykrisp_native_identity_is_a_required_pair(self):
        self.assertEqual(gpu.parse_run(json.dumps(probe()),'compute')['status'],'pass')
        # No PCI-vendor override or arbitrary Mesa/software/MoltenVK admission.
        for update in ({'vendor_id':0x106b},{'vendor_id':0x1002},{'driver_id':14},
                       {'driver_id':13},{'device_type':4},{'device_type':2},{'device_type':3},{'api_version':4194304},
                       {'device_name':'llvmpipe'},{'device_name':'Apple M1 translated'}):
            p=probe();p['identity'].update(update)
            self.assertEqual(gpu.parse_run(json.dumps(p),'compute')['status'],'fail',update)

    def test_unequal_dispatch_work_is_rejected(self):
        p=probe('submit-batched');p['result']['operations']=4096
        self.assertEqual(gpu.parse_run(json.dumps(p),'submit-batched')['status'],'fail')
        self.assertEqual(gpu.OPERATIONS['submit-batched'],gpu.OPERATIONS['submit-single'])
    def test_unsupported_gpu_time_is_absent_not_cpu_time_or_zero(self):
        run=gpu.parse_run(json.dumps(probe(timestamps=False)),'compute')
        self.assertEqual(run['status'],'pass');self.assertNotIn('gpu_timestamp_ns',run['measurements'])
        metric=next(x for x in gpu.metrics_for([{'phase':'measured',**run}]) if x['id']=='gpu_timestamp_ns')
        self.assertEqual(metric['status'],'unsupported');self.assertEqual(metric['statistics'],{})
    def test_missing_availability_or_float_timing_cannot_pass(self):
        for field,value in [('gpu_timestamp_queries',0),('record_ns',1.5)]:
            p=probe();p['result'][field]=value
            self.assertEqual(gpu.parse_run(json.dumps(p),'compute')['status'],'fail')
    def test_negative_control_requires_exact_single_mismatch(self):
        p=probe(negative=True);self.assertEqual(gpu.parse_run(json.dumps(p),'compute',True)['status'],'pass')
        p['result']['mismatches']=0;self.assertEqual(gpu.parse_run(json.dumps(p),'compute',True)['status'],'fail')
    def test_statistics_preserve_order_and_honest_spread(self):
        s=gpu.summarize([7,1,6,2,5,3,4]);self.assertEqual(s['median'],4);self.assertEqual(s['iqr'],3)
        self.assertEqual(s['raw'],[7,1,6,2,5,3,4]);self.assertNotIn('confidence_interval',s)

class CliTests(unittest.TestCase):
    def test_whole_offline_run_matches_new_schema_and_uses_no_normal_checks(self):
        mac=Mac();self.assertEqual(main(['--gpu-benchmark','--accept-gpu-risk'],mac),0)
        doc=json.loads(mac.written['omarchy-m-test-gpu-benchmark.json'])
        self.assertEqual(gpu_schema.errors(SCHEMA,doc),[])
        self.assertEqual(len(doc['schedule']),7*9);self.assertTrue(all(x['status']=='pass' for x in doc['cases']))
        self.assertEqual(mac.posts,[]);self.assertTrue(all(mac.private));self.assertEqual(mac.signs[0][0],gpu.NAMESPACE)
        self.assertFalse(any(c[0].startswith('bundled:') and c[0]!='bundled:gpu-benchmark' for c in mac.calls))
        self.assertFalse(any(c[0] in ('sudo','curl','systemctl','cryptsetup') for c in mac.calls))
    def test_failing_probe_private_paths_never_escape_document_or_signing(self):
        private='/home/private-owner/assets/10.0.0.7/725346d2-f127-47bc-b464-9dd46155e8d6.pak'
        def bad(value,args):return {'status':'fail','reason':'probe-execution','stderr':private,'asset_path':private,'before':{'ac':'online','hostname':private}}
        mac=Mac(fault=bad);self.assertEqual(main(['--gpu-benchmark','--accept-gpu-risk'],mac),2)
        text=next(iter(mac.written.values()));signed_input=mac.signs[0][1].decode()
        for secret in (private,'private-owner','10.0.0.7','725346d2-f127-47bc-b464-9dd46155e8d6'):
            self.assertNotIn(secret,text);self.assertNotIn(secret,signed_input)
        self.assertEqual(gpu_schema.errors(SCHEMA,json.loads(text)),[])
    def test_missing_helper_is_truthful_unsupported_no_samples(self):
        mac=Mac(fault=lambda *_:{'status':'unsupported','reason':'helper-not-built'})
        self.assertEqual(main(['--gpu-benchmark','--accept-gpu-risk'],mac),2)
        doc=json.loads(next(iter(mac.written.values())));self.assertEqual(doc['status'],'unsupported');self.assertEqual(doc['schedule'],[])
        self.assertTrue(all(not x['runs'] for x in doc['cases']))
    def test_decline_and_bad_repetition_do_not_run_work(self):
        for argv in (['--gpu-benchmark'],['--gpu-benchmark','--benchmark-repetitions','1']):
            mac=Mac(answer='n');self.assertIn(main(argv,mac),(1,4));self.assertEqual(mac.calls,[]);self.assertEqual(mac.written,{})
    def test_changed_implementation_stops_experiment(self):
        n=0
        def drift(value,args):
            nonlocal n;n+=1
            if n>=3:value['helper_sha256']='2'*64
            return value
        mac=Mac(fault=drift);self.assertEqual(main(['--gpu-benchmark','--accept-gpu-risk'],mac),2)
        self.assertEqual(json.loads(next(iter(mac.written.values())))['status'],'fail')
    def test_seeded_schedule_is_reproducible_and_not_grouped_by_workload(self):
        a=gpu.execute(Mac(),seed=42);b=gpu.execute(Mac(),seed=42)
        self.assertEqual(a['schedule'],b['schedule']);self.assertEqual(len(set(x['workload'] for x in a['schedule'][:7])),7)
    def test_custom_kernel_embedded_personal_hint_is_redacted(self):
        class PersonalMac(Mac):
            def run(self, args):
                if args == ['uname', '-r']:
                    return CommandResult(0, '7.2-private-owner-custom', '')
                return super().run(args)
        mac = PersonalMac()
        self.assertEqual(main(['--gpu-benchmark', '--accept-gpu-risk'], mac), 0)
        self.assertNotIn('private-owner', next(iter(mac.written.values())))
        self.assertNotIn('private-owner', mac.signs[0][1].decode())

    def test_comparison_rejects_float_documents_and_changed_kernel(self):
        doc = gpu.execute(Mac())
        other = copy.deepcopy(doc)
        other['machine']['kernel'] = 'another-kernel'
        self.assertFalse(gpu.compare(doc, other)['comparable_stack'])
        other = copy.deepcopy(doc)
        other['cases'][0]['runs'][0]['measurements']['record_ns'] = 1000.0
        self.assertFalse(gpu.integer_document(other))

    def test_real_signature_uses_dedicated_namespace_and_detects_tampering(self):
        with tempfile.TemporaryDirectory() as state:
            class SigningMac(Mac):
                def env(self, key):
                    return state if key == 'XDG_STATE_HOME' else super().env(key)
                def machine_sign(self, key_path, namespace, message):
                    return RealHost().machine_sign(key_path, namespace, message)
            mac = SigningMac()
            self.assertEqual(main(['--gpu-benchmark', '--accept-gpu-risk'], mac), 0)
            document = json.loads(next(iter(mac.written.values())))
            self.assertEqual(gpu_schema.errors(SCHEMA, document), [])
            allowed = Path(state) / 'allowed_signers'
            sig = Path(state) / 'document.sig'
            allowed.write_text('machine namespaces="' + gpu.NAMESPACE + '" ' + document['signature']['public_key'] + '\n')
            sig.write_text(document['signature']['signature'] + '\n')
            command = ['ssh-keygen', '-Y', 'verify', '-f', str(allowed), '-I', 'machine', '-n', gpu.NAMESPACE, '-s', str(sig)]
            self.assertEqual(subprocess.run(command, input=signing.canonical(document), capture_output=True).returncode, 0)
            document['protocol']['order_seed'] += 1
            self.assertNotEqual(subprocess.run(command, input=signing.canonical(document), capture_output=True).returncode, 0)

    def test_comparison_never_invents_significance_or_combined_score(self):
        a=gpu.execute(Mac());b=copy.deepcopy(a);b['machine']['chip']='M1'
        result=gpu.compare(a,b);self.assertTrue(result['comparable_stack']);self.assertNotIn('score',result)
        self.assertTrue(all(x['median_change_ppm']==0 for x in result['metrics']))
        b['stack']['packages'][0]['version']='2.0';self.assertFalse(gpu.compare(a,b)['comparable_stack'])


class LauncherGuards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = Path(__file__).parents[1] / 'omarchy_m_test/gpu_native/launcher.py'
        spec = importlib.util.spec_from_file_location('gpu_host_operation_fixture', path)
        cls.operation = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.operation)

    def test_own_memory_and_thermal_guards_fail_closed(self):
        op = self.operation
        self.assertIsNone(op.guard(copy.deepcopy(HEALTH)))
        for update, reason in (({'ac':'unknown'},'ac-not-confirmed'),
                               ({'temperatures_mc':[]},'temperature-unavailable'),
                               ({'temperatures_mc':[85000]},'experimental-temperature-stop'),
                               ({'memory_available_bytes':1024**3},'memory-reserve')):
            h=copy.deepcopy(HEALTH);h.update(update)
            self.assertEqual(op.guard(h),reason)

    def test_source_tree_without_native_binary_never_starts_a_probe(self):
        self.assertEqual(self.operation.run('compute'), {'status':'unsupported','reason':'helper-not-built'})

if __name__=='__main__':unittest.main()
