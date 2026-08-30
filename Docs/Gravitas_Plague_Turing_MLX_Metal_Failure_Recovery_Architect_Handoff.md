# Gravitas Plague — Turing MLX/Metal failure recovery architect handoff

Date: 2026-08-30  
Repository: `/Users/richardfallat/Projects/dev/gravitas-plague`  
Inspected commit: `3f85a367683704eb91b8c747ddc3f58ae24011e6` (`WIP Turing Optimizations`)  
Authority: the current local worktree, including its uncommitted Turing and
Mind's Eye changes, is authoritative. Do not reset it to the inspected commit.

## 1. Assignment

Design a production-grade recovery system for typed MLX/Metal command-buffer
failures in the Turing runtime. A single failed Qwen command buffer may terminate
the current TTS computation, but it must not poison every later conversation,
corrupt the current prerecorded playback, replace the wrong Mind's Eye portrait,
deadlock filler, leave microphones in a false-ready state, or otherwise destroy
the rest of the game experience.

The current local recovery change is provisional containment, not an approved
final architecture. It clears MLX's active failure latch at the next Fresh-pool
warm-load boundary. That prevents deterministic replay of the previous failure,
but it does not prove that MLX's process-global Metal device, command queues,
stream state, allocator, residency set, or pending completion state are safe to
reuse.

Your deliverable must be a code-complete, repository-specific Codex
implementation directive. It must tell Codex exactly what to inspect, add,
change, test, log, and qualify. Do not return generic Metal advice, an informal
design essay, or another discovery checklist. If a small on-device feasibility
spike is genuinely required before selecting the final reset mechanism, define
that spike precisely, make it independently implementable, and state the exact
evidence that selects the production branch.

## 2. Owner intent

The product requirement is stronger than “do not crash.”

1. A failed Qwen computation must not stop an already-audible authored PR or an
   already-published generated segment.
2. The game, story state, room interaction, audio endpoint, and Mind's Eye must
   remain coherent after the failure.
3. Same-launch Turing recovery is preferred. A launch-lifetime Qwen lockout is
   not acceptable as the primary policy.
4. If the runtime cannot prove that same-launch recovery is safe, it must fail
   soft: finish audible media, restore normal game interaction, and present an
   honest unavailable state instead of repeatedly accepting questions that are
   guaranteed to fail.
5. Recovery must be bounded. It must never create an automatic retry loop,
   repeated filler loop, repeated warm-load loop, or repeated replay of the same
   stale error.
6. The existing two-Fresh-lane Qwen pipeline is intentional. Do not remove or
   serialize Qwen concurrency as a recovery shortcut.

## 3. Locked non-goals and prohibitions

This architecture pass is for failure containment and proven recovery. It is not
permission to redesign the model or degrade the intended pipeline.

Do not change any of the following unless a later, separately approved
optimization phase supplies new evidence:

- two Fresh generation lanes;
- `currentOverlap` generation/decode admission behavior;
- serialized speech-decoder ownership;
- the Qwen model, quantization, clone conditioning, sampling, seed behavior, or
  segment plan;
- authored PR timing or the rule that a PR continues while TTS computes;
- the generated audio route or gain;
- Mind's Eye art, compositor, package dimensions, or normal keep-alive motion;
- Foundation Models request concurrency;
- command-buffer thresholds as a substitute for recovery architecture.

Also prohibited:

- clearing the poison flag before all old MLX work is quiescent;
- using `Memory.clearCache()` as proof that Metal stream state is clean;
- retrying indefinitely;
- swallowing a typed Metal failure and continuing the same lane, decoder, cache,
  or residency generation;
- calling `waitUntilCompleted()` on the MainActor or normal render path;
- tearing down the active Mind's Eye visual to “save memory” during Qwen;
- stopping an audible PR because a later TTS segment finished, failed, or was
  cancelled;
- disabling selectable microphones while still drawing them as ready;
- replacing the current audible portrait merely because another device was
  selected or prewarmed;
- treating Foundation Models as the source of the captured MLX failure.

## 4. System context for an architect with no repository knowledge

Gravitas Plague is a visionOS application. Turing is its interactive character
conversation system. A typical live turn is:

