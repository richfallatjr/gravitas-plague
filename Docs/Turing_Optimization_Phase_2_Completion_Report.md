# Turing optimization Phase 2 completion report

## Final status

- Decision: BLOCKED
- Selected shipping candidate: none; `currentOverlap + operations40Megabytes32` also failed on device, and the next optimization candidate must be selected by the architect
- Candidate disposition:
  - diagnostic only pending Vision Pro calibration and pressure qualification
- Starting commit: `8955d6fa9bfc1a914aac6ee48db227e484cdcd01`
- Branch: `main`
- Dirty worktree preserved: yes
- Files added: bounded MLX diagnostics/failure bridge, Qwen typed boundary/circuit breaker/profiles/metrics, app startup/export/ownership telemetry, host analyzers/audits/tests, and completion reports
- Files modified: vendored MLX device/eval/package integration, Fresh2 render/decode/scheduler integration, app startup/render session, Mind's Eye in-flight telemetry, project configuration, and architect handoff
- Files removed: none
- Owner files reset: none
- Fresh instance count: 2
- Generation worker count: 2

## Phase 1 prerequisite

- Current production admission mode: `currentOverlap`
- currentOverlap: retained unchanged as production/default
- decodeExclusive: retained as qualification/control mode only
- Phase 1 device result: three candidate runs started, two completed, third reproduced `ImpactingInteractivity` without render/decode overlap
- Phase 1 latency result: no controlled identical-input baseline; candidate not promotable
- Relevant focused tests: 13/13 Phase 1 admission tests pass
- Existing unrelated stale tests: broad app suite not claimed; local host lacks Xcode

## Vendored MLX containment

- MLX version: 0.31.1 vendored local package
- Original callback throw removed: yes
- Central completion handler: one bounded handler installed by `Device::commit_command_buffer`
- noexcept/catch-all proof: completion handler and `complete_noexcept` are `noexcept`; completion body catches all exceptions
- Scheduler completion on failure: scheduler notification handler is nonthrowing/catch-all and remains installed for committed eval buffers; device run required
- Device poison: atomic launch-lifetime poison on first failed completion
- Controlled synchronous throw: `throw_if_turing_metal_failed` at eval/get-buffer/synchronize boundaries
- C API catch: existing MLX C catch boundary retained; device failure exercise required
- Swift withError: synchronous Qwen MLX operations are scoped by `withError`; async wrapper does not carry thread-local context across `await`
- Typed Qwen failure: `TuringQwenNativeMetalFailure` retains the exact command-buffer failure record
- Circuit breaker: first typed failure retained until relaunch; no production reset
- Same-launch retry policy: rejected immediately; no automatic retry or fallback TTS

## Failure-record contract

- Ring capacity: 64 records, fixed
- Aggregate metrics: submitted/completed/failure counts, maxima, and ten duration buckets
- Failure file: `Application Support/TuringDiagnostics/mlx-metal-last-failure.json`
- Atomic write: bounded temporary file, `fsync`, rename
- Stream/queue identity: recorded
- Operation count: recorded from MLX buffer split accounting
- Byte estimate: recorded as referenced-input estimate, not described as actual bandwidth/allocation
- Primitive labels/hash: count, first, last, and FNV-1a hash recorded
- Context: first/last context plus mixed-context flag
- GPU/kernel timing: Metal start/end/duration recorded
- Memory snapshots: process footprint/available and MLX active/cache/peak at submit and completion
- In-flight counts: MLX, app Metal, and Mind's Eye compositor counts
- Dialogue/PCM persisted: no

## Context coverage

- Warm load: exact synchronous resource/engine scope
- Initial talker: initial forward and codec-logit boundaries
- Dynamic talker: per-row context with row/talker-position ranges
- Code predictor: initial and nested dynamic predictor contexts
- CPU codebooks: outer render/materialization ownership context; CPU payload not persisted
- Decoder: session plus every existing exact decoder stage/decode ID
- Cache clear: phase type exists; cache clear does not launch evaluation and is not independently wrapped
- Unload: phase type exists; teardown avoids new evaluation
- Mind's Eye in-flight telemetry: atomic count 0/1 copied into MLX submissions without retaining a Mind's Eye owner
- Context across await: prohibited; thread-local context is installed only for synchronous work

## Startup profile

- Requested profile: both `deviceDefault` and `operations40Megabytes32` have completed one instrumented Vision Pro launch; Debug device builds remain on `operations40Megabytes32` until the architect selects the next optimization phase
- Device initialized before configuration: startup guard fails closed if true
- Resolved architecture: `applegpu_g14g`, generation 14
- Resolved max operations: 40 for both measured profiles
- Resolved max MB: 40 for `deviceDefault`; 32 for `operations40Megabytes32`
- Requested/resolved match: PASS for both measured Vision Pro runs
- Qualification-only controls: six typed buffer profiles and four targeted-boundary values
- Production profile: `deviceDefault`; no arbitrary runtime/user-default tuning

