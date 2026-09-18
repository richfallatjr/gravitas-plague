# C2: generation activation containment

Current status: **owner-approved normal shipping source default**. The owner
listened to the presented Mike sample and explicitly requested BF16 without a
separate test scheme/toggle. Broader engineering qualification remains pending;
this release decision does not manufacture a numerical, all-voice or device PASS.

Starting backup: `ae65c8b` (`WIP optimizations`). The original legacy baseline and
opt-in protocol below are historical. Production now selects
`TuringQwenNativeExecutionPolicy.production = Self(arithmetic: .bf16Candidate)`;
all other fields are unchanged. The retained explicit benchmark policy is
`Tools/Turing/Performance/Policies/generation-bf16.json`. Reference/control runs
must select legacy explicitly rather than treating `.production` as legacy.

## Scope and arithmetic contract

- Preserve independent Fresh2: two generation lanes, two raw weight stores, one
  decoder, current overlap, existing command-buffer policy and recovery.
- Keep all five voices, reference assets, full conditioning, sampling, EOS,
  segment ceilings, PR authority, playback and gameplay unchanged.
- BF16 storage applies to generation prompt components (including the FP32
  speaker embedding, before concatenation), QKV, RoPE outputs, attention
  outputs, residuals, MLP activations, and generation KV caches.
- Construct RoPE positions/frequencies/trigonometry in Double, then convert the
  resulting Float cos/sin tables to BF16. Never round positions or theta first.
- RMSNorm remains FP32 through normalization AND affine weighting, then casts
  its result to BF16. Manual attention score construction and softmax remain
  FP32; probabilities cast to BF16 for the value product. Existing one-step
  fast SDPA accumulates in float inside the vendored kernel.
- Vocabulary heads receive FP32 inputs before matmul. Sampling code is not
  changed. Changed sampled tokens remain possible: this is not an exact-parity
  arithmetic policy.
- Prompt and segment caches include/check arithmetic identity; a legacy cache
  cannot silently supply a candidate request.
- Decoder precision, decoder I/O, kernels, row windows, and C1 conversion cache
  are outside this experiment. Raw packed model weights are unchanged.

## Source evidence and precision failure retained

The installed Metal `bf16.h` uses `bfloat`, while quantized GEMV, RMS reductions,
and one-step SDPA use float accumulators. This is not evidence of an M2 tensor
core/NAX speedup. BF16 primarily targets activation/cache storage and unwanted
promotions; extra casts or M2 kernel selection can erase a benefit.

Initial host arithmetic tests found 31 failures in the fast RMSNorm oracle.
Inspection of `mlx/fast.cpp` and `rms_norm.metal` confirmed that both CPU and
Metal round the normalized activation to BF16 *before* affine multiplication,
and then round again. The candidate helper now keeps both operations FP32.
The fixed tolerance was not widened: relative `1/256` plus absolute `2e-6`;
explicit casts and high-position RoPE require independently rounded exact bits.
The diagnostic manual norm and precise softmax passed the original tests.

## Original evidence protocol, fixed before model candidate assessment

These engineering requirements are preserved, not retroactively marked complete
by the later owner-directed shipping decision documented below.

1. Run the same full production Big Mike response, not one-word/truncated
   scouts: `big_mike-production-response-full.json`, five segments, 160-row
   production ceiling, natural EOS mandatory for every segment.
2. A separate opt-in model probe runs the complete first-segment prefill with
   real weights and full default clone conditioning. Legacy repeated twice must
   match bitwise. Persist that calibration before candidate evaluation. Compare
   prompt, per-layer valid K/V, final hidden and FP32 logits, including argmax and
   margin. These are observations, not calibrated speech-quality tolerances.
3. Optional `--evidence-directory` captures already-materialized native code
   rows and PCM; serialize WAV/JSON only after render timing and teardown.
   Captured runs explicitly cannot qualify performance because retention changes
   memory use. Ordinary timing runs leave capture off.
4. Keep every failed, truncated, nonfinite, thermal or budget-stopped attempt.
   Different rows/duration means different work, not a proven arithmetic speedup.
5. Numerical/voice acceptance thresholds in `qwen-performance-gates.json` still
   require control calibration, five-voice listening/content review, fixed-seed
   and free-generation coverage. No speech-quality PASS follows from finite PCM
   or an unchanged prompt. Do not invent a tolerance after viewing C2 output.
6. Physical M2 Vision Pro paired tests, full-scene overlap, quality, cancellation
   and recovery remain mandatory before any production promotion. The previous
   isolated ~19-second M2 control is not a same-build C2 performance comparison.

No new gameplay control, testing button, special scheme or environment switch
is required. Normal builds now select BF16 generation through the production
policy; decoder arithmetic/I/O and all other policy fields remain unchanged.

## Latest shipping decision and validation boundary — 2026-09-18

The same-build M2 A/B/B/A screen comprised two Big Mike pairs: mean wall
25.204868354→24.333604854 seconds (about 3.5% lower), with 303→312 generated rows
and 24.24→24.96 seconds of audio. All requested segments reached natural EOS.
This changed-output, one-voice first screen is not identical-work speed proof;
the preserved comparison remains `OUTPUT_LENGTH_REVIEW`. The owner approved
the presented Mike audio, not all voices/scenarios. Calibrated numerical,
five-voice/content, repeated matched device, full-scene and recovery requirements
remain open even though the owner expressly chose to ship BF16 now.

The source shipping fingerprint is
`f7188d490a7d756b1ebc8c65b754bcd8c2e20ec3e45a6ddd70068f465cf665f3`.
Scheduler logs identify arithmetic/fingerprint. The external no-model
`ShippingPolicyCheck.swift` compiled the actual policy source and ran PASS for
the BF16 tuple/fingerprint, explicit legacy override, structured-task inheritance,
detached-task BF16 default and restoration. Legacy arithmetic/probe baselines
in four native test files were made explicit; the full native suite was not rerun.

The standard Release build passed (exit 0), log
`/private/tmp/qwen-c2-device-20260918.3dMy6t/c2-shipping-default.build.log`.
Deep/strict signature verification passed. Actual optimized app/native commands
omit the benchmark-launch define and preserve native stream recovery. The 58
performance/evidence and 25 provenance Python tests passed after the change.
The new shipping-default build has not yet been installed or played; an ordinary
Xcode build/run installs it with no extra switch or scheme. Earlier qualification
binaries and the restored legacy app are not this new build.
