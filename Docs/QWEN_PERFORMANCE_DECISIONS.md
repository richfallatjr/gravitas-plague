# Qwen performance decisions — 2026-09-17

## Evidence boundary

This is the decision record for the new performance package. It is not a claim
that candidate arithmetic or production speedups have passed on Vision Pro.
The existing independent Fresh2 topology, two weight stores, one decoder,
currentOverlap admission, sampling, recovery and audio/story authority remain
the control. Phase C/D/E work below is **source-reviewed, not implemented**.
Execution-policy options reject unimplemented candidates instead of silently
running legacy code under a candidate label.

## A1/B: build identity and allocator hardening

The actual allocator translation unit now exports its compiled libc++ mode,
internal-assertion state, compiler/version, architecture, optimization macro
state, testing macro and named experiment. The Swift wrapper reads this without
initializing Metal. Mach-O UUIDs are read from the running executable and optional
Xcode debug dylib, not inferred from the checkout.

Ordinary Debug remains unchanged. Cmlx Release explicitly selects symbolic
`_LIBCPP_HARDENING_MODE_FAST`. The scoped override first undefines the mode,
because inspected Xcode Debug response files already supplied DEBUG. This does
not disable global assertions or alter allocator implementation, recovery,
optimization level, topology or model math. Named experiment values are
`hardening-debug-control` and `hardening-fast-only`; run them with identical
configuration and flags otherwise. Never equate Debug-vs-Release with a
hardening-only A/B.

Validation to date: Python provenance tests, manifest parsing, project syntax,
and a tiny host C++ fingerprint probe. The probe compiled both candidates at O0
and observed DEBUG/internalAssertions=true vs FAST/internalAssertions=false,
with optimized=false for both. It did not run inference or measure performance.
The actual installed-device experiment and repeat CPU profile remain pending.

For Xcode device builds, use the explicit immutable configurations
`Tools/Turing/Performance/HardeningDebugControl.xcconfig` and
`Tools/Turing/Performance/HardeningFastOnly.xcconfig` with `xcodebuild -xcconfig`.
The environment-only selector remains useful for SwiftPM CLI builds, but did
not reliably reach this Xcode build. A single parameterized xcconfig also
reused old effective values despite a correct FAST build request. The named
literal files produced the intended actual commands; their shared indirection
expands only for `PRODUCT_MODULE_NAME=Cmlx`. `.xcconfig` is included in source
fingerprints. No experiment config is enabled by the project normally.

The final `*-canonical-05` control/candidate manifests pass the build-only
comparison with identical source, optimization, recovery, Swift and Metal
settings. They still require installed fingerprints and actual device runs.

Update: six unique `readyb` device scouts now pass installed provenance and
exact PCM parity. Median render time is 28.35% lower for FAST in this short
unoptimized Debug test; Fresh2 and recovery settings remain unchanged. This
supports the allocator-hardening experiment but does not establish a shipping
Release improvement. Three sequential repeats per mode and only 0.64 seconds
of row-capped audio do not satisfy the production promotion gates. All attempts
and first-run cache variation remain in `QWEN_PERFORMANCE_RESULTS.md`.

The separate Time Profiler attempt completed device compute but Instruments
aborted while saving on the Mac; no CPU trace survived. Do not claim sampled
proof that the allocator hot path disappeared. Restore and measure the trace
facility and then the optimized Release baseline before selecting C/D/E from
the residual bottleneck. The existing release-hardening caveat below stands.

### Release baseline caveat

Explicit FAST is not an established improvement over the prior Release build.
The installed Xcode 27 `Clang.xcspec` chooses DEBUG at C/C++ optimization level
0. At optimized levels it selects FAST when enhanced security or C++ bounds-safe
buffers are enabled; without those settings the mode setting is empty and the
installed XROS libc++ `__config_site` defaults to mode 2 (NONE). Both FAST and
NONE omit the DEBUG-only internal whole-tree invariant checks. The current
SwiftPM build plan selects `s` for Release, and the prior package source had no
hardening override. No retained previous Release allocator command/binary
fingerprint was located. Thus source evidence supports that ordinary optimized
Release need not have paid the profiled Debug invariant cost already; it does
**not** establish whether an actual older shipped binary used FAST or NONE.
The new setting makes a supported non-NONE mode explicit. Claim a performance
benefit only from the named same-configuration DEBUG-vs-FAST device experiment,
not from the existence of this package edit.

