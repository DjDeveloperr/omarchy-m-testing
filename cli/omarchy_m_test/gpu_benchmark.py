"""Opt-in, offline GPU experiments. All machine interaction uses the Host.

The normal hardware report/schema and normal section selection are unchanged.
This separately versioned document uses the existing machine-signing mechanism;
it cannot be uploaded by this command. No scalar ranks unlike workloads.
"""
from __future__ import annotations
import gzip
import hashlib
import json
import random
import re

from . import TOOL_NAME, TOOL_VERSION, bundled, gpu_schema, privacy, signing
from .host import Host
from .machine import NotAppleSilicon, identify

SUITE=1
NAMESPACE='omarchy-m-test-gpu-benchmark'
WORKLOADS=('raster','texture','compute','copy','submit-single','submit-batched','bo-lifetime')
OPERATIONS={'raster':256,'texture':64,'compute':64,'copy':32,'submit-single':128,'submit-batched':128,'bo-lifetime':32}
QUERIES={'raster':16,'texture':16,'compute':8,'copy':32,'submit-single':128,'submit-batched':4,'bo-lifetime':32}
REASONS={'completed','negative-control-detected','helper-not-built','helper-architecture','helper-drift','helper-manifest',
         'ac-not-confirmed','temperature-unavailable','experimental-temperature-stop','memory-reserve','probe-timeout',
         'probe-output-limit','probe-execution','new-kernel-fault-category','probe-protocol-or-correctness','invalid-operation',
         'cooldown-inconclusive','session-stopped','conditions-changed','invalid-host-response','required-capability-unavailable'}
PACKAGE_NAMES=('mesa','mesa-aurora','vulkan-asahi','vulkan-aurora','linux-aurora','linux-asahi','m1n1-aurora')
PACKAGE_QUERY=['pacman','-Q',*PACKAGE_NAMES]
HASH=re.compile(r'[0-9a-f]{64}\Z')
VERSION=re.compile(r'[0-9A-Za-z][0-9A-Za-z.+~:_-]{0,149}\Z')
GPU_NAME=re.compile(r'Apple (?:M[0-9]+(?: Pro| Max| Ultra)?|A[0-9]+(?: Pro)?) \([A-Z][A-Z0-9]+ [A-Z][0-9]+\)\Z')
IDENTITY_INTS=('protocol','suite','vendor_id','device_id','device_type','driver_id','api_version','driver_version','timestamp_bits','timestamp_period_ps')
RESULT_INTS=('mismatches','width','height','operations','record_ns','submit_wait_ns','thread_cpu_ns','gpu_timestamp_ns',
             'gpu_timestamp_queries','bo_lifetime_ns','owned_bytes_peak')
HEALTH_ARRAYS=('temperatures_mc','cpu_frequency_khz','devfreq_hz')

def integer(value,low=0,high=10**15):
    return isinstance(value,int) and not isinstance(value,bool) and low<=value<=high

def health(value):
    """Construct a numeric-only observation, never copy arbitrary keys/text."""
    if not isinstance(value,dict):return {}
    result={}
    for key in HEALTH_ARRAYS:
        values=value.get(key)
        if isinstance(values,list) and len(values)<=128 and all(integer(v,-20000 if key=='temperatures_mc' else 0) for v in values):result[key]=values
    if value.get('ac') in ('online','offline','unknown'):result['ac']=value['ac']
    for key in ('memory_total_bytes','memory_available_bytes'):
        if integer(value.get(key)):result[key]=value[key]
    return result

