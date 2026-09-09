# Turing optimization Phase 5 completion report

## Disposition

- Qualification foundation: **PASS**
- Preliminary host scouting run: **PASS structurally**
- Production topology change: **NONE**
- Candidate promotion: **NOT EVALUATED / NOT AUTHORIZED**
- Stage 4 work: retained, still disabled at the production call boundary

The owner set a hard condition for this phase: retain an optimization only if
it does not slow Turing down. Phase 5 therefore cannot select a candidate from
API assumptions or a single host run. Production remains the current exact
two-lane `independentFresh2` topology with `currentOverlap` admission and two
generation permits.

## What was implemented

- A deterministic lane/stream matrix with these modes:
  - current two-lane/default-stream approximation;
  - one lane/default stream;
  - three lanes/default stream;
  - two lanes with one owned GPU stream per lane;
  - three lanes with one owned GPU stream per lane;
  - `microbatch2`, explicitly reported unsupported because the engine has no
    batched KV-cache, position-state, and sampling contract.
- Stable caller-owned MLX stream scoping through `TaskLocal`.
- A fix to `StreamOrDevice.stream(_:)`, which previously discarded the stream
  supplied by its caller.
- A one-command runner at `Tools/Turing/benchmark_qwen_phase5.sh`.
- Sequential warmup of every admitted engine and stream before measurement.
- First-needed PCM timing separated from the first completion on any lane.
- Fixed corpus, fixed greedy seeds, 160-row ceiling, completion-order capture,
  exact Float32 PCM digests, structural missing/duplicate checks, current
  process-memory snapshots, and honest unavailable markers for metrics this
  isolated harness cannot measure.
- Fail-stop behavior: after the first supported-mode failure, later MLX modes
  are not attempted in the same potentially poisoned process.
- Explicit report fields stating that the harness is an approximation, the
  exact shipping control was not executed, Stage 4 was not active, no
  production topology changed, and no automatic promotion occurred.

The experimental pool is deliberately not wired into the app. It uses the
deprecated shared-weight raw-lane harness and does not share the full Fresh2
residency, admission, decoder, playback, and Phase 2R recovery lifecycle.

## Preliminary host result

Artifact:

`Docs/TuringBenchmarks/phase5-host-quick.json`

This was one fixed-order quick run on the development Mac. It is scouting
evidence, not Vision Pro evidence and not a production decision.

| Mode | First needed decoded PCM | Delta | Audio seconds / wall second | Delta | Current physical footprint |
| --- | ---: | ---: | ---: | ---: | ---: |
| two lane / default approximation | 4.853 s | control | 1.965 | control | 2,539.6 MB |
| single lane / default | 1.469 s | -69.7% | 1.889 | -3.9% | 5,282.7 MB |
| three lane / default | 3.629 s | -25.2% | 1.998 | +1.7% | 3,416.3 MB |
| two lane / dedicated streams | 13.097 s | +169.9% | 0.770 | -60.8% | 2,731.8 MB |
| three lane / dedicated streams | 13.228 s | +172.6% | 0.723 | -63.2% | 3,339.5 MB |

All completed candidates produced exact matching Float32 PCM digests for all
eight quick-corpus segments. That establishes deterministic output parity in
this run; it does not replace a Big Mike listening/identity gate.

### Interpretation

- Dedicated per-lane streams fail the owner's no-slowdown condition by a wide
  margin on this host. They remain test-only and are not enabled.
- Single lane improved first-needed latency substantially but lost aggregate
  throughput, so it also does not clear the neutral-or-better gate.
- Three default-stream lanes improved both raw metrics in this one approximate
  host sample, but it is not the exact shipping topology, was not repeated or
  counterbalanced for thermal/order bias, and is not safe evidence for a
  Vision Pro change.
- The physical-footprint values are end-of-mode snapshots in a fixed serial
  process, not isolated peaks. The harness reports MLX peak values unavailable
  rather than relabeling end snapshots as peaks.

## Verification

- Focused Phase 5, stream, and production-invariant tests: **PASS, 19/19**
- Qwen benchmark executable Release build: **PASS**
- Generic visionOS Debug app build, code signing disabled: **PASS**
- Shell syntax and executable wrapper: **PASS**
- `git diff --check`: **PASS**
- Preliminary real-model host matrix: **PASS structurally**
- Exact shipping Fresh2 comparison: **not run**
- Repeated/counterbalanced Vision Pro measurement: **not run**
- Device playback scheduling, underrun, thermal, and listening gates: **not run**
- Candidate production activation: **not performed**

## Required promotion evidence

No Phase 5 mode may enter production until the same candidate and the exact
shipping control are measured through the Fresh2 residency, GPU admission,
decoder, ordered playback, and same-launch recovery path on Vision Pro. The
run must be repeated/counterbalanced and must show neutral-or-better
first-needed PCM latency and aggregate throughput, zero missing/duplicate/
reordered speech, zero playback underruns, no memory or thermal regression,
and no Big Mike identity or speech-quality regression.

The current valid decision is therefore: retain the Phase 5 instrumentation,
reject dedicated-stream activation, and leave production concurrency alone.