`Scripts/turing/qwen_build_provenance.py capture` consumes an actual verbose
build log or compile database, recursively expands response files, keeps full
argv in a sidecar, hashes source/model/voice/workload identities, and records
linked UUIDs and compile summaries. `Scripts/qwen_verify_build_provenance.sh`
compares that evidence with an installed export. A matching commit alone is
insufficient. Missing commands, compiled mode, UUIDs, installed payload hashes,
workload identity or production runtime contract produces **unqualified**.
Before a fresh qualification build, run `snapshot --output
/private/tmp/qwen-prebuild-source.json`; pass that file back to capture with
`--source-snapshot`. Capture requires unchanged source, a successful build log,
and linked binary timestamps after the snapshot before verification can qualify.
This intentionally rejects stale artifacts and post-build-only source claims.

Normal app builds embed an explicitly unqualified manifest. A complete capture
must be stamped into the final bundle before signing, and actual installed UUIDs
must still match. `QWEN_BUILD_MANIFEST_PATH` can supply a source-matched manifest
to the final app build phase; a changed relink UUID requires recapture. Do not
claim a first-pass pre-link manifest proves that build's final binary identity.
Xcode build-plan `manifest.json` includes exact planned command argv, but absent
execution evidence it is diagnostic evidence, not proof those commands ran.

## C1: exact conversion caching — bounded candidate design

The relevant chain is:

- `TuringQwenNativeResidentResources.swift:6` owns the immutable weight store and
  resolved talker/predictor weights. Independent Fresh2 creates independent
  resource owners. No model-global conversion cache is appropriate.
- `TuringQwenNativeWeightResolver.swift:19` resolves packed U32 weights and BF16
  scales/biases. `TuringQwenNativeLinearWeight.apply` passes those original
  companions into each quantized matmul.
- Vendored `Source/Cmlx/mlx/mlx/ops.cpp:4323` promotes affine matmul dtype from
  input plus quantization companions; line 4357 creates casts of scales/biases.
  For FP32 input those immutable BF16 companions are repeatedly requested as
  FP32. Repeated actual allocation/copy costs still require the new profile;
  counting Swift calls does not prove GPU recasting.

The actual local 4-bit model header was read without loading tensor data.
Additional FP32 residency is `product(shape) * 4`, not the BF16 byte size:

| Exact tensor family (`.scales` and `.biases`) | Tensors | Added bytes/store | MiB/store |
| --- | ---: | ---: | ---: |
| `talker.code_predictor.model.layers.{0...4}.{self_attn.{q,k,v,o}_proj,mlp.{gate,up,down}_proj}` | 70 | 9,830,400 | 9.375 |
| `talker.code_predictor.lm_head.{0...14}` | 30 | 3,932,160 | 3.750 |
| `talker.code_predictor.small_to_mtp_projection` | 2 | 262,144 | 0.250 |
| All predictor companions | 102 | 14,024,704 | 13.375 |
| `talker.model.layers.{0...27}` companions | 392 | 176,160,768 | 168.000 |
| `talker.text_projection` companions | 4 | 1,048,576 | 1.000 |
| `talker.codec_head` companions | 2 | 786,432 | 0.750 |
| All companions | 500 | 192,020,480 | 183.125 |

Blanket caching adds **366.25 MiB across Fresh2**, before allocator overhead and
transient warmup. Do not implement it. The first proposed fixed hotset is only
the predictor companions, with a **16 MiB/store cap**, at most 32 MiB for both
stores. Exact modeled payload is 26.75 MiB total. This is a proposed budget, not
measured device headroom or approval to trade that memory for a speculative win.

Cache design constraints:

1. Build immutable cached copies once at the resident-load boundary; evaluate
   them there, include cold-load time/peak footprint, then make them read-only.
   A stored lazy cast node is not proof of materialized conversion reuse.
2. Key by owning weight identity/revision, source tensor key, execution dtype,
   quantization layout/group size/bits, device/context and recovery generation.
   Keep packed U32 weights packed. Do not cache/dequantize full matrices.
3. Preserve original BF16 companions. Select FP32 copies only when the original
   operator's dtype promotion would already produce FP32. Installing FP32
   companions indiscriminately can promote an otherwise BF16 invocation and is
   a math change, not exact caching.
