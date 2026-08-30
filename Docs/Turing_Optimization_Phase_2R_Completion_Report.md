# Turing optimization Phase 2R completion report

## Final status

- Decision: BLOCKED
- Selected production branch: failSoftUnavailable
- Production recovery enabled: No. `GR_TURING_METAL_STREAM_RECOVERY` remains unset pending actual-device proof.
- Qualification recovery enabled: Available only behind `GR_TURING_METAL_RECOVERY_QUALIFICATION`; not enabled in the normal build.
- Starting commit: `3f85a367683704eb91b8c747ddc3f58ae24011e6`
- Branch: `main`
- Dirty worktree preserved: Yes
- Local Phase 3 work preserved: Yes; source remains present and its production configuration remains disabled.
- Files added: MLX recovery ABI/controller/wrapper/tests; Qwen recovery generation/state/policy/receipt/coordinator/report/tests; Phase 2R source audit; this report.
- Files modified: MLX stream/diagnostic/evaluation integration; Fresh2 pool/scheduler/lane/decoder/admission; render-session ownership; app recovery availability, lifecycle, and microphone presentation.
- Files removed: None
- Owner files reset: None

## Diagnosis

- Phase introducing launch lockout: Phase 2 command-buffer containment left a process-wide poison latch that was intentionally permanent.
- Swift stale breaker: The provisional breaker exposed recovery at Fresh warm load without owning all runtime state.
- C++ stale failure latch: The active diagnostics poison survived after the failed command buffer completed.
- Replayed failure epoch: Not device-qualified.
- Replayed command-buffer ID: Not device-qualified.
- New failure epoch during replay: Not device-qualified.
- Provisional acknowledgment found: Yes.
- Provisional acknowledgment removed/restricted: Yes. Ordinary Swift and the C ABI can no longer acknowledge it; only the token-owning low-level reset path can.

## Locked architecture

- Fresh generation lanes: Exactly 2
- Production GPU admission: `currentOverlap`
- Decoder concurrency: Serialized, one active decoder run
- Model: Qwen3-TTS 12 Hz 1.7B Base
- Quantization: Existing 4-bit configuration unchanged
- Segment streaming: Preserved
- Automatic segment retry: None
- Automatic Foundation retry: None
- Mind’s Eye recovery teardown: None
- Authored playback timing changed: No

## Recovery state machine

- Initial generation: 1
- States implemented: ready, failing, draining, resettingMetal, probing, readyForFreshRuntime, unavailable, shuttingDown
- First-failure-wins: Yes
- Shared recovery task: Yes
- One attempt per failure: Yes
- Production launch budget: 3
- Qualification launch budget: 12
- Ownership drain timeout: Fail closed from incomplete aggregate receipt
- Metal drain timeout: 5 seconds
- Probe timeout: 2 seconds
- Total timeout: 12-second policy bound
- Waiters resumed exactly once: GPU admission uses one-shot checked continuations; device proof remains required.

## Generation identity

- Session: Recovery admission carries generation.
- Pool: Stored as immutable identity.
- Lane: Stored as immutable identity.
- Scheduler: Stored and checked.
- Admission: Recovery receipt is generation-scoped.
- Decoder: Run token and decoded result carry generation.
- Rendered codebook: Segment and release token carry generation.
- Decoded segment: Carries generation.
- Publication: Requires matching generation and coordinator publishability.
- Old-generation rejection: Implemented before `onSegmentDecoded`.
- Already-published-media exception: Existing published media remains owned by playback through its audible endpoint.

## Swift release receipts

- Lane 0: Explicit engine, mutable-state, residency, identity, and active-render proof.
- Lane 1: Explicit engine, mutable-state, residency, identity, and active-render proof.
- Decoder: Explicit token/session/stage/decode zero proof.
- Admission: Explicit generation/decode lease and waiter counts.
- Queue: Cancellation, empty request list, and empty waiter list checked.
- Release ledger: Run emptiness checked after clear.
- Independent residency: Released without per-lane process-cache clearing.
- Shared residency: Both leases and owner finish are checked.
- MLX active after release: Captured in aggregate receipt.
- Baseline active: Captured before pool warm load.
- Allowed residual: 128 MiB
- Receipt complete: Required before the low-level owner can begin.

## Low-level gate

