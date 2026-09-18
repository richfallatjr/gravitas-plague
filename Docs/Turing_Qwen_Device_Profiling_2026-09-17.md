# Qwen/MLX device profiling — 2026-09-17

## Scope and status

Investigate TTS generation cost in the existing native Qwen3-TTS 1.7B Base 4-bit implementation. Preserve the stable gameplay runtime, Fresh2 concurrency, voice assets, recovery, and playback ordering. No inference optimization or runtime setting was changed during this investigation.

Source audit: local `7d71aea` (`CatEye81 brain`). The pre-existing project-file edit changes the marketing/build version from 4.1/31 to 4.3/33; it was left untouched. The device actually ran developer-installed **4.1/build 31** on visionOS 27.0 (24M5361a). Its source revision and optimization configuration are not embedded in the available run export, so exact installed-source parity is unproven.

Do not label this session a clean Release benchmark. It includes a Metal System Trace capture, and the installed build uses the `operations40Megabytes32` policy. Current source selects that policy in Debug and device-default limits in Release, but policy alone cannot establish how the installed binary was compiled.

## Fresh device evidence

Run: `358AEFD0-8288-4BD6-9BFF-FAD9FC0B967B.legacy`, Big Mike, six segments.

| Measurement | Observed |
| --- | --- |
| Aggregate real-time factor (wall time / raw audio duration) | **2.597804546** |
| Inverse throughput | **0.385 audio seconds / wall second** |
| First completed PCM, segment 1 | 25.039 s after render start |
| First needed PCM, segment 0 | **28.893 s** after render start |
| Entire render-stage interval | **55.496 s** |
| MLX buffers submitted / completed / failed | **37,009 / 37,009 / 0** |
| Residency | `independentFresh2`, two lanes, two weight stores, one decoder |
| Admission | `currentOverlap` |
| Resolved command-buffer policy | 40 operations / 32 MB; GPU `applegpu_g14g` |

PCM materialization is not actual audible start. The first completion was segment 1, 3.853 seconds before the first required segment 0. Do not fix this by playing segments out of order or changing PR authority.

Buffer histogram: 93.572% below 5 ms, 5.482% from 5–10 ms, 0.681% from 10–20 ms; four buffers were at least 50 ms. These counts suggest examining submission/encoding overhead, but **do not prove** that the GPU was starved or that buffers should be enlarged.

Full aggregate maximum GPU duration was 429.338 ms; maximum kernel duration was 423.180 ms. The operation threshold is not a hard cap on an indivisible operation: maximum observed encoded operation count was 183, and maximum referenced-input estimate was 308.76 MiB.

The retained `recentRecords` array contains only the last 64 buffers, covering the final 0.759 seconds of decoder segment 5. Consequently, `runMetrics.maximumGPUSeconds` (43.258 ms), `mixedContextCount` (0), and the tail's stream IDs cannot describe the whole run. Full aggregate and run submission counts match in this first-run export, allowing the full aggregate maximum to be associated with this run.

One memory warning occurred around +8.10 seconds (two log entries describe the same warning). Thermal state changed to raw value 1 around +29.49 seconds. Maximum sampled process footprint was 5,291.9 MiB; maximum sampled MLX active was 3,267.9 MiB; maximum reported MLX peak was 3,675.5 MiB. After unload, process footprint returned to 1,760.6 MiB and MLX active/cache returned to zero. These observations do not establish memory or thermal pressure as the principal throughput bottleneck.

Raw evidence directory, outside the repository:

`/private/tmp/gravitas-tts-profile-20260917.um2OWO/`

- `mlx-command-buffers-358AEFD0-8288-4BD6-9BFF-FAD9FC0B967B_legacy.json`
- `turing-launch-1789676459-B9F7AAF3-E795-4C85-8A6B-2EB9530026CF.jsonl`
- `qwen-native-last-breadcrumb.json`
- `tts-metal-system.trace` — completed 45-second all-process Metal System Trace. Direct attachment by PID/name failed, although CoreDevice could see and read the running app. No app rebuild/reinstall was performed.
- `trace-toc.xml`, `gpu-intervals.xml`, `cpu-profile.xml`, and `analyze_gpu.py` — exported trace metadata/tables and reproducible interval-union analysis.