4. Construct the bounded hotset transactionally. If not eligible, over budget,
   stale or unavailable, use original companions and record why. Never claim a
   cache hit when the original path ran. Do not evict/mutate buffers while lazy
   tensors may retain them. Destroy with the existing resource owner/recovery
   generation; do not add synchronization or share mutable lane state.
5. Prove exact conversion values, same arithmetic/output on captured input,
   actual conversion-kernel reduction, cache hit/materialization counts,
   retained/peak/residual bytes, cold and warm timings, cancellation and recovery.
   Only then test the hotset under Fresh2+decoder overlap on device.

BF16 activation containment is a separate C2 numerical candidate. FP32 speaker
conditioning, RoPE arrays, norms/constants and masks need explicit dtype audit;
do not hide these changes inside C1. Decoder arithmetic is separate. C2 must
establish calibrated numerical and five-voice quality gates before acceptance.

## D: fused prefill feasibility in the installed source

Current full prompt attention repeats K/V heads and uses dense score, softmax,
value operations in `TuringQwenNativeTalkerLayer.swift:602`. Its per-layer eval
boundaries at lines 160–167 remain mandatory for the first candidate. One-step
generation already calls `MLXFast.scaledDotProductAttention`; do not claim that
as a missing optimization.

Installed Swift API `Source/MLX/MLXFast.swift:203` supports `.causal` and array
masks and accepts untiled grouped K/V; it has no `force_fused` parameter.
The older wrapper comments are not the Metal dispatch authority. Installed
`backend/metal/scaled_dot_product_attention.cpp:588` selects a full SDPA kernel
for query length >8 with supported mask and head dimension 64/80/128; vector
mode also supports short queries under its GQA limit. Local model has Q heads
16, KV heads 8, head dimension 128. Thus source predicates permit full prompt
fusion; actual M2 kernel dispatch, layout copies and speed still require trace.

`mlx/mlx/fast.cpp:738` aligns causal query positions at `keyLength-queryLength`.
Full contiguous equal-length prefill positions 0...L-1 agree with the current
triangular mask. Unequal lengths or offset/chunked positions are not covered by
that equivalence: explicitly validate an array mask or retain legacy attention.
Preserve Q/K normalization, rotary math, precision, scale and cache ownership.
Cache immutable full-prompt RoPE/masks once per shape/dtype/position signature,
not hidden states across requests. New fused reduction order requires numerical,
causal-leakage, first/last-position and voice tests even if tensor shapes match.

## E: persistent predictor plan — distinguish the rejected trial

`Docs/Turing_Qwen_Native_Phases_0_1_2_Completion_Report.md:60` records the previous
lane-local complete 16-codebook compiled graph: token and short/medium PCM parity,
about 4.49% lower preliminary aggregate wall time on Mac, long-case row cap, then
reverted under the former 10% gate. That result is not device-qualified. The
retained report describes the trial; its full temporary implementation is not
present in the current source, so no unobserved internal detail is asserted.

Do not rerun that graph unchanged. The next hypothesis starts with a persistent
two-token prefill plan plus finite per-residual-position step plans owned by the
lane/model revision/dtype/configuration. Pass hidden state, selected token and
cache tensors as inputs; do not capture first-request values. Keep all fifteen
different heads/embeddings and their dependent chain. The greedy path already
keeps selected residual tokens as MLX arrays; there are not fifteen production
host readbacks to remove.

Measure first compile, steady compile count, graph construction, allocations,
completion cost and peak/residual memory. A shared compiled closure's lock can
serialize lanes (`Source/MLX/Transforms+Compile.swift:7`), so retain lane-local
owners. A compiled graph is not one Metal kernel or command buffer. Choose a
compiled group only if the smaller persistent-plan profile leaves worthwhile
CPU overhead; preserve recovery visibility and finite cancellation boundaries.

The existing predictor cache creates per-row K/V tensors. A Swift variable or
slice assignment does not establish physical buffer reuse. Keep functional
cache outputs first; add a bounded workspace only after proving backing-buffer
ownership through lazy graph and GPU completion. No global synchronization to
make reuse safe, no mutation while another row/command still references storage.
Test every residual head, consecutive/interleaved Fresh2 rows, decoder overlap,
voice changes, unload, cancellation and recovery-generation invalidation.

## Next decision

Obtain source/binary-matched hardening control/candidate data and the new phase
profile before choosing C1 versus D/E. The September 17 CPU trace motivates B;
it does not quantify the residual bottleneck after B. No C/D/E production
candidate is enabled and no additional arithmetic patch is implied by this
document.