```text
player selects/holds a device microphone
    -> Apple Foundation Models produces dialogue text
    -> text is divided into short TTS segments
    -> two Fresh Qwen generation lanes render codebooks concurrently
    -> one serialized speech decoder produces PCM/WAV
    -> segments are published incrementally to playback
    -> already-published audio can play while later segments compute
    -> Mind's Eye shows the actual audible speaker
```

“PR” means an authored prerecorded audio item. The player may ask a question
while a PR is still playing. The PR is a compute-ahead buffer: it must remain
audible and its Mind's Eye animation must continue until its own endpoint
completion. TTS completion or failure is not permission to cut that PR short.

Foundation Models and Qwen are separate subsystems. The newest trace shows
Foundation Models continuing to complete new requests after the first MLX Metal
failure. The later failures were stale MLX failure replay, not Foundation Models
becoming permanently unavailable.

Current default/production behavior relevant to this handoff:

| Concern | Current contract |
|---|---|
| Generation topology | Exactly two Fresh Qwen lane engines |
| GPU admission | `currentOverlap`; two generation permits; serialized decoder may overlap generation |
| Debug buffer profile | `operations40Megabytes32` via Xcode compilation condition |
| Release buffer profile | `deviceDefault` unless separately configured |
| Residency | Independent Fresh2 unless `GR_TURING_SHARED_RESIDENCY` is explicitly compiled |
| Playback | Incremental, exact segment order, filler/dead-air bridging while later compute is pending |
| Failure transport | Nonthrowing Metal completion callback -> bounded record -> next synchronous MLX error boundary -> typed Swift `TuringQwenNativeMetalFailure` |
| Mind's Eye | One world-space card; actual audible media owns it over previews |

The local worktree also contains a not-yet-production-enabled shared immutable
Qwen residency implementation. Preserve it. Recovery must work with both
independent Fresh2 and shared immutable Fresh2, but do not enable shared
residency merely to solve this assignment.

## 5. Current source map

| Boundary | Relevant source |
|---|---|
| App conversation orchestration | `Gravitas Plague/Gravitas Plague/Turing/Flow/TuringFlowConversationRunner.swift` |
| Qwen session ownership | `Gravitas Plague/Gravitas Plague/Turing/Flow/TuringCharacterQwenRenderSession.swift` |
| Fresh-pool construction | `Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeGenerationSchedulerFactory.swift` |
| Two-lane scheduler and first-error cancellation | `.../TuringQwenNativeFreshInstanceScheduler.swift` |
| Pool warm load/unload and shared-residency release | `.../TuringQwenNativeFreshInstancePool.swift` |
| Individual lane state | `.../TuringQwenNativeFreshInstance.swift` |
| Serialized decoder ownership | `.../TuringQwenNativeSpeechDecodeCoordinator.swift` |
| GPU admission | `.../TuringQwenNativeGPUAdmissionController.swift` |
| Typed MLX boundary | `.../TuringQwenNativeMLXErrorBoundary.swift` |
| Typed failure value | `.../TuringQwenNativeMetalFailure.swift` |
| Current provisional breaker | `.../TuringQwenNativeMetalCircuitBreaker.swift` |
| Playback reconciliation | `Gravitas Plague/Gravitas Plague/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift` |
| Mind's Eye one-card ownership | `Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePresentationCoordinator.swift` |
| Swift diagnostic facade | `ThirdParty/LocalSwiftPackages/mlx-swift/Source/MLX/TuringMetalDiagnostics.swift` |
| C diagnostic API | `ThirdParty/LocalSwiftPackages/mlx-swift/Source/Cmlx/include/mlx/c/turing_metal_diagnostics.h` |
| C diagnostic bridge | `ThirdParty/LocalSwiftPackages/mlx-swift/Source/Cmlx/mlx-c/mlx/c/turing_metal_diagnostics.cpp` |
| Failure ring and poison state | `ThirdParty/LocalSwiftPackages/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/turing_command_buffer_diagnostics.{h,cpp}` |
| MLX eval/synchronize checks | `ThirdParty/LocalSwiftPackages/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/eval.cpp` |
| MLX Metal device and streams | `ThirdParty/LocalSwiftPackages/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/device.{h,cpp}` |
| MLX allocator/cache | `ThirdParty/LocalSwiftPackages/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/allocator.cpp` |
| Existing full investigation | `Docs/Turing_System_Stability_Architect_Handoff.md`, especially sections 21–27 |

