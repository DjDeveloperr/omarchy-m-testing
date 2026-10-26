"""Bundled GPU host operation, called only through Host.run_bundled.

Owns temporary cache/config state, native process bounds, health telemetry and
loaded-file hashes. Only allowlisted structured facts leave this boundary.
Neither raw output, environment, system logs nor absolute file paths escape.
"""
from __future__ import annotations
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time

WORKLOADS = ("raster", "texture", "compute", "copy", "submit-single", "submit-batched", "bo-lifetime")
ROOT = Path(__file__).resolve().parent
LIMIT = 262144
NAME = re.compile(r"Apple (?:M[0-9]+(?: Pro| Max| Ultra)?|A[0-9]+(?: Pro)?) \([A-Z][A-Z0-9]+ [A-Z][0-9]+\)\Z")
FAULTS = {"gpu-fault": r"(?:asahi|agx).*(?:fault|timed? ?out|reset|hang)",
          "kernel-fault": r"BUG:|Oops:|Kernel panic|soft lockup|RCU.*stall",
          "memory-oom": r"Out of memory:|oom-kill:", "dart-fault": r"(?:DART|apple-dart).*fault"}

def digest(path):
    h=hashlib.sha256()
    with open(path,'rb') as f:
        for chunk in iter(lambda:f.read(1024*1024),b''):h.update(chunk)
    return h.hexdigest()

def integer(path):
    try:return int(Path(path).read_text().strip())
    except (OSError,ValueError):return None

def snapshot():
    temperatures=[]
    for p in sorted(Path('/sys/class/thermal').glob('thermal_zone*/temp')):
        value=integer(p)
        if value is not None and -20000<=value<=125000:temperatures.append(value)
    cpu=[v for p in sorted(Path('/sys/devices/system/cpu/cpufreq').glob('policy*/scaling_cur_freq')) if (v:=integer(p)) is not None]
    gpu=[v for p in sorted(Path('/sys/class/devfreq').glob('*/cur_freq')) if (v:=integer(p)) is not None]
    ac=[]
    for p in Path('/sys/class/power_supply').glob('*/online'):
        value=integer(p)
        if value in (0,1):ac.append(value)
    mem={}
    try:
        for line in Path('/proc/meminfo').read_text().splitlines():
            key,_,value=line.partition(':')
            if key in ('MemTotal','MemAvailable'):mem[key]=int(value.split()[0])*1024
    except (OSError,ValueError):pass
    return {'temperatures_mc':temperatures,'cpu_frequency_khz':cpu,'devfreq_hz':gpu,
            'ac':'online' if 1 in ac else 'offline' if ac else 'unknown',
            'memory_total_bytes':mem.get('MemTotal',0),'memory_available_bytes':mem.get('MemAvailable',0)}

def fault_counts():
    try:r=subprocess.run(['journalctl','-k','-b','-n','2000','-o','cat','--no-pager'],capture_output=True,timeout=4,env={'PATH':'/usr/bin:/bin','LC_ALL':'C'})
    except (OSError,subprocess.TimeoutExpired):return {'available':False,'counts':{}}
    if r.returncode or len(r.stdout)>2*1024*1024:return {'available':False,'counts':{}}
    text=r.stdout.decode(errors='replace')
    return {'available':True,'counts':{name:len(re.findall(pattern,text,re.I)) for name,pattern in FAULTS.items()}}