## Profile calibration

### deviceDefault
- Runs: 4 instrumented Qwen sessions in one Vision Pro launch; 3 completed and the fourth failed after publishing segments 0 and 1
- Metal failures: 1 (`MTLCommandBufferErrorDomain`, code 1, status 5)
- P50/P95/P99/max GPU duration: not measured
- First-audio P50/P95: not measured
- Total-response P50/P95: not measured
- Peak physical footprint: 5,557.0 MB in the last completed run; 5,525.0 MB immediately before the failed decoder stage
- Peak MLX active/cache: 3,652 MB peak in the last completed run; failed session reported 3,363 MB MLX peak and 3,103 MB active after failure containment
- Output parity: not measured

### operations32Megabytes40
- Runs: 0
- Metal failures: not measured
- P50/P95/P99/max GPU duration: not measured
- First-audio P50/P95: not measured
- Total-response P50/P95: not measured
- Peak physical footprint: not measured
- Peak MLX active/cache: not measured
- Output parity: not measured

### operations40Megabytes32
- Runs: 18 instrumented Qwen attempts across three Vision Pro launches; 15 completed, two failed after publishing earlier segments, and one capture ended while its final attempt was still generating its first two segments. Three additional same-launch conversation requests were rejected before Qwen warm load by the tripped circuit breaker.
- Metal failures: 2 (`MTLCommandBufferErrorDomain`, code 1, status 5); both were `dynamicTalker / baseClone.dynamicRow` buffers with 41 operations and low referenced-input byte estimates
- P50/P95/P99/max GPU duration: not measured
- First-audio P50/P95: not measured
- Total-response P50/P95: not measured; the final incomplete attempt had already degraded to projected per-lane real-time factors of 6.408 and 6.839 at row 8
- Peak physical footprint: at least 5,989.9 MB during the earlier failed run; the later failure recovered to 1,884 MB physical footprint with approximately 6,307 MB OS-available memory
- Peak MLX active/cache: 3,818 MB reported before the earlier failure; the later failure reported a 3,268 MB MLX peak and returned active/cache memory to 0 MB after unload
- Output parity: not measured

### operations32Megabytes32
- Runs: 0
- Metal failures: not measured
- P50/P95/P99/max GPU duration: not measured
- First-audio P50/P95: not measured
- Total-response P50/P95: not measured
- Peak physical footprint: not measured
- Peak MLX active/cache: not measured
- Output parity: not measured

### operations24Megabytes24
- Runs: 0
- Metal failures: not measured
- P50/P95/P99/max GPU duration: not measured
- First-audio P50/P95: not measured
- Total-response P50/P95: not measured
- Peak physical footprint: not measured
- Peak MLX active/cache: not measured
- Output parity: not measured

### operations16Megabytes16
- Runs: 0
- Metal failures: not measured
- P50/P95/P99/max GPU duration: not measured
- First-audio P50/P95: not measured
- Total-response P50/P95: not measured
- Peak physical footprint: not measured
- Peak MLX active/cache: not measured
- Output parity: not measured

## Slow-buffer diagnosis

- Aggregate-buffer correlation: BLOCKED pending first device export
- Single-primitive long buffers: BLOCKED pending first device export
- Mixed-context buffers: BLOCKED pending first device export
- Slowest phase: successful-session maximum was 88.069 ms; the failed buffer itself completed as a 19.051 ms Metal error, so duration alone did not predict it
- Slowest stage: the first failure was `speechDecoder.decoder.3.residual.4`, shape `1x37120x192`; the second was `dynamicTalker / baseClone.dynamicRow`
- Slowest primitive: the first failed aggregate contained 16 operations, first `Exp`, last `Multiply`; the second contained 41 operations, first `AsType`, last `Negative`
- Shape: available in existing Qwen stage log, not invented here
- Operation count: unknown
- Byte estimate: unknown
- Why aggregate split was or was not sufficient: lowering only the byte threshold from 40 MB to 32 MB did not contain the failure. Under the crossed profile, buffer 183666 failed with 41 operations and only 2,945,792 referenced-input bytes. No further profile or targeted primitive change is selected here; that optimization decision remains with the architect.

## Targeted fix

- Required: unknown; no speculative targeted fix enabled
- Boundary/primitive selected: none
- Files changed: policy contract only
- Exact chunk axis: none
- Chunk size: none
- Halo/mask/offset rules: none
- Weight duplication: none
- Output parity: unchanged by inactive policy; device parity pending
- GPU-duration effect: not measured
- First-audio effect: not measured
- Total-response effect: not measured
- Retained or reverted: no targeted change to retain