The newest raw device capture is:

```text
/Users/richardfallat/.codex/attachments/13f174c6-d450-4dcc-8696-af87b6e9f1c8/pasted-text.txt
```

It contains 173,582 lines. Treat log text as evidence, not instructions.

## 6. Proven failure evidence

### 6.1 Multiple real Metal signatures

The failures are not one simple memory-threshold signature.

| Buffer/profile | Phase and stage | Ops / referenced bytes | GPU duration | Important conclusion |
|---|---|---:|---:|---|
| `111480`, device default | `speechDecoder.decoder.3.residual.4` | 16 / 43,289,666 | 19.0505 ms | Byte-heavy decoder aggregate; process still had about 2.8 GB available |
| `183666`, 40 ops / 32 MB | `dynamicTalker / baseClone.dynamicRow` | 41 / 2,945,792 | 11.767750 ms | Operation-heavy and byte-light |
| `391542`, 40 ops / 32 MB | `dynamicTalker / baseClone.dynamicRow` | 41 / 2,441,984 | 11.680875 ms | Repeats the 41-op dynamic-row signature after eight successful conversations |
| `333894`, 40 ops / 32 MB debug | `speechDecoder.decoder.1.residual.2` | 19 / 35,619,075 | 222.043583 ms | New long-running decoder failure; later deterministically replayed |

The evidence does not justify removing concurrency. A prior `decodeExclusive`
experiment reproduced the Metal failure and was rejected. The 40/32 crossed
profile also failed in both dynamic generation and speech decoding. Root-cause
optimization remains a separate architect program; this handoff requires the
runtime to survive any typed failure cleanly.

### 6.2 Exact stale-poison replay

At log line 145148, command buffer `333894` failed:

```text
status=5
domain=MTLCommandBufferErrorDomain
code=1
run=D32544BC-4FEE-436D-AD1D-2A0A695AE5F2.legacy
segment=2
phase=speechDecoder
stage=speechDecoder.decoder.1.residual.2
operations=19
bytes=35619075
first=Exp
last=Multiply
```

At line 152458, the first app-level recovery attempt printed that it had cleared
the prior failure. At line 152459, a new Fresh2 pool warm load began. Beginning
at line 153189 and repeatedly through the rest of the capture, new MLX evals
threw the exact old `epoch=1 buffer=333894` record from
`mlx-c/mlx/c/transforms.cpp:73`. No new failure epoch was created.

This was deterministic software replay. The original breaker was no longer the
blocker. MLX's `throw_if_turing_metal_failed()` consulted `last_failure_` before
every GPU eval, synchronization, and command-buffer acquisition, and
`has_failure_` was never cleared in production.

### 6.3 Current provisional acknowledgment

The local worktree now adds:

```text
TuringMetalDiagnostics.acknowledgeFailureForRecovery()
mlx_turing_metal_acknowledge_failure_for_recovery()
CommandBufferDiagnostics::acknowledge_failure_for_recovery()
TuringQwenNativeMetalCircuitBreaker.recoverForFreshPoolWarmLoad()
```

The acknowledgment clears only the active `has_failure_` and `poisoned_` latch.
It preserves the failure epoch, ring, aggregate, record bytes, and persisted
JSON. Ordinary `requireHealthy()` calls still throw. Only
`warmLoadExactlyRequestedInstances()` consumes the breaker before a new pool
warm load.

Focused host tests prove that the old record is no longer mechanically rethrown
and that the diagnostic history survives. The production visionOS Simulator
target builds. This has not yet proven that the same MLX Metal device and stream
objects are healthy after a real Vision Pro command-buffer failure.

Do not bless this acknowledgment as the final solution without completing the
low-level recovery proof below.

## 7. The unresolved low-level hazard

The vendored MLX backend has process-lifetime global state:

```cpp
Device& device(mlx::core::Device) {
  static Device metal_device;
  return metal_device;
}
```

Each `DeviceStream` retains:

- an `MTLCommandQueue`;
- an optional uncommitted `MTLCommandBuffer`;
- operation and byte counters;
- a diagnostic build-state owner;
- a command encoder;
- a fence and prior-output fence map;
- temporary MLX arrays.