def guard(h):
    if h['ac']!='online':return 'ac-not-confirmed'
    if not h['temperatures_mc']:return 'temperature-unavailable'
    if max(h['temperatures_mc'])>=85000:return 'experimental-temperature-stop'
    if h['memory_available_bytes']<max(2*1024**3,h['memory_total_bytes']//4):return 'memory-reserve'
    return None

def mappings(pid):
    """Hash actual system loader/implementation; only logical roles leave here."""
    result=[]
    try:lines=Path(f'/proc/{pid}/maps').read_text().splitlines()
    except OSError:return result
    for line in lines:
        path=line.split()[-1]
        if not path.startswith('/'):continue
        name=Path(path).name
        role='implementation' if re.fullmatch(r'libvulkan_(?:asahi|honeykrisp|borealis)\.so(?:\.[0-9]+)*',name) else 'loader' if re.fullmatch(r'libvulkan\.so(?:\.[0-9]+)*',name) else None
        if role is None:continue
        canonical=Path(path).resolve()
        system=any(str(canonical).startswith(base) for base in ('/usr/lib/','/usr/lib64/'))
        entry={'role':role,'sha256':digest(canonical),'system_provider':system}
        if entry not in result:result.append(entry)
    return sorted(result,key=lambda x:(x['role'],x['sha256']))

def terminate(p):
    if p.poll() is None:
        p.terminate()
        try:p.wait(timeout=2)
        except subprocess.TimeoutExpired:p.kill();p.wait(timeout=2)

def run(workload,negative=False):
    binary=ROOT/'bin/gpu-benchmark-vulkan';manifest=ROOT/'bin/gpu-benchmark-build.json'
    if not binary.is_file() or not manifest.is_file():return {'status':'unsupported','reason':'helper-not-built'}
    try:
        build=json.loads(manifest.read_text());sha=digest(binary);header=binary.read_bytes()[:20]
        if not(header[:4]==b'\x7fELF' and header[4:6]==b'\x02\x01' and struct.unpack_from('<H',header,18)[0]==183):
            return {'status':'unsupported','reason':'helper-architecture'}
        if build['suite']!=1 or sha!=build['executable_sha256']:return {'status':'fail','reason':'helper-drift'}
        source_names=('benchmark.c','compute.comp','fullscreen.vert','raster.frag','texture.frag')
        sources={name:digest(ROOT/name) for name in source_names}
        source_sha=hashlib.sha256(json.dumps(sources,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        if sources!=build['sources'] or source_sha!=build['source_sha256']:
            return {'status':'fail','reason':'helper-drift'}
    except (OSError,KeyError,ValueError,struct.error):return {'status':'fail','reason':'helper-manifest'}
    before=snapshot();why=guard(before)
    if why:return {'status':'guard-inconclusive','reason':why,'before':before}
    start_faults=fault_counts();samples=[];output=bytearray();drivers=[];p=None;reason=None;started=time.monotonic()
    # Cache/config isolation is recreated for every independent helper process.
    # No user's config, implicit user ICD or game data is read into the document.
    with tempfile.TemporaryDirectory(prefix='omarchy-m-test-gpu.') as temporary:
        env={'PATH':'/usr/local/bin:/usr/bin:/bin','LC_ALL':'C','HOME':temporary,
             'XDG_CACHE_HOME':temporary+'/cache','XDG_CONFIG_HOME':temporary+'/config',
             'XDG_DATA_HOME':temporary+'/data','MESA_SHADER_CACHE_DIR':temporary+'/shader-cache'}
        command=[str(binary),'--workload',workload]+(['--negative-control'] if negative else [])
        selector=selectors.DefaultSelector()
        try:
            p=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,stdin=subprocess.DEVNULL,env=env)
            for stream in (p.stdout,p.stderr):os.set_blocking(stream.fileno(),False);selector.register(stream,selectors.EVENT_READ,stream is p.stdout)
            next_sample=0
            while selector.get_map() or p.poll() is None:
                if time.monotonic()-started>45:reason='probe-timeout';break
                if time.monotonic()>=next_sample:
                    h=snapshot();samples.append(h);next_sample=time.monotonic()+0.25
                    why=guard(h)
                    if why:reason=why;break
                    if not drivers or not any(x['role']=='implementation' for x in drivers):drivers=mappings(p.pid)
                for key,_ in selector.select(0.05):
                    chunk=os.read(key.fd,16384)
                    if not chunk:selector.unregister(key.fileobj);continue
                    # stderr is deliberately discarded: driver failures can name
                    # home paths, usernames, addresses and arbitrary device data.
                    if key.data:output.extend(chunk)
                    if len(output)>LIMIT:reason='probe-output-limit';break
                if reason:break
            if reason:return {'status':'guard-inconclusive' if reason in ('experimental-temperature-stop','memory-reserve','ac-not-confirmed','temperature-unavailable') else 'fail','reason':reason,'before':before,'samples':samples}
            code=p.wait(timeout=2)
        except (OSError,subprocess.SubprocessError):return {'status':'fail','reason':'probe-execution'}
        finally:
            if p is not None:terminate(p)
            selector.close()
    after=snapshot();end_faults=fault_counts()
    if start_faults['available'] and end_faults['available'] and start_faults['counts']!=end_faults['counts']:
        return {'status':'fail','reason':'new-kernel-fault-category','before':before,'after':after}
    why=guard(after)
    if why:
        return {'status':'guard-inconclusive','reason':why,'before':before,'after':after,'samples':samples}
    if code == 3:
        return {'status':'unsupported','reason':'required-capability-unavailable','before':before,'after':after}
    try:
        records=[json.loads(line) for line in output.decode().splitlines()]
        identity=next(x for x in records if x.get('kind')=='identity');result=next(x for x in records if x.get('kind')=='result')
        if not NAME.fullmatch(identity['device_name']) or identity['vendor_id']!=0x10005 or identity['driver_id']!=26 or identity['device_type']!=1 or identity['api_version']<4202496:raise ValueError('identity')
        if identity['source_sha256']!=build['source_sha256'] or result['workload']!=workload:raise ValueError('version')
        if not any(x['role']=='implementation' for x in drivers) or any(not x['system_provider'] for x in drivers):raise ValueError('provider')
        expected=1 if negative else 0
        if code!=expected or result['mismatches']!=(1 if negative else 0):raise ValueError('correctness')
        identity={k:identity[k] for k in ('protocol','suite','device_name','vendor_id','device_id','device_type','driver_id','api_version','driver_version','timestamp_bits','timestamp_period_ps','source_sha256')}
        numeric=('mismatches','width','height','operations','record_ns','submit_wait_ns','thread_cpu_ns','gpu_timestamp_ns','gpu_timestamp_queries','bo_lifetime_ns','owned_bytes_peak')
        result={**{k:result[k] for k in numeric},'gpu_timestamp_status':result['gpu_timestamp_status']}
        if any(not isinstance(result[k],int) or isinstance(result[k],bool) or result[k]<0 or result[k]>10**15 for k in numeric):raise ValueError('numeric')
    except (KeyError,ValueError,TypeError,StopIteration,UnicodeError):return {'status':'fail','reason':'probe-protocol-or-correctness'}
    return {'status':'pass','reason':'negative-control-detected' if negative else 'completed',
            'identity':identity,'result':result,'helper_sha256':sha,'driver_libraries':drivers,
            'before':before,'after':after,'samples':samples,'kernel_fault_log_available':start_faults['available'] and end_faults['available']}

def main():
    args=sys.argv[1:]
    if args==['snapshot']:result={'status':'pass','snapshot':snapshot()}
    elif len(args) in (1,2) and args[0] in WORKLOADS and (len(args)==1 or args[1]=='negative-control'):
        result=run(args[0],len(args)==2)
    else:result={'status':'fail','reason':'invalid-operation'}
    # This document is intentionally path-free and integer-only.
    sys.stdout.write(json.dumps(result,separators=(',',':'))+'\n')

if __name__=='__main__':main()
