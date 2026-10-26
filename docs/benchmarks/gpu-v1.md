# GPU benchmark suite 1 (unreleased)

This opt-in, offline mode measures fixed offscreen Vulkan workloads on native Apple Silicon Linux drivers. It does not predict how a game, compositor or all applications will perform, produce a combined score, or assume one chip must outperform another. Compilation and synthetic host tests are not hardware qualification.

## Run and compare

Use a reviewed AArch64 release containing the native helper. Save work first: experimental GPU drivers can hang. Leave the Mac idle, use AC power and keep the normal cooling controls enabled. The command never installs packages, changes governors or thermal controls, reboots, edits boot files, updates itself or uploads a document.

```sh
omarchy-m-test --gpu-benchmark --benchmark-seed 42 --benchmark-block 1 --output gpu-block1.json
omarchy-m-test --gpu-compare left.json right.json --output comparison.json
```

The normal interactive risk confirmation remains unless `--accept-gpu-risk` is supplied by an attended test operator. Default: two discarded warmup rounds and seven measured rounds; `--benchmark-repetitions 5..31` changes the latter. Each round interleaves all seven cases in reproducible seeded order. Every case runs in a fresh helper with empty private configuration/cache directories, so this is a process-cold benchmark, including pipeline setup outside timing, rather than a persistent application or sustained thermal benchmark. Two compute controls first require correct output and detection of exactly one deliberately corrupted expected word.

Each helper is bounded to 40 seconds internally, 45 seconds by its supervisor, with individual fence waits at most five seconds. A fixed 64 MiB cap covers explicit Vulkan memory allocations, not driver/compiler/kernel allocations. Available host memory must retain at least 2 GiB and 25% of RAM. Missing AC or thermal observations, insufficient reserve, or inability to cool within 30 seconds yield `guard-inconclusive`. The 85°C experimental stop is a conservative protocol rule, not a hardware damage threshold or evidence that healthy throttling is a regression. Between cases, temperatures must be within 5°C of the starting maximum and no more than 60°C. No policy is relaxed automatically to obtain a result. Driver errors, protocol errors, incorrect output, new observed kernel fault categories or implementation changes stop the session. Kernel-log access may be unavailable and is reported explicitly. Existing boot faults are not a clean-kernel certification. Worst-case default session allowance is approximately 90 minutes; ordinary durations require measurement. Interruption stops owned helper processes and does not save a partial result or upload anything.

## Fixed workloads

| ID | Actual work | Independent correctness control |
|---|---|---|
| raster | RGBA8 UNORM 1920×1080 offscreen, additive blending, fullscreen triangle, 16 submissions ×16 draws | Every pixel checked against coordinate/seed formula after each submission |
| texture | Same extent/format/blending, 1024×1024 RGBA8 source, four integer texel fetches/fragment, 16×4 draws | Full CPU coordinate/texture oracle; ±1 UNORM conversion tolerance |
| compute | 8 MiB uint32 SSBO, 8×8 dispatches of a 32-step nonlinear transform | Every word checked with independently executed CPU formula after each submission |
| copy | Two 32 MiB buffers, 32 device copies =1 GiB logical copied | Entire destination checked after every completion; changing seed |
| submit-single | 128 submissions ×1 dispatch over a 1 KiB buffer | Every word/seed checked after completion |
| submit-batched | 4 submissions ×32 dispatches; same 128 dispatches and seed sequence | Same oracle; equal work prevents a batching comparison from measuring extra work |
| bo-lifetime | 32 create/allocate/bind/use/fence/check/free cycles, 1 KiB buffer | Completed use checked before freeing |

CPU oracles, input generation, pipeline creation and readback validation are outside device timestamp scope. Seeds change to reject stale output. Additive blending makes every draw contribute; bounded integer contributions avoid saturation and opaque hidden-surface elimination. Graphics GPU timestamps end before image-to-buffer readback; CPU completion includes readback. The copy is logical transfer work, not a measurement of physical VRAM bandwidth. BO lifetime includes userspace allocation, driver calls, execution, synchronization and freeing; it is not isolated kernel VM teardown, pending-work destruction or multi-client coverage. One real GPU queue is used. No timeline semaphore, multiple queue or optional feature is implicitly enabled. Format/capability/API failures are explicit; absent timestamps remain unsupported.

## Timing and statistics

All raw per-run integers are retained in order, with workload/source/SPIR-V/helper/loaded implementation hashes. CPU `record_ns` measures command recording and finalization; `submit_wait_ns` covers fence reset, queue submission and completion wait. `thread_cpu_ns` is main-thread CPU time and excludes driver worker threads. None is pure GPU shader time or peak FLOPS.

Optional `gpu_timestamp_ns` sums available TOP_OF_PIPE→BOTTOM_OF_PIPE intervals on the same queue. These are pipeline-scope elapsed intervals, not calibrated CPU time or isolated shader ALU duration. Queries use 64-bit results plus availability after a bounded fence. Valid counter bits are masked with modulo wrap handling; wall completion shorter than a full counter period rules out multiple-wrap ambiguity. Timestamp period converts ticks to integer nanoseconds. Zero valid bits gives no timestamp sample, never zero or CPU time as a substitute. Device loss/errors invalidate the run. Vulkan has no GL-style disjoint flag; a future GL cohort must handle disjoint queries separately.

