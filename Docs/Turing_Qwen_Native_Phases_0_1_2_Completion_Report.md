# Turing Qwen Native Phases 0–2 Completion Report

Date: 2026-09-06  
Baseline source revision: `44e7bebcb5266b73e015f9f110294ca48be11a04` (`Angel MVP`)

## Disposition

| Phase | Result | Production-runtime disposition |
| --- | --- | --- |
| Phase 0 — investigation and benchmark | Implemented | Audit, deterministic corpus, Release CLI, JSON schema, hard quality gates, tests, and canonical reports added. |
| Phase 1 — synchronization/readback candidates | Rejected by the handoff's acceptance gate | Candidate reverted; production inference files match baseline. |
| Phase 2 — predictor/preallocation/compile candidates | Rejected by the handoff's acceptance gate | Candidate reverted; production inference files match baseline. |

No sub-threshold optimization was left in production. This is intentional compliance with the directive to retain only an individually meaningful or combined gain of at least 10% without quality, truncation, underrun, or memory regression.

## Delivered Phase 0 tooling

- The complete 61-answer source/model/runtime audit is `Docs/Turing_Qwen_Native_Phase_0_Audit.md`.
- `Tools/Turing/benchmark_qwen_native.sh OUTPUT.json [quick|full] [BASELINE.json]` builds a Release executable, locates and stages the MLX Metal library, runs the selected locked corpus, and atomically writes JSON.
- The full corpus contains 10 short, 10 medium, 10 long, and three multi-minute cases. Long material is divided into fixed sentence-sized production requests; the per-segment generation ceiling remains 160 rows.
- The fixed configuration is Big Mike `broadcast_reference_fast_01`, full 159-row reference, greedy talker and predictor, one checked-out Fresh2 lane, the MLX default stream, one warmup, and `.performance` mode.
- Schema version 2 records whether Big Mike's configured 0.85 playback rate was applied. It is `false` in this compute-only harness, so PCM duration and digests describe raw 24 kHz decoder output rather than time-stretched playback.
- Baseline compatibility locks schema, model, clone revision, device, Release configuration, corpus/input segments, sampling, row cap, lane policy, and other execution settings. A compatible AFTER run must preserve every PCM digest and gain at least 10% aggregate warm audio-seconds per wall-second or it fails.
- Row-cap hits, non-finite/empty PCM, a non-24 kHz result, any Metal command-buffer failure, prior-PASS regression, or digest mismatch are hard failures.
- Metrics which the current runtime cannot measure honestly—completed first semantic row, total MLX synchronization barriers, complete host-readback elements, isolated token materialization, allocation count, playback scheduling/audibility, and underruns—are explicitly `unavailable` or `notApplicable`, never zero-filled or inferred.

## Canonical Mac baselines

The canonical quick report is `Docs/TuringBenchmarks/phase0-baseline-quick-m4.json`. It is a compute-health PASS, not an optimization acceptance result:

| Metric | Result |
| --- | ---: |
| Cases / segments | 3 / 8 |
| Generated rows | 612 |
| Raw PCM duration | 48.96 s |
| Total measured wall time | 32.1438319683 s |
| Raw audio seconds / wall second | 1.5231538059× |
| Rows / second | 19.0394225742 |
| Peak process footprint | 4,875.894493 MB |
| Peak MLX active / cache | 2,441.760513 / 561.626842 MB |
| Metal command-buffer failures | 0 |

The short, medium, and long PCM digests are respectively `0b1fb77d8bd8236e`, `e334969ae3ef0d12`, and `6fb2b4d482d8866a`.

The canonical full report is `Docs/TuringBenchmarks/phase0-baseline-full-m4.json`. It correctly reports **FAIL** rather than accepting truncated output:

- All 10 short, 10 medium, and 10 long cases passed. Their passing-case aggregate is 6,201 rows, 496.080041667 seconds of raw PCM, 351.247645974 seconds wall time, 1.412336986× raw realtime, and zero Metal command-buffer failures.
- `multi-minute-01` decoded all 61 requests but one request reached the real 160-row ceiling without EOS. Its measured result was 5,007 rows, 400.56 seconds of raw PCM, 277.388491035 seconds wall time, 1.444039724× raw realtime, and zero Metal command-buffer failures.
- During that multi-minute case, process footprint rose from 3,773.894608 MB to a measured peak of 27,293.598930 MB and ended at 26,920.239555 MB. Peak MLX active memory was 2,801.994522 MB. The process footprint remained high across the continuous run; whether that residency belongs to the harness, native runtime, MLX, or the Metal driver is not yet attributed.
- The hard stop then marked `multi-minute-02` and `multi-minute-03` skipped. It prevented a second high-pressure pass on a 24 GiB development host.

These measurements are from the Apple M4 Mac host, not Vision Pro. The Xcode beta at `/Users/richardfallat/Downloads/Xcode-beta.app` includes the visionOS 27 SDK, but the registered Vision Pro was unavailable to `devicectl`. Consequently no physical-device playback, underrun, audible-start, perceptual-clone, capture-overhead, or Vision Pro memory result is claimed.

## Phase 1 candidate

The Phase 1 experiment removed redundant materialization/logging work and kept more row data device-side. The preliminary paired quick runs retained identical PCM digests but changed aggregate wall time only from 27.386057 seconds to 27.222684 seconds, approximately **+0.60%**. That preliminary corpus version also exposed two long-case row-cap hits and therefore cannot be an acceptance artifact. The gain was far below 10%; every runtime change was reverted.

## Phase 2 candidates

The invariant/preallocation batch was measured together with the Phase 1 experiment and did not turn the preliminary result into a qualifying gain. A second prototype compiled the complete 16-codebook greedy predictor as one lane-local MLX graph. Its direct predictor test produced the same 16 tokens as the uncompiled path; fixed short and medium PCM digests also matched. Summed preliminary per-case wall time was about 4.49% lower than its paired baseline, still below 10%, while the long case hit the same hard cap and the report failed. The compiled and invariant-hoist code was therefore reverted rather than shipped.

No Foundation Models prompt, story text, production segmentation, authored content, model weights, clone artifacts, concurrency policy, or playback behavior was changed.

## Verification

- `swift test --disable-sandbox --filter TuringQwenOptimizationBenchmarkTests`: 16/16 passed.
- `swift build -c release --disable-sandbox`: passed; existing deprecation/compiler warnings remain.
- An unsigned generic visionOS Release compile/link with the installed Xcode beta and visionOS 27 SDK passed. This was a compile check, not an archive, install, launch, or device qualification.
- The complete Swift package suite ran 81 tests: 80 passed and one unrelated fixture test failed because the ignored VoiceDesign-bf16 model payload is not installed (`Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16/vocab.json`). No dependency or model payload was installed to conceal that environmental precondition.
- The one-command wrapper completed a Release quick run and reproduced all three canonical PCM digests.
- `git diff --check`: passed.
- Direct diffs of the production Qwen files touched by the rejected experiments against `HEAD` are empty.
- The ignored model payload and all tracked `.qwenclone` profiles were inspected but not modified or unignored.

## Next evidence boundary

The largest measured risk is no longer hypothetical predictor dispatch overhead; it is the multi-minute process-footprint growth, followed by the existing row-level host boundary and the predictor's 15-forward/75-layer structure. Attribution should happen before another production optimization is retained. A future candidate must be compared with this same locked corpus and must pass exact digests, zero row caps, memory stability, device playback/underrun qualification, and the 10% throughput gate.