### Completed GPU trace

The trace explicitly identifies the Vision Pro and its M2 GPU, with Gravitas Plague PID 1756 present. It covers 13:24:52.678–13:25:38.893 PDT (46.215195 seconds). TTS begins around trace second 23, so the capture covers the initial generation pair, **not** the completed response or steady later decoder segments. It ends before the first PCM materialization. Shader Timeline was disabled; this capture cannot attribute time to named MLX kernels or verify activation precision by kernel name.

Using only depth-zero `Active` intervals from `metal-gpu-intervals`, clipped to trace seconds 24–46.215195 and unioned rather than summed:

| Interval coverage in that 22.215195-second window | Seconds | Window percentage |
| --- | ---: | ---: |
| All recorded processes/channels | 13.948429 | 62.79% |
| Gravitas Plague compute | 11.111623 | 50.02% |
| App compute excluding explicitly labeled MindEyeComposite | 10.537380 | 47.43% |
| Explicitly labeled MindEyeComposite | 0.574243 | 2.58% |

The app's other compute work starts with TTS, but has generic `Command Buffer 0:Compute Command ...` labels; it is not a fully attributed MLX kernel total. These percentages describe **recorded active-interval coverage, not GPU core/ALU utilization**. They show substantial gaps and justify checking CPU graph construction, synchronization, and command dispatch before assuming uninterrupted GPU saturation. They do not alone identify the source of each gap. Mind's Eye is context here, not an optimization target.

The trace's issue store contains one `Data stream: Time Mapping` entry. Export also reports overlapping-image warnings for two unrelated system processes. Keep these tool caveats with the evidence; do not silently describe this as a pristine, uninstrumented hardware benchmark.

### Completed CPU trace: measured allocator diagnostic hotspot

The app-only Time Profiler export contains 31,851 samples weighted at 1 ms, or 31.851 sampled CPU seconds. Qwen/MLX appears in 24.786 sampled CPU seconds. The two leading worker threads account for 11.779 and 11.701 seconds; this is not evidence that Fresh2 was secretly disabled.

**`std::__1::__tree_sub_invariant` alone has 12.893 seconds of self samples: 40.48% of all app CPU samples and 52.02% of the Qwen/MLX subset.** Self samples avoid double-counting recursive inclusive frames. CPU percentages are not predicted wall-time speedups.

The symbolicated chain is:

```text
talker selection → MLXArray.item → lazy graph evaluation
  → AsType / copy_gpu → MetalAllocator.malloc
  → BufferCache.reuse_from_cache → std::multimap.erase
  → __tree_remove → __tree_invariant → recursive __tree_sub_invariant
```

This is recursive C++ container verification during MLX buffer reuse, not model matrix arithmetic. Vendored MLX `Source/Cmlx/mlx/mlx/backend/common/buffer_cache.h:30` erases the reused entry. The installed XROS SDK's `usr/include/c++/v1/__tree:351` checks the entire tree via `_LIBCPP_ASSERT_INTERNAL(std::__tree_invariant(__root))`; `__assert:81–94` enables that check in `_LIBCPP_HARDENING_MODE_DEBUG`. FAST and EXTENSIVE modes omit this particular internal check. Merely changing `NDEBUG` is not sufficient evidence that it is removed.

The captured app image is `Gravitas Plague.debug.dylib`, UUID `1E056994-5C7A-303D-A3DA-E8AB91E40C1E`. This establishes debug-dylib layout and actual execution of the expensive invariant checks, not every original compile option.

`AsType` appears in 7.889 seconds of inclusive CPU stacks, overlapping the allocator checks above. Do not add those times or label them isolated GPU casting time. Similarly, high inclusive time under `MLXArray.item` is lazy graph evaluation, not proof that sampling itself is expensive. Breadcrumb diagnostics appear in only 0.075 sampled CPU seconds (0.24% of all app samples) in this pre-decoder window; removing logging is not the leading measured opportunity here.