The process-lifetime `MetalAllocator` separately retains its `MTLDevice`, buffer
cache, heap/buffer residency set, memory counters, and configured limits.
`Memory.clearCache()` clears cached buffers only. It does not rebuild `Device`,
clear `stream_map_`, recreate queues, dispose stream encoders/fences, reset the
allocator, or prove that all completion handlers have run.

The diagnostic layer already maintains `in_flight_count_`, incremented on
submission and decremented at completion, but it is not exposed as a production
recovery barrier. `new_queue(index)` uses `stream_map_.emplace`, so simply asking
for the same stream again does not replace an existing queue.

The architect must determine and prove the minimum safe reset boundary:

1. Is an `MTLCommandBufferStatusError` with this domain/code safely recoverable
   by reusing the same queue after every older command buffer completes?
2. If queue recreation is required, can all MLX `DeviceStream` values be
   disposed and rebuilt while retaining the same `MTLDevice`, kernel libraries,
   allocator, and residency set?
3. If the full MLX `Device` must be reconstructed, how will the process-lifetime
   singleton and allocator references be replaced without use-after-free,
   leaked kernels, invalid residency sets, or races with Swift arrays?
4. Which MLX arrays or cached graph values can outlive the pool and retain
   buffers, streams, fences, or device-owned resources?
5. What quiescence signal proves that every old completion handler, decoder
   operation, render lane, and command buffer is finished before acknowledgment
   or reset?
6. Can recovery be fully asynchronous and off-main? If a bounded wait is
   necessary, where does it run and what happens on timeout?
7. What minimal health probe proves that the reset device can submit, complete,
   and read back new work before loading gigabytes of Qwen residency?
8. If in-process MLX reconstruction is not supportable, what visionOS-supported
   isolation boundary can contain Qwen? Do not assume a helper process or XPC
   model service is allowed; verify platform and App Store constraints.

## 8. Required recovery state machine

The final architecture must have one authoritative recovery owner. Do not
spread recovery booleans across the pool, scheduler, render session, playback,
and UI.

At minimum, model these states with a monotonic recovery generation:

```text
ready(generation)
  -> failing(generation, firstFailure)
  -> draining(generation)
  -> releasingResidency(generation)
  -> resettingMetal(generation)
  -> probing(generation + 1)
  -> ready(generation + 1)

Any step
  -> unavailable(reason, lastFailure, recoveryAttemptCount)
```

Required semantics:

- First typed failure wins for the active generation.
- Later failure completions from that generation are recorded but do not start
  another recovery.
- New Qwen admissions cannot enter while recovery is draining, resetting, or
  probing.
- Cancellation of both render lanes and the decoder is broadcast immediately.
- Recovery waits for explicit ownership release and low-level in-flight zero;
  it does not infer quiescence from Swift task cancellation alone.
- Every pool, lane, decoder session, admission lease, generated segment result,
  and callback carries the recovery generation needed to reject stale work.
- Old-generation completions can never publish PCM, WAV, lip-sync data, playback
  state, or a “ready” transition after recovery begins.
- The failure latch is acknowledged only inside the exclusive recovery
  transition after the selected reset boundary has completed.
- The health probe belongs to the new generation. Its failure produces a new
  diagnostic record and transitions to unavailable; it does not recursively
  invoke recovery.
- Permit at most one automatic recovery attempt per typed failure and define a
  bounded launch-level budget. The architecture must make an infinite retry
  mechanically impossible.
- App backgrounding, immersive shutdown, and user cancellation during recovery
  have deterministic terminal transitions and resume all waiters exactly once.

The architect may refine state names, but all of these properties are mandatory.

## 9. Low-level MLX requirements

Design an explicit, testable MLX recovery API rather than exposing independent
“clear poison,” “clear cache,” and “reset stream” calls to arbitrary Swift code.

The API must:

1. require exclusive recovery ownership;
2. expose current failure epoch, recovery generation, and MLX in-flight count;
3. prevent new `eval`, `get_command_buffer`, queue creation, or synchronization
   from entering during reset;
4. asynchronously observe or wait for all submitted command buffers to reach a
   terminal completion;
5. dispose or reconstruct exactly the device/stream/queue/fence/encoder state
   selected by the feasibility proof;
6. reconcile allocator and residency-set state with the selected reset;
7. preserve the 64-record diagnostic ring, aggregate, persisted failure JSON,
   and monotonic failure epoch;