- Recovery owner token: Failure epoch plus unique monotonic token.
- New eval blocked during drain: Yes; top-level eval/finalize/synchronize acquire execution leases.
- Active execution count: Explicit.
- In-flight command-buffer count: Incremented at submission and decremented in the nonthrowing completion path.
- Quiescence proof: Both counts must be zero.
- MainActor blocking: None; low-level recovery runs in a detached task.
- Timeout result: Fail-soft unavailable.
- Completion callback remains noexcept: Yes.

## DeviceStream reset

- Safe destructor order: Implemented.
- Encoder released before buffer: Yes.
- Temporaries: Cleared before buffer/queue.
- Fences/output map: Cleared before buffer/queue.
- Uncommitted buffers: Released before queue.
- Streams disposed: Entire stream map under its mutex.
- Queues recreated: Exact prior indexes, or default stream zero.
- Stream generations: Candidate generation assigned to every replacement stream.
- Residency set reattached: Yes.
- MTLDevice retained: Yes.
- Library/kernel cache retained: Yes.
- Full Device reconstruction attempted: No.

## Failure acknowledgment

- Owner-token guarded: Yes.
- Happens after quiescence: Yes.
- Happens after stream reset: Yes.
- Active latch cleared: Qualification reset path only.
- Failure epoch preserved: Yes.
- Last failure preserved: Yes.
- Ring preserved: Yes.
- Persisted JSON preserved: Yes.
- Warm-load direct acknowledgment remains: No.

## Allocator/residency

- Cache clear point: Once, after aggregate ownership release and again inside low-level reconciliation after stream reset.
- Active bytes before: Captured at reset.
- Active bytes after: Captured at reset.
- Cache bytes before: Captured at reset.
- Cache bytes after: Captured at reset.
- Residual threshold: Baseline plus 128 MiB.
- Residency leak result: Dedicated fail-soft result.
- Allocator reconstructed: No; allocator object is retained.

## Health probe

- Queue generation: Candidate generation.
- Command-buffer ID: Allocated by the existing diagnostics sequence.
- Work: Deterministic 256-byte shared-buffer Metal blit.
- Timeout: 2 seconds.
- Completion status: Must be `completed`.
- Metal error: Must be zero.
- Readback: Exact byte equality required.
- In-flight after: Must be zero.
- Probe failure recursion count: Zero automatic retries.
- Result: Host source/test path passes; actual Vision Pro proof not run.

## Next Fresh runtime

- New session ID: Generated by each render session.
- New pool ID: Generated by each pool.
- New lane 0 ID: New lane actor in a new pool.
- New lane 1 ID: New lane actor in a new pool.
- New decoder ID: New decoder coordinator/token.
- New shared owner ID, when applicable: New owner unless an explicitly supplied qualification owner is used.
- Any old ID reused: Generation numbers only; owner identities are not reused.
- Same-launch next turn result: BLOCKED on actual Vision Pro qualification.
- Old command-buffer ID replayed: Not device-qualified.

## Playback continuity

- qwenComputeFailed route: Preserved.
- runCancelled route avoided: Typed compute failures use `qwenComputeFailed`.
- Audible authored endpoint stops: No recovery stop added.
- Audible generated endpoint stops: No recovery stop added.
- Prepared clips retained: Yes.
- Missing clips skipped: Existing terminal reconciliation retained.
- Segment ordering: Existing ordered publication retained.
- Filler loops: Not changed.
- Response terminal completions: Not changed.
- Progression holds: Not changed.
- Microphone leases: Selectability is suspended during recovery.
- Interaction leases: Qwen pool ownership waits for ready/unavailable; the global room arbiter is not held for the unavailable remainder.

## Mind’s Eye

- Audible priority: Preserved.
- Preview deferral: Preserved.
- Card detached by recovery: No.
- Package evicted by recovery: No.
- Motion seed restarted: No.
- Mouth/blink/motion continuity: No recovery teardown was introduced.
- Stale visual updates: Existing run/handle protection remains.
- Wrong-speaker replacements: None added.

## Availability

- Recovering microphone state: Visible, desaturated, nonselectable.
- Unavailable microphone state: Visible, desaturated, nonselectable.
- Foundation requests while recovering: Blocked before microphone activation/new turn.
- Foundation requests while unavailable: Blocked before microphone activation/new turn.
- Ordinary game interactions: Remain available.
- User-facing stale Metal text: No raw Metal error is surfaced by the availability path.
- Relaunch behavior: Static state starts at generation 1 on a new process.