Reproduction artifacts: `cpu-profile.xml`, `cpu-analysis.json`, and `analyze_cpu_profile.py` in the raw evidence directory.

## Ranked low-level investigations

All paths below are relative to the repository. Native filenames are under `Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/` unless otherwise stated. The first hotspot is measured; the other candidates are source-backed. **No candidate speedup has yet been measured.**

### 1. Cmlx build optimization and libc++ debug-hardening overhead

First establish a source-matched optimized build and inspect the actual Cmlx compile commands/libc++ hardening mode. Repeat the same workload with Fresh2 and model arithmetic unchanged, verifying that expensive whole-tree validation is no longer in the hot path. Keep ordinary appropriate library hardening, MLX recovery, bounded GPU work, and application safety checks; do not globally disable assertions or patch the allocator as an unmeasured shortcut.

Because current source uses different command-buffer policies in Debug and Release, explicitly identify whether the experiment holds that policy constant or measures the complete shipping configuration. Do not claim a single-variable compiler improvement if both policies change. Profiled and unprofiled runs must also remain distinct.

### 2. Activation precision and repeated conversions

The main checkpoint contains BF16 floating weights and packed U32 quantized weights, but the native implementation introduces FP32 activations:

- `TuringQwenNativeBaseCloneInputBuilder.swift:24` constructs the speaker embedding from `[Float]`. It is concatenated with model embeddings at lines 226–244 and the complete prompt at lines 326–330.
- `TuringQwenNativeTalkerLayer.swift:764` and `TuringQwenNativeSegmentRuntimeCache.swift:98` create RoPE tables from `[Float]`. Rotary multiplication does not cast to the input dtype (`TalkerLayer.swift:796`, `CodePredictorForwardRunner.swift:732`).
- Vendored MLX `Source/Cmlx/mlx/mlx/fast.cpp:704` promotes SDPA query/key/value to their common dtype.
- Vendored MLX `Source/Cmlx/mlx/mlx/ops.cpp:4342` promotes quantized-matmul activation/scales/bias and inserts casts. FP32 activations therefore propagate FP32 outputs and require BF16 scale/bias conversions.

Measure dtypes without materializing tensors at prompt, QKV, post-RoPE, attention, KV cache, predictor, and logits boundaries. Inspect kernel names and conversion work. If significant, compare separately: (a) caching conversions already required by the current arithmetic, and (b) preserving BF16 activations. The latter changes numerics and needs explicit token/voice-quality, finite-output, memory, and stability validation; do not promise bit-identical PCM.

### 3. Prompt prefill attention

`TuringQwenNativeTalkerLayer.swift:567–604` rebuilds RoPE/masks, repeats KV heads, and performs dense score/softmax/value operations across each of 28 layers. Generated one-token attention already uses `MLXFast.scaledDotProductAttention` at line 661.

Measure prefill's share first. A fused causal grouped-query prefill and cached immutable shape-dependent tables are candidates. Keep the existing per-layer materialization boundaries until a separately qualified containment design justifies changing them.

### 4. Autoregressive graph and dispatch cost

Each subsequent 0.080-second audio row traverses 28 talker layers plus 15 five-layer residual-predictor passes: **103 model-layer passes per audio row**. The predictor allocates ten fixed-capacity K/V arrays per row (`TuringQwenNativeCodePredictorCache.swift:49`). Fixed-capacity slice updates do not by themselves prove in-place buffer reuse.

Use CPU stacks and GPU execution gaps to distinguish graph construction, allocation, casting, submission, and math. Current greedy residual prediction does not perform 15 host token readbacks per row. Only Dad/Rich use sampled talker logits; all five voices use greedy residual prediction. Avoid optimizing a nonexistent 15-readback production path.

### 5. Decoder repeated I/O, allocation, and synchronization