## Failure injection

- Callback returned: PASS in bounded synthetic completion test
- Failure epoch: PASS; increments once
- Ring record: PASS; exactly one synthetic failure record
- Scheduler completion: the crossed-profile device run exposed a lane-order unwind defect; host code now observes the first completed/failed lane through a throwing task group and immediately cancels its sibling; device proof pending
- Synchronous Swift error: boundary unit behavior PASS; end-to-end poisoned Metal call BLOCKED on device
- Queue cancellation: implemented; full fake-scheduler integration BLOCKED
- Decoder cancellation: implemented; full fake-scheduler integration BLOCKED
- Lane unwind: first-error task-group cancellation plus a dynamic-row cancellation checkpoint implemented; focused host test PASS and Vision Pro failure-path proof PASS
- Invalid output publication count: guarded by fatal typed path; device proof BLOCKED
- Already-published audio result: FAIL on the later device failure; generated segment 3 was actively audible at 3.779 seconds when `conversationFailed.qwen` cancelled its handle and detached Mind's Eye
- New-run circuit-breaker result: PASS by the current fail-closed contract; three later requests were rejected before warm load and repeated the original failure. Product recovery remains FAIL because microphones stayed enabled while Qwen was known to be unavailable until relaunch.
- Final ownership counts: Phase 1 controller tests PASS; failed-device run BLOCKED

## Pressure qualification

- Release no debugger: not run
- Xcode only: not run
- Capture only: not run
- Xcode + capture: not run
- Complete film: not run
- Repeated complete film: not run
- Ten targeted responses: not run
- Signed archive: not run
- Actual TestFlight: not run

## Stability and performance

- Crashes: not measured for Phase 2
- Uncaught C++ exceptions: callback throw removed; device proof pending
- Metal command-buffer errors: one typed device error under each measured profile (`deviceDefault` and `operations40Megabytes32`); there was no SIGABRT in either supplied log
- Hangs: one `operations40Megabytes32` run entered an infinite filler/dead-air cycle because lane 1 surfaced the process-global failure while the scheduler awaited lane 0 first. The first-error task-group fix is now proven on Vision Pro: a later Metal failure cancelled the sibling lane, finished decoder teardown, unloaded the pool, and returned story interaction without looping. A separate launch had no filler loop or Metal failure, but its fifth Qwen attempt was still in progress when capture ended and had degraded to approximately 6.4–6.8 projected real-time factor; classify that report as an incomplete severe-latency/stall trace, not a proven terminal loop.
- Audio underruns: not measured
- Segment ordering: implementation preserves existing ordering; device proof pending
- First-audio regression: not measured
- Total-response regression: not measured
- Steady-state real-time factor: not measured
- Peak physical-footprint change: not measured
- Peak MLX active/cache change: not measured
- Post-unload residual: not measured
- Thermal result: not measured

## Product regressions

- Authored playback: no intentional change
- Generated audio: no model/sampling/audio change
- Runtime phoneme lip sync: no intentional change
- Filler lip sync: no intentional change
- Mind's Eye continuity: no cadence/lifecycle change; telemetry only
- Actual speaker: no routing change
- Story progression: no flow change
- World/portal behavior: no change
- Model quality: unchanged
- Quantization: 4-bit unchanged
- Seeds: unchanged

## Tests and audits

- C++ diagnostics tests: bounded ring/synthetic completion exercised through public C/Swift test seam
- Swift MLX wrapper tests: ring wrap, monotonic sequence, poison/failure record, external in-flight counts pass
- Qwen-native focused tests: Phase 2 profile, policy, boundary, circuit-breaker, and first-lane-failure cancellation tests pass
- Phase 1 regression tests: 13/13 pass
- App integration tests: source added; not run because Xcode is unavailable on this host
- Host analysis tests: 3/3 pass
- Static audits: fail-closed Phase 2 audit passes; manual completion-handler audit passes
- Build: MLX target PASS; Qwen-native package PASS; app build BLOCKED because Xcode is not installed
- Archive: not run
- Diagnostics export: implementation and host analyzer present; device artifact pending

## Phase 3 readiness

- Safe command-buffer profile: none selected
- Remaining slow primitive: unknown until device ring evidence
- Current admission mode: `currentOverlap`
- Duplicate-residency measurement readiness: diagnostics ready, but Phase 3 is not authorized
- Exact Phase 3 starting condition: Phase 2 must first select and pressure-qualify a safe profile or prove an exact primitive blocker

## Blockers

- Vision Pro device calibration, failure-containment reproduction, performance/profile matrix, full pressure qualification, signed archive, and TestFlight-equivalent evidence remain required. No Xcode installation is available on this host for the simulator build or archive.
