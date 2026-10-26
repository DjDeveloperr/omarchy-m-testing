#!/usr/bin/env bash
# Explicit developer/release build. Never installs packages or executes GPU work.
set -euo pipefail
umask 022
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
src=$root/cli/omarchy_m_test/gpu_native
dest=${1:?Usage: build_gpu_benchmark.sh OUTPUT_DIRECTORY}
mkdir -p -- "$dest"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/omarchy-gpu-build.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
for file in compute.comp fullscreen.vert raster.frag texture.frag; do
  glslangValidator -V --target-env vulkan1.0 "$src/$file" -o "$scratch/$file.spv"
  spirv-val --target-env vulkan1.0 "$scratch/$file.spv"
done
python3 - "$src" "$scratch" <<'PY'
import hashlib,json,pathlib,struct,sys
src,out=map(pathlib.Path,sys.argv[1:]);names=['compute.comp','fullscreen.vert','raster.frag','texture.frag']
lines=['#include <stdint.h>']
for name in names:
 b=(out/(name+'.spv')).read_bytes();assert len(b)%4==0
 words=struct.unpack('<'+'I'*(len(b)//4),b)
 lines.append('static const uint32_t '+name.split('.')[0]+'_spv[] = {'+','.join('0x%08xu'%x for x in words)+'};')
(out/'shaders.h').write_text('\n'.join(lines)+'\n')
manifest={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in [src/'benchmark.c',*(src/n for n in names)]}
(out/'source.json').write_text(json.dumps(manifest,sort_keys=True,separators=(',',':')))
(out/'source.sha256').write_text(hashlib.sha256((out/'source.json').read_bytes()).hexdigest())
PY
source_sha=$(cat "$scratch/source.sha256")
cc -std=c11 -O2 -g -Wall -Wextra -Werror -I"$scratch" -DGPU_SOURCE_SHA256="\"$source_sha\"" "$src/benchmark.c" -o "$dest/gpu-benchmark-vulkan" $(pkg-config --cflags --libs vulkan)
python3 - "$src" "$scratch" "$dest" <<'PY'
import hashlib,json,pathlib,platform,subprocess,sys
src,scratch,dest=map(pathlib.Path,sys.argv[1:]);binary=dest/'gpu-benchmark-vulkan'
j={'protocol':1,'suite':1,'architecture':platform.machine(),'source_sha256':(scratch/'source.sha256').read_text(),
   'sources':json.loads((scratch/'source.json').read_text()),'executable_sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),
   'compiler':subprocess.check_output(['cc','--version'],text=True).splitlines()[0],
   'vulkan_headers':subprocess.check_output(['pkg-config','--modversion','vulkan'],text=True).strip(),
   'shader_compiler':subprocess.check_output(['glslangValidator','--version'],text=True).splitlines()[0],
   'shader_sha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in scratch.glob('*.spv')},
   'validation':'compile and SPIR-V only; no GPU runtime result'}
(dest/'gpu-benchmark-build.json').write_text(json.dumps(j,indent=2)+'\n')
print(json.dumps(j,indent=2))
PY