def parse_run(text,workload,negative=False):
    """Fail closed on malformed/mis-sized/unverified or inconsistent probes."""
    failure={'status':'fail','reason':'invalid-host-response'}
    try:
        if len(text.encode())>1024*1024:return failure
        value=json.loads(text)
        if value['status'] not in ('pass','fail','unsupported','guard-inconclusive'):return failure
        result={'status':value['status'],'reason':value.get('reason') if value.get('reason') in REASONS else 'invalid-host-response'}
        for name in ('before','after'):
            if name in value:result[name]=health(value[name])
        samples=value.get('samples',[])
        if isinstance(samples,list):result['health_samples']=[health(x) for x in samples[:200]]
        if result['status']!='pass':return result
        identity=value['identity'];metrics=value['result']
        if not GPU_NAME.fullmatch(identity['device_name']) or not HASH.fullmatch(identity['source_sha256']):return failure
        if not all(integer(identity.get(k)) for k in IDENTITY_INTS):return failure
        if identity['protocol']!=1 or identity['suite']!=SUITE or identity['vendor_id']!=0x10005 or identity['driver_id']!=26 or identity['device_type']!=1 or identity['api_version']<4202496:return failure
        if not all(integer(metrics.get(k)) for k in RESULT_INTS):return failure
        if metrics['operations']!=(OPERATIONS[workload]//QUERIES[workload] if negative else OPERATIONS[workload]):return failure
        dimensions=(1920,1080) if workload in ('raster','texture') else (0,0)
        if (metrics['width'],metrics['height'])!=dimensions or metrics['mismatches']!=(1 if negative else 0):return failure
        if metrics['owned_bytes_peak']>64*1024**2 or not HASH.fullmatch(value['helper_sha256']):return failure
        timestamp=metrics['gpu_timestamp_status']
        if timestamp not in ('supported','unsupported'):return failure
        if timestamp=='supported' and (not 36<=identity['timestamp_bits']<=64 or metrics['gpu_timestamp_queries']!=(1 if negative else QUERIES[workload])):return failure
        if timestamp=='unsupported' and (identity['timestamp_bits']!=0 or metrics['gpu_timestamp_queries'] or metrics['gpu_timestamp_ns']):return failure
        libraries=[]
        for item in value['driver_libraries']:
            if item['role'] not in ('loader','implementation') or not HASH.fullmatch(item['sha256']) or item['system_provider'] is not True:return failure
            libraries.append({'role':item['role'],'sha256':item['sha256']})
        if not any(x['role']=='implementation' for x in libraries):return failure
        result.update(identity={**{k:identity[k] for k in IDENTITY_INTS},'device_name':identity['device_name'],'source_sha256':identity['source_sha256']},
                      measurements={**{k:metrics[k] for k in RESULT_INTS if k!='gpu_timestamp_ns' or timestamp=='supported'},'gpu_timestamp_status':timestamp},
                      helper_sha256=value['helper_sha256'],driver_libraries=sorted(libraries,key=lambda x:(x['role'],x['sha256'])),
                      kernel_fault_log_available=value.get('kernel_fault_log_available') is True)
        return result
    except (KeyError,TypeError,ValueError,AttributeError):return failure

def quantile(values,numerator,denominator):
    """R7 interpolation rounded to integer units; no JSON/signature floats."""
    ordered=sorted(values);position=(len(ordered)-1)*numerator;index,remainder=divmod(position,denominator)
    upper=ordered[min(index+1,len(ordered)-1)]
    return (ordered[index]*(denominator-remainder)+upper*remainder+denominator//2)//denominator

def summarize(values):
    if not values:return {}
    median=quantile(values,1,2);q1=quantile(values,1,4);q3=quantile(values,3,4)
    return {'n':len(values),'median':median,'q1':q1,'q3':q3,'iqr':q3-q1,'minimum':min(values),'maximum':max(values),
            'mad':quantile([abs(x-median) for x in values],1,2),'raw':values}

def workload_definition(name):
    base={'id':name,'api':'vulkan','revision':SUITE,'operations':OPERATIONS[name]}
    if name in ('raster','texture'):
        base.update(width=1920,height=1080,format='rgba8-unorm',blend='add-one-one',oracle='full-image-integer-seed-v1-tolerance1',submissions=16,draws_per_submission=16 if name=='raster' else 4,
                    texture_width=1024 if name=='texture' else 0,texture_height=1024 if name=='texture' else 0,texture_fetches_per_fragment=4 if name=='texture' else 0)
    elif name=='copy':base.update(buffer_bytes=32*1024**2,submissions=32,logical_bytes=1024**3)
    else:base.update(buffer_bytes=8*1024**2 if name=='compute' else 1024,submissions=QUERIES[name],dispatches_per_submission=32 if name=='submit-batched' else 8 if name=='compute' else 1)
    base['sha256']=hashlib.sha256(json.dumps(base,sort_keys=True,separators=(',',':')).encode()).hexdigest()
    return base

def metrics_for(runs):
    measured=[r['measurements'] for r in runs if r['phase']=='measured' and r['status']=='pass']
    metrics=[]
    for key in ('record_ns','submit_wait_ns','thread_cpu_ns','bo_lifetime_ns','gpu_timestamp_ns'):
        values=[r[key] for r in measured if (key!='gpu_timestamp_ns' or r['gpu_timestamp_status']=='supported') and (key!='bo_lifetime_ns' or r[key]>0)]
        metrics.append({'id':key,'unit':'ns','direction':'lower','status':'measured' if values else 'unsupported',
                        'statistics':summarize(values)})
    return metrics

def safe_text(value, scrubber):
    # Personal names may be embedded in a custom kernel/package suffix where
    # ordinary word-boundary scrubbing cannot distinguish a version token.
    hints = getattr(scrubber, '_hint_values', ())
    if any(hint in value.lower() for hint in hints):
        return '<redacted>'
    return scrubber.scrub(value)

def integer_document(value):
    if isinstance(value, float):
        return False
    if isinstance(value, dict):
        return all(integer_document(v) for v in value.values())
    if isinstance(value, list):
        return all(integer_document(v) for v in value)
    return True

def stack(host,scrubber):
    packages=[]
    for line in host.run(PACKAGE_QUERY).stdout.splitlines():
        fields=line.split()
        if len(fields)==2 and fields[0] in PACKAGE_NAMES:
            version=safe_text(fields[1],scrubber)
            if VERSION.fullmatch(version):packages.append({'name':fields[0],'version':version})
    firmware={}
    for key,node in (('system','asahi,system-fw-version'),('os','asahi,os-fw-version'),('m1n1_stage2','asahi,m1n1-stage2-version')):
        try:value=safe_text(host.read_file('/proc/device-tree/chosen/'+node).rstrip(b'\0').decode(),scrubber)
        except (OSError,UnicodeError):continue
        if VERSION.fullmatch(value):firmware[key]=value
    config={}
    try:
        data=gzip.decompress(host.read_file('/proc/config.gz'))
        if len(data)<=4*1024**2:config={'config_sha256':hashlib.sha256(data).hexdigest()}
    except (OSError,ValueError,EOFError):pass
    return {'packages':sorted(packages,key=lambda x:x['name']),'firmware':firmware,**config}

def scrubber_for(host):
    try:hostname=host.read_file('/etc/hostname').decode().strip()
    except OSError:hostname=''
    try:users=host.list_dir('/home')
    except OSError:users=[]
    return privacy.Scrubber(hostnames=[hostname],users=users)

def snapshot(host):
    try:return health(json.loads(host.run_bundled('gpu-benchmark',['snapshot']).stdout).get('snapshot'))
    except (TypeError,ValueError):return {}

def cooled(host,target):
    for attempt in range(16):
        h=snapshot(host);temperatures=h.get('temperatures_mc',[])
        if h.get('ac')!='online' or not temperatures:return False
        if max(temperatures)<=target:return True
        if attempt<15:host.sleep(2)
    return False

def fingerprint(run):
    return {key:run[key] for key in ('identity','helper_sha256','driver_libraries')}

def execute(host,block=1,seed=0,repetitions=7):
    machine=identify(host);scrubber=scrubber_for(host);before=stack(host,scrubber);start=snapshot(host)
    target=min(60000,max(start.get('temperatures_mc',[55000]))+5000)
    controls=[];stable=None;stopped=None;runs={name:[] for name in WORKLOADS}
    for negative in (False,True):
        run=parse_run(host.run_bundled('gpu-benchmark',['compute',*(['negative-control'] if negative else [])]).stdout,'compute',negative)
        controls.append({'negative':negative,**run})
        if run['status']!='pass':stopped=run;break
        if stable is None:stable=fingerprint(run)
        elif fingerprint(run)!=stable:stopped={'status':'fail','reason':'conditions-changed'};break
    ordered=[];randomizer=random.Random(seed)
    if stopped is None:
        for phase,count in (('warmup',2),('measured',repetitions)):
            for repetition in range(count):
                order=list(WORKLOADS);randomizer.shuffle(order)
                for name in order:
                    if not cooled(host,target):stopped={'status':'guard-inconclusive','reason':'cooldown-inconclusive'};break
                    run=parse_run(host.run_bundled('gpu-benchmark',[name]).stdout,name)
                    record={'phase':phase,'index':repetition,'sequence':len(ordered),**run};runs[name].append(record);ordered.append({'workload':name,'phase':phase,'index':repetition})
                    if run['status']!='pass':stopped=run;break
                    if fingerprint(run)!=stable:stopped={'status':'fail','reason':'conditions-changed'};break
                if stopped:break
            if stopped:break
    after=stack(host,scrubber)
    if before!=after:stopped={'status':'fail','reason':'conditions-changed'}
    cases=[]
    for name in WORKLOADS:
        complete=len([x for x in runs[name] if x['phase']=='measured' and x['status']=='pass'])==repetitions
        status='pass' if complete and not stopped else stopped['status'] if stopped else 'guard-inconclusive'
        cases.append({'workload':workload_definition(name),'status':status,'reason':'completed' if status=='pass' else stopped.get('reason','session-stopped') if stopped else 'session-stopped',
                      'runs':runs[name],'metrics':metrics_for(runs[name])})
    doc={'document_type':'gpu-benchmark','schema_version':1,'suite':SUITE,'tool':{'name':TOOL_NAME,'version':TOOL_VERSION},
         'machine':{k:safe_text(getattr(machine,k),scrubber) for k in ('model','board','soc','chip','arch','kernel')},
         'stack':before,'protocol':{'warmups':2,'repetitions':repetitions,'order_seed':seed,'declared_boot_block':block,
             'boot_independence':'operator-declared-not-verified','cooldown_target_mc':target,'temperature_stop_mc':85000,
             'cache_policy':'new-empty-private-cache-per-helper','quantiles':'R7-rounded-integer','uncertainty':'within-session-spread-only',
             'api_scope':'native-vulkan-1.2-offscreen','multi_queue':'not-tested','vm_teardown':'not-isolated','upload':'never'},
         'controls':controls,'schedule':ordered,'status':stopped['status'] if stopped else 'pass','cases':cases}
    return doc

def compare(left,right):
    if left.get('document_type')!='gpu-benchmark' or right.get('document_type')!='gpu-benchmark':raise ValueError('wrong document type')
    if left.get('suite')!=right.get('suite') or left.get('status')!='pass' or right.get('status')!='pass':raise ValueError('incomplete or different suite')
    if [x['workload'] for x in left['cases']]!=[x['workload'] for x in right['cases']]:raise ValueError('workloads differ')
    a=fingerprint(left['controls'][0]);b=fingerprint(right['controls'][0])
    same_implementation=all(a[k]==b[k] for k in ('helper_sha256','driver_libraries')) and a['identity']['source_sha256']==b['identity']['source_sha256']
    comparable=same_implementation and left['stack']==right['stack'] and left['machine']['kernel']==right['machine']['kernel'] and all(left['protocol'][key]==right['protocol'][key] for key in ('cache_policy','api_scope','warmups','repetitions','temperature_stop_mc'))
    rows=[]
    for l,r in zip(left['cases'],right['cases']):
        if [m['id'] for m in l['metrics']] != [m['id'] for m in r['metrics']]:
            raise ValueError('metric ordering differs')
        for lm,rm in zip(l['metrics'],r['metrics']):
            if lm['status']!=rm['status'] or lm['status']!='measured':continue
            before=lm['statistics']['median'];after=rm['statistics']['median']
            rows.append({'workload':l['workload']['id'],'metric':lm['id'],'unit':lm['unit'],'direction':lm['direction'],
                         'left':lm['statistics'],'right':rm['statistics'],'median_change_ppm':((after-before)*1000000//before) if before else 0})
    return {'document_type':'gpu-benchmark-comparison','suite':left['suite'],'comparable_stack':comparable,'metrics':rows,
            'signature_verification':'not-performed-by-comparison',
            'conclusion':'Descriptive only. Independent boot blocks and workload-specific uncertainty are required for causal or small-change claims. No combined score.'}

def cli(args,host:Host):
    try:schema=json.loads(bundled.gpu_document_schema())
    except (OSError,ValueError):host.show('Benchmark schema is unavailable. Nothing ran.');return 4
    if args.gpu_compare:
        try:
            docs=[json.loads(host.read_file(p)) for p in args.gpu_compare]
            if any(not integer_document(doc) or gpu_schema.errors(schema,doc) for doc in docs):raise ValueError('invalid document')
            result=compare(*docs)
        except (OSError,ValueError,KeyError,TypeError):host.show('Cannot compare: incomplete, malformed or incompatible benchmark documents.');return 4
        output='omarchy-m-test-gpu-comparison.json' if args.output=='omarchy-m-test-report.json' else args.output
        host.write_file(output,json.dumps(result,indent=2)+'\n',private=True);host.show('Comparison saved locally; no upload.');return 0
    if not 5<=args.benchmark_repetitions<=31 or not 1<=args.benchmark_block<=1024 or not 0<=args.benchmark_seed<2**31:
        host.show('Benchmark repetitions must be 5–31; block 1–1024; seed 0–2147483647. Nothing ran.');return 4
    if not args.accept_gpu_risk:
        host.show('GPU benchmarks can hang an experimental driver. Save work, use AC power and leave the Mac idle. This mode never installs packages, reboots or uploads.')
        try:accepted=host.prompt('Run the GPU-only benchmark? [y/N] ').strip().lower() in ('y','yes')
        except EOFError:accepted=False
        if not accepted:return 1
    try:document=execute(host,args.benchmark_block,args.benchmark_seed,args.benchmark_repetitions)
    except NotAppleSilicon:host.show('GPU benchmarks require an Apple Silicon Linux machine. Nothing ran.');return 2
    except KeyboardInterrupt:host.show('GPU benchmark interrupted; owned work stopped and nothing uploaded.');return 130
    if gpu_schema.errors(schema,document):
        host.show('Benchmark result failed its privacy/schema boundary; nothing was signed, written or uploaded.');return 4
    signed,why=signing.sign_document(host,document,NAMESPACE)
    if gpu_schema.errors(schema,signed):
        host.show('Benchmark result failed its privacy/schema boundary; no document was written or uploaded.');return 4
    output='omarchy-m-test-gpu-benchmark.json' if args.output=='omarchy-m-test-report.json' else args.output
    host.write_file(output,json.dumps(signed,indent=2,ensure_ascii=False)+'\n',private=True)
    host.show('GPU benchmark saved locally. No upload. '+('Signed with the machine key.' if not why else 'Machine signature unavailable.'))
    for case in document['cases']:
        host.show(case['workload']['id']+': '+case['status'])
    return 0 if document['status']=='pass' else 2