- `TuringQwenNativeSafetensors.swift:148` opens/seeks/reads/closes per tensor; the decoder session retains config/index, not the decoder tensor set.
- Quantizer rows are individually read for all 16 codebooks (`:176`).
- `TuringQwenNativeSpeechDecoder.swift:403` evaluates, clears the global MLX allocation cache, samples memory, and records two durable breadcrumbs per stage, including performance mode.
- Current configuration reaches 34 stage-materialization calls plus 54 bounded transposed-convolution eval calls and final output evaluation per segment. These are source-call counts, not measured barrier counts.
- `TuringQwenNativeDiagnostics.swift:164` synchronously locks, JSON-encodes, atomically replaces the last breadcrumb, and appends the timeline. At least 68 decoder-stage writes occur per segment, plus other diagnostics.
- `TuringQwenNativeCodecSampler.swift:85` still logs every successful talker selection.

Measure costs before changing them. Weight caching trades memory for speed; full caching is not automatically affordable. Global cache clearing, bounded convolution, and eval boundaries were introduced for stability. Do not remove them wholesale. A specialized bounded/tiled convolution is a possible larger project, not a safe one-line switch.

Each output segment also decodes up to 24 reference rows (1.92 seconds) and discards their PCM. At that maximum, this adds approximately 77% decoded duration for a 2.5-second output segment. Reducing it requires codec-state/continuity and audio parity evidence, not arbitrary prefix trimming.

## Measurement traps and previously tried paths

The current talker/predictor wall timers can charge lazy predictor execution to a later talker materialization. They cannot establish completed GPU cost by stage. The file named `TuringAudioOffloadSignposts.swift` only emits Logger messages; the audited source has no actual signpost intervals for these stages.

Prior evidence is useful but not a current-device A/B:

- M4 isolated quick benchmark: 48.96 seconds raw audio / 32.144 seconds wall, 1.523× realtime. It uses shared residency, one checked-out lane, no scene/playback, and no 0.85 playback processing.
- Older Vision Pro trace: approximately 0.515 seconds/row, projected RTF 6.44. Different workload/build; do not claim a measured 6.44→2.60 optimization gain.
- Prior generic sync/readback/log cleanup: approximately +0.60%; compiled predictor experiment: approximately +4.49%; both reverted under the former 10% gate.
- Dedicated streams were much slower in the approximate host Phase 5 matrix. Do not promote them or disable Fresh2 based on speculation.
- Growing-prefix streaming decoder remains a disabled qualification oracle: it repeats decoding work and has not passed PCM parity, recovery integration, or sustainable producer-cadence gates. No measured production slowdown from enabling that path is claimed here.
- A historical full host stress run reached roughly 27 GB footprint and hit a row cap. Do not start another long benchmark before bounded profiling.
- The old Phase 0 audit's claim that the tokenizer is rebuilt per request is stale; current engines retain their tokenizer.

## Next controlled experiment

1. Use the measured libc++ allocator-verification hotspot as the first target; preserve trace overhead as a separate condition.
2. Establish an optimized, source-identified on-device baseline using the existing two-lane pipeline. Inspect Cmlx optimization/hardening flags. Pin text, voice/reference, sampling, segment policy, command-buffer profile, scene, and warm/cold state. Include a no-profiler control and report thermal/memory warnings.
3. Add diagnostic-only, bounded dtype/phase markers if the capture cannot attribute stages. Avoid extra tensor eval/readback solely for logging.
4. Choose the largest measured target above; change one thing. Check time to first-needed PCM, aggregate RTF, GPU time, footprint, exactness/voice quality appropriate to the change, and repeated-run recovery.
5. Retain a change only if it improves relevant on-device performance without breaking stability or playback. Preserve two-lane concurrency unless a separate user-approved experiment explicitly tests topology.

Near-realtime on Vision Pro remains an objective, not a demonstrated outcome. The isolated Mac result proves this implementation can exceed realtime on different hardware/workload; it does not predict the headset result. Upstream Qwen's advertised first-packet latency is also a different metric from sustained on-device audio throughput.

Primary references: [MLX profiling/Metal debugger](https://ml-explore.github.io/mlx/build/html/dev/metal_debugger.html), [Qwen3-TTS upstream](https://github.com/QwenLM/Qwen3-TTS). Local vendored code and the actual device export are authoritative for this app.