8. issue a new recovery generation only after reset completes;
9. run a bounded GPU health probe and return a typed result;
10. expose enough diagnostics to distinguish `recovered`, `probeFailed`,
    `drainTimedOut`, `residencyLeak`, `staleOwner`, and `unsupportedReset`;
11. remain nonthrowing inside Metal completion callbacks;
12. never invoke a C++ exception across a completion callback or C ABI boundary.

If queue/device teardown requires changes to upstream MLX structures, include
the exact C++ lifetime and locking contract. Account for `DeviceStream`'s
destructor behavior and for the process-lifetime allocator. Do not write
pseudocode that calls an undefined “reset MLX” function.

## 10. Swift Qwen requirements

The Swift side must coordinate the low-level state rather than racing it.

Required changes include:

- Replace the provisional consume-on-warm-load circuit-breaker behavior with the
  architected recovery owner.
- Ensure `TuringQwenNativeFreshInstanceScheduler` reports the first typed Metal
  failure immediately, cancels its sibling lane through the existing throwing
  task group, cancels decoder admission, and stops new MLX submissions.
- Ensure `TuringQwenNativeSpeechDecodeCoordinator` releases its active run and
  decoder session even when the failure originated on another lane.
- Ensure independent and shared-residency pool unloads produce explicit receipts
  for lane state, leases, resident resources, active MLX arrays, cache state, and
  ownership release.
- Do not declare drain complete merely because `instances` was emptied.
- Make `TuringCharacterQwenRenderSession.finish` and `cancel` idempotent and
  generation-aware. All ownership waiters must resume exactly once.
- Keep the `TuringQwenCharacterPoolArbiter` blocked until recovery reaches ready
  or unavailable.
- On successful probe, construct an entirely new Fresh pool and lane generation.
  Never reuse old lane engines, KV caches, decoder sessions, sampler state, or
  shared-residency leases.
- On unavailable, return a stable typed error to the app without replaying the
  stale MLX record on every attempted operation.
- Preserve exact first-failure diagnostic identity while separately reporting
  recovery outcome.

## 11. Audible media and story continuity requirements

Qwen compute ownership and audible media ownership are intentionally separate.
The recovery system must not turn a compute failure into an audio cancellation.

`TuringStoryWalkiePlaybackCoordinator.qwenComputeFailed` already contains the
correct core reconciliation shape:

- retain the currently playing generated segment;
- retain already-prepared pending generated segments;
- mark only missing/unpublished segments skipped;
- set `allComputeFinished = true`;
- reconcile to actual terminal playback;
- keep the generated terminal state behind the authored PR start gate when a PR
  cover is still audible.

The final directive must audit every failure route and guarantee that it uses
this terminal-compute reconciliation rather than `runCancelled` for a typed
Qwen failure. `runCancelled` is reserved for actual user/session/app lifecycle
cancellation.

Acceptance behavior when a failure occurs while audio is audible:

1. The endpoint handle is not stopped.
2. The spoken presentation completion remains tied to the endpoint's actual
   completion event.
3. Mind's Eye continues the active audio's mouth track, motion, and blinking.
4. Missing future segments are skipped without filler looping forever.
5. Playback terminates once all published audio completes.
6. Route cleanup cannot cut the parent authored PR.
7. Story progression, microphone leases, progression holds, and interaction
   arbiter state are released exactly once at the correct boundary.

## 12. Mind's Eye ownership requirement

The newest trace also exposed a distinct visual ownership bug. While CatEye PR
`prologue.room.cateye81.hamReceiver.003` was audible, a Dad pre-audio reveal ran
`preAudioRevealReplacement` and disposed CatEye. Later, a Big Mike reveal
disposed an audible Rich portrait. The local worktree now tracks
`ActivePresentation.isAudible` and checks it before continuity promotion or
preview replacement.

Preserve and formally test this contract:

```text
actual audible presentation
    > pre-audio reveal
    > device-selection preview
    > upcoming generated idle
    > authored preparation hint
```

Selecting another device and beginning its Foundation/Qwen computation may
continue. Its pre-audio portrait must be deferred while another PR owns the
card. It may claim the card only at the correct actual-audio transition. A
visual failure always falls back to audio continuation; it never blocks or
stops audio.