Each metric reports median, R7 quartiles, IQR, MAD, min/max and raw samples in nanoseconds, lower-is-faster. There is no combined score, confidence interval, frame p95, peak throughput claim or significance test. A comparison is descriptive; it flags different kernels, driver/helper hashes, package/config/firmware metadata or measurement protocols. It does not verify input signatures; verify signed inputs separately before trusting their origin. Repeat independent attended boot blocks, alternate device/order, hold package/kernel/firmware/workload/toolchain and power conditions fixed, and review within/between-block spread before claiming small differences. Boot block numbers are operator declarations, not verified boot identities. Frequency and thermal readings are passive observations, not evidence that DVFS or chip power was equal.

## Provenance, privacy and coverage

A passing run requires exactly one selected Apple integrated Vulkan GPU advertising the Mesa vendor ID0x10005 and Honeykrisp driver ID26 (not Apple PCI vendor0x106b) and an actual mapped system-native Asahi/Honeykrisp/Borealis implementation, hashed along with the loader. Software devices and non-system override libraries cannot pass. The helper starts with a minimal environment and private HOME/XDG/cache; inherited ICD, LD and debug overrides are not carried in. Device/API/driver numeric identity, workload extent/count, source hash, helper hash, loaded library hashes, selected package versions, running kernel release/config hash, firmware/system/OS/m1n1 chosen properties, model/board/SoC, temperature/frequency/AC/memory samples are allowlisted. Missing firmware properties or frequency sensors stay absent; exact loaded GPU firmware ABI, kernel build artifact hash, utilization, energy/power and comprehensive optional-device feature inventory are not yet captured. A package version alone does not prove which kernel or firmware binary ran. Keep a separately reviewed artifact/boot provenance receipt for claims requiring those exact pins.

`schema/gpu-benchmark-v1.schema.json` is separate from the normal hardware report/site schema. The CLI attempts to sign with the existing per-machine key under namespace `omarchy-m-test-gpu-benchmark` and writes a private local file. If signing is unavailable, it clearly reports this and saves an unsigned document; a passing workload status does not establish signature authenticity. The machine public key is the existing signing identity. Documents contain no host/user/home/IP/MAC/SSID/disk identifiers, absolute executable/asset paths, environment, UUIDs or raw driver/kernel logs. Unknown probe fields and raw stderr are discarded before signing. A failing adversarial fixture verifies this boundary. Normal hardware reporting and its schema stay unchanged; this mode does not call its upload path. There is no server ingestion support for this new document yet.

## Build and qualification

```sh
# Developer/CI operation only; prerequisites must already be provided.
cli/scripts/build_gpu_benchmark.sh /owned/build-output
/owned/build-output/gpu-benchmark-vulkan --host-self-test
OMARCHY_GPU_BINARY_DIR=/owned/aarch64-output release/build.sh /owned/release-output
```

The build records compiler/header/shader tool versions, shader/source/helper SHA256 values, validates SPIR-V and treats C warnings as errors. `--host-self-test` checks arithmetic/oracle/counter guards before Vulkan initialization. Release CI builds on ARM; source-only archives truthfully report `helper-not-built`. No compiler/package installer runs on a subscriber Mac. The normal release version still needs a maintainer version bump before publishing this unreleased feature.

Qualification before interpreting a comparison: build/load on supported AArch64 userspace; native provider selection; all full-output oracles and deliberately wrong negative control; supported and unsupported timestamps; stop/cleanup/AC/memory/thermal guards; repeated blocks on M1 Air, M1 MacBook Pro and M3 Pro with reviewed exact artifact/firmware/boot provenance. Desktop/presentation, suspend, external displays, OOM, multi-client stress, multiple queues and optional games are outside this offscreen suite's coverage. No result from this suite alone qualifies an RC image or proves Neo/G17 performance.

## Primary references

- [Vulkan timestamp queries and availability](https://docs.vulkan.org/spec/latest/chapters/queries.html#queries-timestamps)
- [Vulkan physical device limits, including timestampPeriod](https://docs.vulkan.org/spec/latest/chapters/limits.html)
- [Vulkan fences](https://docs.vulkan.org/spec/latest/chapters/synchronization.html#synchronization-fences)
- [Vulkan memory synchronization](https://docs.vulkan.org/spec/latest/chapters/synchronization.html)
- [Pinned Honeykrisp vendor/driver properties](https://github.com/omacom/mesa/blob/147a62f619/src/asahi/vulkan/hk_physical_device.c#L971)
- [Vulkan driver identity](https://docs.vulkan.org/refpages/latest/refpages/source/VkPhysicalDeviceDriverProperties.html)
- [Google Benchmark: repetitions and statistics](https://google.github.io/benchmark/user_guide.html#statistics-reporting-the-mean-median-and-standard-deviation-cv-of-repeated-benchmarks)
- [SPEC CPU run/report rules: consistency and disclosure principles](https://www.spec.org/cpu2017/Docs/runrules.html)