## Fault injection

- Fresh warm load: Hook path supported; device run not performed.
- Initial talker: Existing Phase 2 injection path; device run not performed.
- Dynamic talker: Existing Phase 2 injection path; device run not performed.
- Code predictor: Existing Phase 2 injection path; device run not performed.
- Decoder with generation: Generation identity and cancellation receipt implemented; device run not performed.
- Decoder with audible generated segment: Not device-qualified.
- Qwen while authored PR audible: Playback code remains independent; not device-qualified.
- Probe failure: Dedicated fail-soft path implemented; not device-qualified.
- Drain timeout: Dedicated fail-soft path implemented; not device-qualified.
- Background: Active recovery becomes unavailable.
- Shutdown: Active recovery becomes unavailable; an idle healthy runtime is not disabled.

## Ten-cycle qualification

- Recovery cycles: Not run.
- Ordinary conversations after: Not run.
- Automatic retry loops: None in source.
- Stale failure replays: Not run.
- Old-generation publications: Guarded in source; not device-qualified.
- Endpoint stops: Not run.
- Preview replacements: Not run.
- Filler loops: Not run.
- Ownership leaks: Not run.
- Peak generation lanes: Locked to 2 in source/tests.
- Peak decoder concurrency: Locked to 1 in source/tests.
- Physical-footprint trend: Not measured.
- MLX active trend: Not measured.
- MLX cache trend: Not measured.
- Queue-count trend: Not measured.
- Residency-owner trend: Not measured.

## Real Vision Pro failure proof

### Dynamic-generation failure
- Build: Not run.
- Environment: Actual Vision Pro required.
- Failure epoch: Not captured.
- Command-buffer ID: Not captured.
- Recovery: Not proven.
- Probe: Not proven.
- Same-launch next turn: Not proven.
- Stale replay: Not proven.

### Speech-decoder failure
- Build: Not run.
- Environment: Actual Vision Pro required.
- Failure epoch: Not captured.
- Command-buffer ID: Not captured.
- Recovery: Not proven.
- Probe: Not proven.
- Same-launch next turn: Not proven.
- Stale replay: Not proven.

## Builds and tests

- C++ recovery tests: Covered through the Swift C-ABI recovery tests; 2 passed.
- Swift MLX wrapper tests: 2 passed with the full Xcode toolchain.
- Qwen package tests: Focused recovery tests 4 passed; diagnostics ring tests 4 passed; circuit-breaker test 1 passed.
- Independent pool tests: Existing package suite compiles; Phase 2R device fault cycle not run.
- Shared-residency tests: Existing package suite compiles; Phase 2R device fault cycle not run.
- Playback tests: Source/app compile passed; device playback qualification not run.
- Mind’s Eye tests: No recovery teardown source found; device qualification not run.
- Microphone tests: App compile passed; device accessibility/visual qualification not run.
- Source audit: PASS.
- Arm64 simulator app build: Swift/C++ integration PASS with large resources excluded. The normal full-resource build reached resource copy and failed because only 116 MiB remained on disk, not because of a compiler error.
- Release archive: Not run; insufficient free disk and no device qualification.
- Actual TestFlight: Not run.

## Product regressions

- Authored PR: No timing or stop path changed.
- Generated audio: No sampling/decoder architecture change.
- Runtime phoneme lip sync: Not changed.
- Filler lip sync: Not changed.
- Mind’s Eye: No recovery teardown.
- Actual speaker: Not changed.
- Story: Ordinary interaction remains available when Qwen is unavailable.
- World/portals: Not changed.
- Model: Not changed.
- Quantization: Not changed.
- Seeds: Not changed.

## Phase 3 readiness

- Independent Fresh2 Phase 2R: Source implementation and host verification complete; actual-device proof blocked.
- Shared-residency rerun required: Yes, after the independent production branch is proven.
- Phase 3 may proceed: No production qualification claim yet.
- Exact remaining blocker: Qualification Release on Vision Pro must pass deterministic ten-cycle injection plus one real dynamic-generation failure and one real decoder failure before `GR_TURING_METAL_STREAM_RECOVERY` can be enabled.

## Blockers

- Actual Vision Pro qualification, real-failure evidence, Release archive, and TestFlight-equivalent testing have not been performed. Production therefore remains honestly fail-soft unavailable after the first MLX/Metal failure until relaunch.