Do not use Mind's Eye teardown as part of MLX recovery. Its payload is small and
the owner explicitly removed emergency teardown for it.

## 13. Fail-soft product policy

The owner wants same-launch recovery, but the product must remain coherent even
if the low-level probe says recovery is unsafe.

Specify an honest unavailable mode:

- already-audible PR/generated audio finishes;
- the current Turing turn reaches a terminal result without dead air or filler
  looping;
- ordinary room interactions and the rest of the game continue;
- Qwen-backed microphones are not selectable while unavailable;
- their visuals cannot imply a ready state;
- no automatic new Foundation Models or Qwen request is started;
- the UI does not repeatedly surface the old command-buffer text to the player;
- diagnostics retain the exact failure and recovery result;
- app relaunch naturally starts a new process and recovery generation.

This is the fallback after a bounded recovery failure, not the default response
to the first typed Metal error.

## 14. Diagnostics required from the implementation

Every recovery must emit one bounded summary keyed by:

```text
original Qwen run ID
original recovery generation
new recovery generation, if any
failure epoch
failed command-buffer ID
failure phase/stage/lane/segment/decode ID
first-failure uptime
recovery state transitions and durations
MLX in-flight count at each transition
active generation/decode admission counts
lane and residency release receipts
MLX active/cache/peak memory
process physical footprint and available memory
stream/queue reset counts
health-probe command-buffer ID and result
automatic recovery attempt number
final result: recovered or unavailable with reason
```

Preserve the existing no-text/no-token diagnostic policy. Do not log dialogue,
dictation, prompt content, or generated speech text.

Add a deterministic JSON recovery report alongside the existing
`mlx-metal-last-failure.json`. Persist atomically and bound any history.

The next device log must make these distinctions obvious:

- stale failure replay versus a genuinely new failure epoch;
- low-level drain completion versus Swift task cancellation;
- pool release versus device/stream reset;
- probe success versus full Qwen warm-load success;
- compute failure versus audible playback completion;
- recovery unavailable versus Foundation Models unavailable.

## 15. Required testability hooks

Production recovery cannot be qualified by waiting for random device failures.
Add qualification-only deterministic injection at these boundaries:

1. Fresh lane warm load;
2. initial talker evaluation;
3. dynamic talker row with both lanes active;
4. dynamic code predictor;
5. speech decoder while the other generation lane is active;
6. speech decoder while a generated segment is already audible;
7. Qwen compute while an authored PR is audible;
8. recovery health probe;
9. low-level drain timeout;
10. app background or immersive shutdown during recovery.

Injection must flow through the same typed production failure path after the
injection point. Do not build a separate fake recovery implementation that
bypasses real cancellation, unload, reset, probe, or playback reconciliation.

## 16. Acceptance gates

### 16.1 Host and simulator gates

- Vendored MLX builds for host and visionOS Simulator.
- Full production app target builds.
- The MLX fixed ring remains bounded at 64 and preserves monotonic sequences.
- A synthetic failure increments the epoch once and never throws from the Metal
  completion callback.
- Multiple completions from the failed generation trigger one recovery.
- New admissions are blocked throughout drain/reset/probe.
- In-flight count reaches zero before reset acknowledgment.
- Old-generation completions cannot publish output after recovery begins.
- Independent Fresh2 and shared immutable Fresh2 release every lane and lease.
- Recovery success creates new lane, cache, decoder, sampler, and ownership IDs.
- Probe failure transitions once to unavailable with no recursive retry.
- Every waiter and continuation resumes exactly once.
- Playback failure reconciliation retains audible/prepared segments and skips
  only missing ones.
- A pre-audio reveal cannot detach an audible Mind's Eye card.
- Source audits prove `currentOverlap`, two lanes, model, sampling, and decoder
  serialization remain unchanged.

The current Xcode test target has unrelated stale test-source compile errors
around `primaryGenerator` and runtime lip-sync manifest APIs. The directive must
identify those as pre-existing if still present; it must not hide recovery test
results behind them. Add focused package tests where possible and include the
full app build separately.

### 16.2 Vision Pro gates

Run without debugger first, then repeat under Xcode debugger and video capture.

For each injected phase above:

1. observe one typed failure;
2. observe cancellation and low-level drain;
3. observe the selected reset boundary;
4. observe a successful health probe or an explicit unavailable result;
5. if recovered, submit a new real conversation in the same launch;
6. prove the new conversation uses a new recovery generation and does not replay
   the old command-buffer ID;
7. prove audible media from the failed run was not cut short;
8. prove story interaction remains usable.

Then run:

- ten recovery cycles in one launch using deterministic injection;
- ten ordinary conversations after the final recovered cycle;
- a real long-running mixed workload with no injection;
- at least one failure during dynamic generation and one during speech decode;
- TestFlight-equivalent Release configuration separately from Debug.

Mandatory device assertions:

```text
automatic retry loops                         0
stale failure replays                         0
old-generation output publications           0
audible endpoint stops caused by Qwen failure 0
audible Mind's Eye preview replacements       0
filler/dead-air infinite loops                0
ownership/waiter leaks                        0
peak generation lanes                         2
peak decoder concurrency                      1
same-launch post-recovery successful turns    >= 1 per recovered failure
```

Measure memory before the failure, after lane release, after reset, after probe,
after new warm load, and after final unload. Recovery cannot introduce monotonic
physical-footprint, MLX active-memory, cache-memory, command-queue, or residency
growth across ten cycles.

## 17. Architect decisions that must be explicit

The final directive must answer, not defer, these questions:

1. What exact low-level state is considered poisoned after this Metal error?
2. What exact object graph is destroyed or recreated?
3. How is exclusive access enforced across Swift and C++?
4. How is in-flight-zero proven without blocking the MainActor?
5. What is the timeout, and why is it safe?
6. What health probe runs, on which stream, and what constitutes success?
7. When is the diagnostic failure latch acknowledged?
8. What new-generation identifiers prevent stale publication?
9. How many automatic attempts are allowed per failure and per launch?
10. What exact event moves the product to unavailable?
11. How do independent and shared-residency modes differ during recovery?
12. How does app background/shutdown interrupt or complete recovery?
13. How are audible media, Mind's Eye, microphones, progression holds, and story
    state kept independent from Qwen device recovery?
14. If a full in-process device reset is impossible, what verified alternative
    isolation strategy is used?

## 18. Expected implementation-directive structure

Return one coherent Codex directive with:

1. a strict operating contract requiring implementation rather than another
   handoff;
2. worktree protections for all existing local changes;
3. a repository audit anchored to the exact files and current contracts above;
4. the selected recovery architecture and state machine;
5. exact Swift, C, and C++ API contracts;
6. exact ownership, locking, actor-isolation, and lifetime rules;
7. exact file-by-file changes;
8. deterministic failure-injection hooks;
9. host, simulator, Vision Pro, capture, and Release qualification;
10. source audits proving locked concurrency and model behavior are preserved;
11. a mandatory `PASS`, `BLOCKED`, or `FAIL` completion report.

If the reset strategy cannot be selected without a device spike, split the
directive into a tightly bounded Phase A proof and a Phase B production
implementation. Phase A must not alter shipping behavior, and its result must
mechanically select exactly one Phase B branch. Do not create an open-ended
multi-phase roadmap.

## 19. Current verification status

As of this handoff:

- focused MLX recovery tests: 5/5 pass;
- visionOS Simulator production app build: passes;
- broad Xcode unit-test target: blocked by unrelated existing test API drift;
- provisional low-level acknowledgment after a real Vision Pro failure: not yet
  device-proven;
- true MLX device/stream reconstruction: not implemented;
- same-launch failure -> reset/probe -> successful real conversation: not yet
  proven;
- audible-card preview interruption: locally contained and app-build verified,
  but still requires device confirmation.

Do not describe this feature as production-safe until all required Vision Pro
gates pass.

## 20. Bottom line

The immediate stale-error replay bug is understood: MLX retained and rethrew
`last_failure_` forever. The deeper production question is not whether that
latch can be cleared; it is whether the process-global MLX Metal execution
state can be proven quiescent, reconstructed or safely reused, health-checked,
and re-admitted without corrupting audio or game state.

Design that boundary explicitly. Preserve the intended two-lane pipeline. Let
already-audible media finish. Reject stale generations. Retry once only after a
real reset and probe. If proof fails, degrade honestly without damaging the
rest of the experience.
