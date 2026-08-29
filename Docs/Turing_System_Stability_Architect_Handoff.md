# Turing System stability and memory optimization handoff

Date: 2026-08-24  
App: Gravitas Plague 3.9 (29), visionOS 27  
Status: the film cut is complete and is in TestFlight. This handoff is about
stabilizing on-device Turing/Qwen execution without changing the authored film.

## 1. Executive summary

The previous released build produced seven crashes. The current report is that
running with Xcode debugging or device video capture can make the app crash, and
Qwen/TTS is believed to occupy roughly 7.5 GB on an 8 GB Vision Pro. The reported
termination signal is usually `SIGABRT`.

Do not conclude that this is an out-of-memory termination from `SIGABRT` alone.
An abort can come from a failed precondition, runtime assertion, allocator failure,
or an explicit abort. A jetsam termination has separate device evidence. The first
job is to correlate all three artifacts from the same run:

1. The symbolicated crash `.ips` report.
2. A same-time `JetsamEvent` or memory-related `EXC_RESOURCE`, if one exists.
3. The new persisted Turing event timeline and last low-level Qwen breadcrumb.

The most consequential current code fact is not speculative: the production
render session requires exactly two fresh Qwen instances. Each instance creates
its own `TuringQwenNativeResidentResources` and base-clone engine. The pool logs
two unique resident-resource stores and two unique weight stores, with
`sharedWeights: false`; fallback to one instance is disabled. This is the first
architecture boundary to measure and challenge.

Polygon reduction may still help GPU and RealityKit pressure, but it should not
precede an A/B measurement of one Qwen instance versus the current Fresh2 setup.

## 2. Current production architecture

The active path is:

```text
TuringCharacterQwenRenderSession.begin
  -> high-memory preflight (release Story scene when an adapter is installed)
  -> acquire Turing ownership
  -> stage the bundled 4-bit Qwen model to writable storage
  -> makeFresh2Pool()
  -> warm-load exactly two independent instances
  -> makeFresh2Scheduler()
  -> render codebooks on two generation lanes
  -> decode speech through the coordinated decoder path
  -> materialize/play audio
  -> unload both instances and clear the MLX cache
```

Relevant implementation:

- `Gravitas Plague/Gravitas Plague/Turing/Flow/TuringCharacterQwenRenderSession.swift`
- `Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeGenerationSchedulerFactory.swift`
- `Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeFreshInstancePool.swift`
- `Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeFreshInstance.swift`
- `Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeSpeechDecodeCoordinator.swift`

Current memory policy details:

- The Fresh2 pre-load gate allows another instance while MLX active memory is
  below 6,500 MB and MLX cache is below 1,500 MB.
- That gate does not inspect `phys_footprint` or `os_proc_available_memory()`.
- Performance mode configures the live MLX cache limit to 512 MB.
- Performance mode does not clear MLX cache every generated row; it does clear at
  segment/release boundaries.
- Diagnostic mode uses a 64 MB cache and per-row diagnostics, but production uses
  performance mode.
- The package also contains shared-weight parallel-lane code, but the production
  path is deliberately on Fresh2 with shared weights disabled. Do not switch to
  the legacy path without proving its thread safety and output correctness.

The high-memory preflight releases the Story scene only when its preparer is
installed. When it is absent, Turing proceeds without a Story-scene release. The
new log distinguishes these two outcomes.

## 3. Instrumentation now in the build

The instrumentation is deliberately bounded and does not persist prompt text or
generated dialogue.

### Durable event timeline

Every launch creates:

```text
Application Support/TuringDiagnostics/
  turing-launch-<unix-time>-<launch-id>.jsonl
```

Each event includes an ISO-8601 timestamp, launch ID, uptime, event kind and
label, optional run ID and segment index, and relevant structured details. Memory
events include:

- process physical footprint;
- process resident size;
- `os_proc_available_memory()`;
- MLX active, cache, and peak memory;
- MLX cache and memory limits;
- active model and quantization when known.

Recorded boundaries include app launch, control-window scene-phase transitions,
thermal-state changes, memory warnings, high-memory preflight, Turing ownership,
Fresh2 warm load, session readiness, stage and segment boundaries, audio
materialization, failures, and unload.

### Crash-surviving low-level breadcrumb

The Qwen package atomically replaces one small file:

```text
Application Support/TuringDiagnostics/qwen-native-last-breadcrumb.json
```

It records the last entered/completed Qwen stage, run/instance/segment IDs where
available, process and MLX memory, and decoder stage. Because it is replaced
atomically, the next launch can report the last successfully persisted boundary
even if the process aborts before normal teardown.

### MetricKit and unified logging

The app subscribes to `MXMetricManagerSubscriber` and stores delivered diagnostic
payloads as `metrickit-diagnostic-*.json`. The SDK marks the newer MetricKit
diagnostic-report API unavailable on visionOS 27, so the legacy subscriber is
intentional for this target.

Unified-log categories are:

```text
subsystem: app bundle identifier, category: TuringProduction
subsystem: com.gravitas.turing, category: QwenNativeBreadcrumb
```

Existing Turing audio-offload signposts remain available for Instruments.

### Export after a TestFlight crash

On a TestFlight or Debug build, relaunch the app and use the waveform/ECG button
in the main room-skinning top ornament. It shares a combined
`Gravitas-Turing-Diagnostics.txt` containing the bounded diagnostic artifacts.
The diagnostics directory is excluded from device backup and retains at most 16
artifacts.

If a MetricKit crash payload has not arrived immediately, leave the app open on
the main menu briefly and reopen the menu before exporting. MetricKit delivery is
asynchronous.

## 4. Required evidence for every reproduced crash

Record:

- TestFlight build number and exact device/visionOS version;
- wall-clock time of the crash, including timezone;
- chapter/point, character, and the last audible or visible action;
- whether Xcode, Instruments, system capture, or neither was attached;
- whether this was the first Turing run since launch or a later run;
- whether the Story scene, portals, and heavyweight props were present;
- the in-app Turing diagnostics export after relaunch;
- the symbolicated `.ips` report;
- every same-time `JetsamEvent`.

Crash reports should be taken from TestFlight/Xcode Organizer or from the Vision
Pro Analytics Data screen. Preserve the archive and matching dSYM for every
TestFlight build.

Apple references:

- Crash reports and device logs: https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs
- Acquiring reports: https://developer.apple.com/documentation/xcode/acquiring-crash-reports-and-diagnostic-logs
- MetricKit: https://developer.apple.com/documentation/metrickit
- Performance signposts: https://developer.apple.com/documentation/os/recording-performance-data
- `OSSignposter`: https://developer.apple.com/documentation/os/ossignposter

## 5. Classification decision table

| Evidence | Working classification | Next action |
| --- | --- | --- |
| `JetsamEvent` names the app at the same time | OS memory-pressure termination | Use the timeline to identify the high-water stage and compare one-instance/Fresh2 runs. |
| `.ips` has `EXC_CRASH (SIGABRT)` and Application Specific Information or a stack at `precondition`/`fatalError` | Assertion or invariant failure | Fix the named invariant/race before treating it as a memory optimization problem. |
| `.ips` ends in malloc, Metal, or MLX abort with no jetsam record | Allocator/runtime abort, possibly caused by pressure | Correlate process available memory, physical footprint, MLX peak, and the last decoder breadcrumb. |
| Memory warning followed by steep footprint growth and incomplete unload | Leak or retained lifecycle state | Compare the first and subsequent Turing runs and audit owners that survive teardown. |
| Stable post-run baseline but a large spike at one stage | Transient peak | Serialize or chunk that stage and prevent generation/decode/RealityKit peaks from overlapping. |
| No memory evidence and a repeatable Qwen stage/segment | Logic/data-dependent abort | Reproduce the same input/seed in an optimized device build and inspect the symbolicated stack. |

There are intentional `precondition` calls in the Turing flow, interaction,
audio, rendered-codebook, and release-ledger paths. They are another reason not to
label every `SIGABRT` as OOM.

## 6. Ranked hypotheses

1. **Two independent resident Qwen stores.** Fresh2 is explicitly two unique
   weight/resource owners. Measure the second warm load's physical-footprint delta.
2. **Transient overlap.** Two codebook-generation lanes, decoder work, buffered
   CPU codebooks/PCM, portals, and RealityKit resources may overlap at the peak.
3. **Lifecycle retention.** A completed run, model instance, generated buffer,
   portal, or scene resource may remain owned into the next point/run.
4. **Assertion or race.** The symptom is `SIGABRT`, and the code contains
   preconditions. This remains a first-class hypothesis until the stack says
   otherwise.
5. **MLX cache.** Production permits up to 512 MB of MLX cache. It matters at the
   margin but cannot by itself explain an observed 7.5 GB working set.
6. **RealityKit geometry/materials.** Props and portals can reduce headroom,
   especially during capture, but should be isolated after the Qwen ownership A/B.

## 7. Profiling and experiment matrix

Run on the lowest-memory supported Vision Pro configuration. Begin with an
optimized/Release device build, no debugger and no capture. Do not use an Xcode
Debug run as the baseline because the user already reports that instrumentation
overhead changes the outcome.

For every row, run the same chapter path and deterministic TTS input/seed:

| Variant | Qwen ownership | World load | Purpose |
| --- | --- | --- | --- |
| A | Current Fresh2, independent weights | Current film | Establish current peak and failure rate. |
| B | One fresh instance, serialized generation | Current film | Measure the memory cost and latency benefit lost from instance 2. |
| C | Two lanes with one immutable shared weight/resource owner | Current film | Determine whether concurrency can survive without duplicated residency. |
| D | Best stable Qwen variant | Portals/heavy props disabled | Isolate RealityKit contribution. |
| E | Best stable Qwen variant | Current film, system capture on | Measure capture headroom only after A-D are stable. |

Capture at least these points:

```text
app launch
before and after Story-scene preflight
before instance 0 load
after instance 0 load
after instance 1 load
before/after initial talker forward
before/after dynamic codebook generation
before each speech-decoder eval stage
after PCM/audio materialization
after playback enqueue/completion
before/after Fresh pool unload and MLX cache clear
```

Use Instruments Allocations and VM Tracker first. Add Metal System Trace and
RealityKit-specific investigation when variant D shows material savings. Use the
existing signposts to align CPU/audio offload with the persisted boundaries.

## 8. Recommended architect work order

### Phase 0: classify, do not guess

Obtain one complete artifact set and identify whether the failure is jetsam,
assertion, allocator/Metal/MLX abort, or another crash. Reproduce the exact failing
stage if the breadcrumb is stable across reports.

### Phase 1: remove the mandatory two-instance cliff

Add a production-safe one-instance scheduler and make lane count adaptive. The
decision must use whole-process signals (`phys_footprint` and
`os_proc_available_memory()`), not only MLX active/cache memory. If headroom is
insufficient before the second warm load, remain on one instance rather than
aborting the session.

This is an architecture change, so preserve exact segment ordering, deterministic
seeds, decoder serialization, release-ledger correctness, and audio quality.

### Phase 2: share immutable residency where safe

Prove which tokenizer, config, safetensor mapping, weight tensors, codec decoder,
and reference artifacts are immutable. Give those resources one explicit owner
and let lane-local engines own only mutable generation state. Do not share mutable
KV caches, sampling contexts, release ledgers, or decoder workspaces.

If safe shared residency cannot be proved quickly, keep one serialized engine. A
slower stable path is preferable to a mandatory duplicate 7+ GB working set.

### Phase 3: bound transient working sets

- Do not retain MLX codebook tensors after compact CPU codebooks are materialized.
- Bound the number of rendered-but-not-decoded segments.
- Release decoded PCM as soon as playback ownership transfers.
- Ensure generation and decoder peaks do not overlap when headroom is low.
- Verify cache clear actually lowers MLX cache and whether physical footprint
  returns; cache clearing is not proof that resident allocations were released.
- Use scoped autorelease pools around large Foundation/Audio conversions where
  Objective-C temporaries exist.

### Phase 4: audit scene and portal ownership

After the Qwen variants are measured, verify that high-memory preflight releases
the intended Story resources in every entry path. Track portal textures,
environment resources, prepared animation state, meshes/materials, audio buffers,
and hidden entities by owner. A hidden or detached entity may still retain GPU and
CPU resources.

### Phase 5: model changes only if still necessary

The model is already a 4-bit Qwen variant. Consider additional quantization,
smaller model variants, or quality-affecting changes only after duplicate ownership
and transient overlap are fixed and measured.

## 9. Proposed acceptance gate

Before releasing the optimized Turing architecture:

- Ten consecutive end-to-end device runs in an optimized build complete without
  crash, hang, missing segment, or ordering change.
- Repeat the ten-run suite both from a cold launch and through repeated Turing
  sessions without relaunching.
- No run depends on debugger attachment or system capture being disabled for
  correctness; capture may reduce performance but must not crash the process.
- At every logged Turing boundary, preserve a proposed minimum of 1 GB process
  available-memory headroom. Adjust this threshold only from measured device data.
- After unload, physical footprint returns to within 10% of the first-run post-
  unload baseline. Continued monotonic growth fails the gate.
- The second Fresh instance, if retained, has a measured and justified latency
  benefit large enough to offset its incremental peak memory.
- Audio samples, deterministic seeds, segment order, and authored playback timing
  pass the existing acceptance comparison.

## 10. First questions the crash evidence must answer

1. Does a jetsam record exist at the exact crash time?
2. What is the symbolicated aborting thread and Application Specific Information?
3. What footprint delta occurs between `session.beforeFresh2WarmLoad` and
   `session.afterFresh2WarmLoad`, and between instance 0 and instance 1?
4. Does `os_proc_available_memory()` collapse before the second warm load, initial
   talker forward, dynamic codebook, or decoder evaluation?
5. Does a second Turing run begin from a higher baseline than the first?
6. Did high-memory preflight release the Story scene, or complete with no adapter?
7. Does disabling portals/props materially change the peak after Qwen ownership is
   held constant?

Those answers determine whether the first implementation patch should be an
assertion fix, a one-instance fallback, shared immutable weights, tighter pipeline
backpressure, or a RealityKit ownership cleanup.

## 11. Device incident update: 2026-08-29

This is now a living handoff. The following evidence comes from one complete
on-device console capture supplied after the Mind's Eye runtime and runtime TTS
lip-sync integration. Preserve these facts in the next architect directive; do
not replace them with a generic memory-pressure assumption.

### 11.1 Exact terminal failure

The final process output is:

```text
libc++abi: terminating due to uncaught exception of type std::runtime_error:
[METAL] Command buffer execution failed: Impacting Interactivity
(0000000e:kIOGPUCommandBufferCallbackErrorImpactingInteractivity)
```

This is direct evidence of an uncaught MLX/Metal command-buffer failure. It is
not evidence of a Swift precondition, an authored-image file-size failure, or a
jetsam termination. A matching symbolicated `.ips` and same-time Jetsam search
are still required, but optimization work should now treat Metal scheduling and
MLX command-buffer behavior as a first-class path alongside memory residency.

The vendored runtime is MLX Swift/core 0.31.1. In its Metal backend,
`mlx/backend/metal/eval.cpp` installs command-buffer completion handlers that
call `check_error`; `check_error` throws `std::runtime_error` when the command
buffer status is error. The supplied console termination text matches that
function's message exactly. The architect must determine how to prevent this
Metal failure and how to contain/report a failed command buffer without an
uncaught exception escaping a Metal completion callback. Do not simply swallow
the failure and continue with undefined tensors.

### 11.2 Where the abort occurred

The app completed one full six-segment Big Mike live response during the same
launch. It then began a second five-segment Big Mike response. On the second
response:

- Fresh2 started two independent instances and initially rendered segments 0
  and 1 on lanes 0 and 1.
- Segments 0 through 3 were generated and published far enough for playback.
- At the terminal moment, generated segment 3 was audibly playing and its
  Mind's Eye mouth track was active.
- Fresh instance 0 was generating segment 4. The log reached talker positions
  176, 184, 192, and 200, with dynamic codebook checkpoints after each group.
- The most recent render-phase entry for segment 4 reported
  `activeRenderCount: 1`; this was not a moment with two simultaneous codebook
  renderers according to the app's own phase counter.
- The serialized speech decoder for segment 3 had completed before the abort.

Therefore, “two lanes were simultaneously evaluating at the exact crash line”
is not established by this log. Two full Fresh2 instances were still resident,
RealityKit remained live, generated audio was playing, and the Mind's Eye GPU
compositor/motion path was active. The qualification plan must distinguish
resident duplication from concurrent GPU execution and from command-buffer
duration/scheduling.

### 11.3 Measured memory in this run

The highest persisted process snapshot in the supplied log was:

```text
label: qwen.segment.renderStarted
phys_footprint_MB: 5488
resident_size_MB: 1639
os_proc_available_memory_MB: 2703
mlx_active_MB: 3619
mlx_cache_MB: 135
mlx_peak_MB: 3754
```

The last persisted snapshot near segment 4 start was:

```text
label: qwen.segment.renderStarted
phys_footprint_MB: 4933
resident_size_MB: 1597
os_proc_available_memory_MB: 3258
mlx_active_MB: 3104
mlx_cache_MB: 1
mlx_peak_MB: 3611
```

After segment 3 decode/materialization, another snapshot reported roughly
5,060 MB physical footprint, 3,131 MB process-available memory, 3,178 MB MLX
active memory, and a 3,694 MB MLX peak. There was no logged collapse to the
8,192 MB process high-water mark before this abort. This does not prove memory
was irrelevant—GPU residency and capture/debug overhead still matter—but this
specific console ending must not be relabeled as a confirmed OOM.

### 11.4 Mind's Eye payload versus runtime residency

The artist's compressed package is only a few megabytes, but the runtime log
reports decoded source texture totals of approximately:

```text
Big Mike: 127,733,760 bytes
Rich:     139,677,696 bytes
```

Those values reflect decoded GPU source layers, not PNG file size. Loading the
Big Mike package during the second Qwen run coincided with process footprint
moving through roughly 4.7–4.9 GB while MLX active memory was about 3.2 GB. That
is worth measuring, but it is still much smaller than the Qwen working set and
does not by itself explain the terminal Metal error.

### 11.5 Separate functional defects found in the same log

These are functional correctness bugs, not proposed Qwen optimizations:

1. High-memory preflight explicitly unregistered the active authored mouth
   track, stopped Mind's Eye motion, detached the card, released its package,
   and evicted the authored track while the PR lifecycle was still active. It
   occurred for both Big Mike and Rich. The reports said
   `activeRetained: false` and `activeReleased: true`. This is the exact cause
   of the portrait disappearing during TTS computation.
2. Runtime phoneme generation failed ten times with
   `PocketSphinx resource tree hash mismatch`, causing amplitude fallback.
   Runtime validation hashed the `en-us` directory while the manifest/source
   lock was generated from its parent `pocketsphinx-5.1.1` directory. The bytes
   existed; the relative paths used by the two hashes differed.

The current stabilization worktree corrects only those two functional issues:

- an active authored PR is retained through Qwen preflight and its authored
  mouth, blink, and motion animation continues until the PR's real completion
  event; exact child speaker/surface validation remains required before a
  generated portrait can reuse that card;
- runtime PocketSphinx validation hashes and byte-counts the same versioned
  model root as the source lock.

No Qwen lane count, model, cache policy, command-buffer threshold, scheduler,
quantization, Metal priority, or generation algorithm is changed by that
stabilization patch.

## 12. Tests to run before the architect chooses an optimization

### Functional stabilization gate

Run the exact Big Mike script-point-01 path and the Rich-to-Big-Mike
script-point-02 path. During the interval between transcript submission and the
authored PR completion, require:

```text
[MindEyePresentation] authored portrait retained for generated handoff
activeRetained: true
activeReleased: false
```

There must be no `playback unregistered`, `keep-alive stopped`, `dynamic visual
detached`, authored-track release, or package release with a `qwenPreflight.*`
reason for the active authored PR. Its authored mouth poses, blink scheduler,
and motion must continue in sync with the resumed PR audio. Pausing while the
audio itself is paused for player dictation is valid; remaining paused or being
destroyed after audible PR playback resumes is not.

For a cross-speaker handoff, the current Rich portrait may finish its authored
PR and remain visible during silence, but it must be replaced by Big Mike before
Big Mike filler or generated speech becomes audible. Never drive Rich's mouth
with Big Mike audio and never substitute Big Mike while Rich is still speaking.

For every generated segment, require a successful runtime phoneme result and no
resource-tree mismatch. Record whether the result was phoneme-authored or
amplitude fallback; fallback is an observable degradation, not a silent pass.

### Current local stabilization verification

The 2026-08-29 stabilization worktree has passed an arm64 visionOS Simulator
Debug app build with heavyweight resources excluded from the disposable build
product. The first universal-simulator attempt reached link and failed only
because the checked-in `TuringPocketSphinx` static library has no x86_64 slice;
the arm64-only rerun linked and completed successfully. This is a build-tooling
constraint, not a failure in the changed Swift sources.

`verify_pocketsphinx_vendor.py` also reports `PASS` with resource-tree SHA-256
`e2ca8da1fecfd4a676fbd3d68537c705688b669b30ddaa1cb78dd1850e4fe12d`,
matching the source lock now used by the runtime locator.

The full unit-test target does not currently build because unrelated, existing
tests are stale against current production contracts. Examples include actor
test doubles conforming to newly MainActor-isolated protocols,
`TuringPhase0Tests` using removed scheduler initializer arguments, and
generated-playback/lip-sync tests using superseded initializer/result shapes.
`MindEyeHighMemoryPreflightTests.swift`, including the new authored-PR retention
source audit, compiled before the wider target failed. Do not attribute the
full test-bundle build failure to this stabilization patch; repair or isolate
those stale tests before using the entire suite as a release gate.

### Reproduction matrix for the architect

Use identical conversation text, deterministic seeds, chapter state, and audio
route for every row. First run each row without changing Qwen code:

| Row | Build/run environment | Mind's Eye | Repetition | Purpose |
| --- | --- | --- | --- | --- |
| 1 | Release, no debugger or capture | Enabled, fully animated | Two consecutive live responses | Reproduce the supplied failure under the intended shipping load. |
| 2 | Release, no debugger or capture | Disabled by a qualification flag | Two responses | Isolate Mind's Eye GPU/residency contribution without changing Qwen. |
| 3 | Release, no debugger or capture | Enabled, composition and motion measured separately | Two responses | Separate package residency, compositor work, and motion cadence. |
| 4 | Release under Xcode | Enabled | Two responses | Measure debugger overhead after rows 1–3. |
| 5 | Release with device capture | Enabled | Two responses | Measure capture pressure after rows 1–3. |
| 6 | TestFlight-equivalent archive | Enabled | Ten cold and ten repeated runs | Establish release behavior and failure rate. |

For every row, collect the app diagnostics export, symbolicated `.ips`, same-time
Jetsam search, Metal System Trace, VM Tracker/physical-footprint trace, thermal
state, and exact timestamps. Add signposts or labels that identify each MLX
command buffer's segment, lane, talker position range, encoded operation count,
encoded byte estimate, submission time, completion time/status, and concurrent
RealityKit/Mind's Eye frame work.

The architect's first deliverable is a diagnosis and experiment plan grounded
in this matrix. Do not prescribe command-buffer limits, serial lanes, shared
weights, lower-quality models, frozen imagery, or cache changes until the A/B
evidence identifies which boundary changes the failure.

## 13. Standing mandate for subsequent incidents

Treat this runtime as a device-specific systems project, not as a conventional
application-layer TTS integration. The repository contains a custom realtime
Qwen3-TTS Base implementation, a custom two-instance scheduler, a custom speech
decoder integration, a runtime phoneme aligner, and a continuously composited
RealityKit portrait. Running that combination interactively on Vision Pro is a
high-risk deployment even if each subsystem passes independently.

Future crash work is authorized to add bounded diagnostics, persisted
breadcrumbs, signposts, counters, experiment flags, and new factual findings to
this handoff. It is not authorization to tune Qwen, reduce quality, suppress
animation, change model output, or broadly rewrite the pipeline before the
failure boundary is measured.

Every optimization proposal must retain this chain:

```text
observed evidence
  -> falsifiable hypothesis
  -> one isolated experimental variable
  -> device measurement
  -> quality/correctness comparison
  -> keep or revert decision
```

Do not accept a change merely because one run stopped crashing. Record its
effect on physical footprint, MLX active/cache memory, GPU command duration,
time to first playable audio, steady-state generation rate, audio quality,
segment ordering, Mind's Eye continuity, and repeated-run baseline.

## 14. Revised priority order for the largest gains

This section refines the older work order using the 2026-08-29 incident and a
fresh source audit. Priority 0 is instrumentation and failure containment. The
remaining priorities are ranked by the combination of observed relevance and
potential gain, not by ease of implementation.

| Priority | Boundary | Why it is high value | Required proof before retaining a change |
| --- | --- | --- | --- |
| 0 | MLX/Metal failure attribution and safe propagation | The actual terminal event is an uncaught exception thrown from an MLX Metal completion handler. Without the failed command buffer's identity, every optimization is guesswork. | Capture the failed buffer's stream, lane, segment, phase, row range, last primitive labels, operation/byte estimates, timings, and Metal error without allowing a C++ exception to escape the callback. |
| 1 | MLX command-buffer duration and GPU interactivity | The OS reported `kIOGPUCommandBufferCallbackErrorImpactingInteractivity`. The initial talker and decoder already contain manual materialization/chunking, proving this boundary has been encountered before. The remaining dynamic talker/code-predictor path is now the leading incident-specific suspect. | A controlled command-buffer-boundary A/B eliminates the Metal error across repeated runs and Metal System Trace shows bounded GPU duration without changing output tokens. |
| 2 | Duplicate Qwen resident weights | Fresh2 owns two independent `TuringQwenNativeResidentResources` and two independent `TuringQwenNativeWeightsStore` values. This is the largest visible footprint opportunity. | Measure the per-instance warm-load delta, then prove one immutable resident owner or a one-instance path materially lowers peak footprint with identical deterministic output. |
| 3 | Actual lane/stream semantics and adaptive concurrency | Fresh2 requires exactly two instances, has no fallback, and launches two Swift workers, but Turing's current lane abstraction is `defaultOnly`; the production path does not install lane-specific MLX streams. The architect must establish whether work serializes, interleaves into one default stream, or produces useful GPU concurrency. | Log real MLX stream/queue identities and compare one lane, Fresh2 default-stream, and deliberately isolated-stream variants. Retain concurrency only when it improves playable-audio latency without increasing watchdog failures. |
| 4 | Cross-stage backpressure and GPU arbitration | Fresh generation bypasses the legacy generation/decode gate. Decoder execution is serialized, but a decoder or published segment can overlap another lane's generation, Mind's Eye composition, playback, and runtime lip sync. | Record every overlap and queue depth. Bound work in flight and demonstrate lower peak command duration/footprint with no audio underrun. |
| 5 | Mind's Eye compositor coexistence | While visible, motion publishes on every RealityKit rendering update. Each accepted frame dispatches a full 1920 x 1080 compute pass reading background, base, eyes, mouth, and mask, with one buffer in flight and one latest frame pending. This can compete with MLX despite the compressed art being small. | A/B fully animated Mind's Eye on/off, then test measured cadence/bandwidth variants that preserve continuous authored motion and mouth timing. Do not freeze or remove the portrait as a shipping fix. |
| 6 | Speech decoder residency and transient stages | The speech-tokenizer weights are substantial, decoder stages load Float32 tensors, and the decoder deliberately materializes/clears between high-water stages. It is not implicated at the terminal instant of this incident, but it can create major earlier peaks. | Attribute peak bytes and GPU time to each decoder stage and prove whether residency reuse, narrower precision, or stricter generation/decode exclusion lowers the end-to-end peak. |
| 7 | PCM, file materialization, and runtime lip sync | Runtime analysis is CPU-side and capped, so it is unlikely to explain multi-gigabyte MLX residency. It still retains/copies PCM, resamples, hashes, aligns, refines boundaries, and runs at user-initiated QoS while Qwen and Mind's Eye remain active. | Persist queue delay, retained bytes, cold/warm aligner time, CPU time, and overlap. Optimize only if it contributes measurable latency, CPU pressure, copies, or frame loss. |
| 8 | Writable model staging and file/page-cache behavior | The bundled model is copied to Application Support even though production primarily reads it. The two largest files total 2,331,531,515 bytes. This can affect cold-start I/O, storage, and page cache, though the stage was reused in the supplied repeated-run crash. | Compare direct read-only bundle loading and writable staging on cold/warm launches; retain a change only if the runtime truly does not require mutation and package validation remains exact. |
| 9 | World assets and model-quality reductions | Portals, props, meshes, and textures reduce headroom, but Qwen and GPU scheduling have stronger direct evidence. Smaller models or lower quality may save more only after architecture waste is removed. | Hold the chosen Qwen architecture constant, measure world-load deltas, and treat any model/quality change as a last resort with listening tests. |

### 14.1 Highest-priority low-level MLX work

The vendored MLX core currently performs this sequence in
`mlx/backend/metal/eval.cpp`:

1. encode lazy MLX work into a stream command buffer;
2. install a completion handler;
3. call `check_error` from that handler;
4. throw `std::runtime_error` when Metal reports an error.

A C++ exception escaping a Metal completion callback terminates the process.
The architect should design a non-throwing callback boundary that records the
complete failure, satisfies MLX scheduler completion bookkeeping, invalidates
affected results, and surfaces a typed failure at a controlled Swift/C++ call
boundary. Merely swallowing the Metal error is prohibited because downstream
tensors may be invalid.

The vendored MLX device already has two command-buffer split controls:

```text
MLX_MAX_OPS_PER_BUFFER
MLX_MAX_MB_PER_BUFFER
```

Their defaults are selected from the reported GPU architecture and are commonly
40 operations / 40 MB for the `g` or unknown/default cases. They are read when
the MLX Metal device is constructed. Therefore an experiment must:

- log the actual device architecture string and resolved limits;
- set experimental values before the first MLX GPU device access;
- record operation and byte counts for every committed buffer;
- compare GPU duration and output parity, not only crash/no-crash;
- distinguish a buffer containing too many operations from one individual
  kernel that exceeds the interactivity budget by itself.

If lower aggregate thresholds do not shorten the failed buffer, isolate and
chunk the offending primitive. The speech decoder already replaces a stock
transposed-convolution path with bounded contributions because the stock kernel
could monopolize the GPU. Initial talker forward also materializes per layer.
The 2026-08-29 failure occurred during dynamic codebook generation after the
preceding decoder had completed, so dynamic talker/code-predictor attention,
quantized matrix multiplication, sampling synchronization, and KV-cache growth
deserve command-level attribution before further decoder changes.

### 14.2 Largest probable footprint gain

The current model package contains:

```text
model.safetensors:                  1,649,238,423 bytes
speech_tokenizer/model.safetensors:   682,293,092 bytes
combined:                           2,331,531,515 bytes
```

Disk bytes do not equal active GPU bytes, but Fresh2 explicitly constructs two
independent main-model weight stores. On-device logs also state
`uniqueResidentResources: 2`, `uniqueWeightStores: 2`, and
`sharedWeights: false`. The repository already contains a separate shared
resident-resource lane design, but it is not the production path and must not be
enabled without concurrency and output validation.

The preferred experiment sequence is:

1. one fresh instance, fully serialized, as the memory and correctness control;
2. two logical lanes sharing exactly one immutable resident resource owner while
   keeping KV caches, sampling contexts, segment state, and release ledgers local;
3. current Fresh2 as the latency control.

This experiment can reveal whether the second full owner buys real latency on a
single Vision Pro GPU. If two independent owners are resident but MLX ultimately
serializes most work through one default stream, Fresh2 may pay nearly the full
memory cost without receiving equivalent concurrency.

The current pre-warm memory gate is not an adequate device-safety decision. It
allows another instance while MLX active memory is below 6,500 MB and MLX cache
is below 1,500 MB, ignores physical footprint and
`os_proc_available_memory()`, and cannot fall back because `fallbackAllowed` is
false. An eventual adaptive gate should use measured incremental warm-load cost,
whole-process headroom, thermal state, capture/debug overhead, and a safe reserve.

### 14.3 Highest-priority pipeline work

The target pipeline should have explicit bounded ownership at every edge:

```text
text segments
  -> generation lease
  -> compact CPU codebook rows
  -> decoder lease
  -> one file-backed playable clip
  -> optional bounded lip-sync analysis lease
  -> playback completion and release
```

For each edge, define a maximum item count, maximum bytes, cancellation owner,
and release event. Specifically measure and then bound:

- submitted but not started text segments;
- rendered CPU codebooks waiting for the decoder;
- decoder workspaces and Float32 stage tensors;
- decoded `[Float]` PCM awaiting postprocessing or file writing;
- processed PCM retained by runtime lip sync;
- file-backed generated clips queued ahead of playback;
- Mind's Eye manifests/tracks waiting to join audible audio.

Fresh2 currently advertises `globalRenderBarrier: false` and
`freshPathUsesLegacyDecodeGate: false`. A lane can enter the serialized decoder
after releasing its render while another lane continues generation. This overlap
may improve latency, but it must become a headroom-aware decision rather than an
unconditional property. Under low headroom or high GPU duration, generation,
decoder, and the 1920 x 1080 Mind's Eye compositor may need a shared GPU budget
or phase-aware admission policy.

The audio contract remains dominant: never interrupt audible authored playback,
never reorder segments, and never create an underrun merely to lower a memory
number. Backpressure belongs ahead of excess work, not in the currently audible
segment.

### 14.4 Runtime lip-sync optimization scope

The production lip-sync path is already serial, off-main, and bounded to three
queued jobs and 16 MB of retained Float PCM. It uses a 750 ms to 2 s compute
budget, a 4 s maximum queue delay, and a 6 s maximum total latency. It performs:

```text
decoded Float PCM retention
  -> sanitization/downmix
  -> resampling and PCM16 conversion
  -> PCM SHA-256
  -> PocketSphinx forced alignment or all-phone fallback
  -> boundary refinement against final PCM
  -> sparse manifest construction
```

This path should be instrumented, but it is a lower-probability cause of the
multi-gigabyte peak because its explicit retained-PCM budget is small and it
does not use MLX. Potential wins are reducing duplicate PCM ownership, avoiding
an unnecessary second full-audio scan, keeping the PocketSphinx engine warm only
when justified, lowering analysis QoS during fragile GPU windows, and feeding
the aligner from the canonical postprocessed buffer without extra copies.

Before any such work, log per segment:

- input/output sample counts and retained bytes;
- buffer ownership transitions and concurrent retained copies;
- queue delay, cold engine initialization, forced-align pass, fallback pass,
  boundary refinement, and total time;
- whether alignment overlapped Qwen generation, speech decoding, audio-file
  writing, Mind's Eye composition, or audible playback;
- phoneme-authored versus amplitude-fallback outcome and late-join result.

The 2026-08-29 PocketSphinx failures were a resource-tree hash bug, not a
performance failure. Re-measure the corrected path before optimizing it.

## 15. Required low-level diagnostic additions

These additions are intended to survive future crashes without collecting
dialogue text or unbounded logs.

### MLX command-buffer ring

Persist a fixed-size ring containing at least the last 32 submitted/completed
MLX command buffers. Every record should contain:

- monotonically increasing buffer ID;
- MLX stream index and Metal command-queue identity/label;
- current Turing run, lane, instance, segment, and dynamic row range;
- current high-level phase: warm load, initial talker, dynamic talker,
  code predictor, decoder stage, cache clear, or unload;
- operation count and encoded-byte estimate used by MLX's split policy;
- first/last primitive label and a bounded list or hash of included labels;
- submit uptime, GPU start/end time when available, completion uptime, and total
  duration;
- number of MLX and app Metal buffers already in flight at submission;
- completion status, Metal error domain/code/localized description, and the
  current process/MLX memory snapshot;
- actual GPU architecture and resolved command-buffer split limits.

Write the latest failure record synchronously to the existing atomic breadcrumb
path or a sibling file before returning from the completion callback. Normal
successful records may be batched to avoid turning diagnostics into a new
performance problem.

### Unified cross-pipeline timeline

Add common IDs and signposts for:

```text
Qwen generation lane
speech decoder
audio postprocessor/file writer
runtime lip-sync analysis
Mind's Eye compositor
RealityKit frame interval
```

At every transition include queue depth, bytes owned, and whether each other
GPU/CPU-heavy subsystem is active. The next crash report must be able to answer
“what else was running?” from one timeline rather than by visually correlating
several console streams.

### Residency ownership ledger

At warm load and unload, log stable owner IDs and measured bytes for:

- each main-model weight store;
- each resolved talker/code-predictor weight set;
- each lane's talker and code-predictor KV caches;
- the speech-decoder session and active stage;
- static prompt-context caches;
- MLX active/cache allocations;
- Mind's Eye source textures and output texture;
- decoded and analysis PCM.

Object identifiers alone prove uniqueness but not allocation size. Pair them
with deltas measured immediately before/after ownership changes and again after
cache clear plus a short quiescent period.

## 16. Controlled experiment order

Run one variable at a time with the same deterministic text, seeds, story point,
speaker, world state, and audio route. Each row requires cold-launch and repeated
second-run samples.

1. **Unmodified Release baseline:** reproduce with full animation, no debugger,
   no capture, and the new diagnostics only.
2. **Command-buffer boundary sweep:** change only MLX operation/byte split limits.
   Stop if output changes or latency becomes unusable.
3. **Mind's Eye GPU isolation:** compare full current composition, composition
   disabled by qualification flag, and a measured lower compositor cadence while
   motion state continues to advance. This is diagnostic, not permission to ship
   a frozen portrait.
4. **One-instance control:** one resident owner and serialized segments, with all
   visuals and lip sync enabled.
5. **Shared-residency lanes:** one immutable weight owner with lane-local mutable
   state; compare one versus two admitted lanes.
6. **Generation/decode exclusion:** preserve Fresh2 ownership but prevent decoder
   and generation GPU overlap. This isolates overlap from duplicate residency.
7. **Pipeline backpressure:** bound one queue at a time and record first-audio and
   underrun behavior.
8. **Runtime lip-sync isolation:** compare corrected phoneme alignment enabled,
   compatibility amplitude analysis only, and analysis disabled under a
   qualification flag. Preserve generated audio in every row.
9. **World-load isolation:** only after the Qwen/Metal variants above, compare
   portals and expensive props.
10. **Debugger, capture, and TestFlight:** qualify the best evidence-backed
    architecture under overhead after no-debugger Release behavior is stable.

The best likely production direction, if the measurements support it, is one
immutable Qwen weight owner, adaptive one/two-lane execution, lane-local mutable
generation state, bounded codebook/decoder/PCM queues, explicit MLX command-buffer
budgets, a non-throwing low-level Metal completion boundary, and coordinated GPU
admission for MLX and Mind's Eye. This is a hypothesis to validate, not a patch
directive.

## 17. Template for every future crash update

Append one incident section rather than overwriting earlier evidence:

```text
Incident ID / date / build:
Device / visionOS / thermal state:
Release, TestFlight, Xcode, Instruments, or capture:
Cold launch or repeated Turing run:
Story point / speaker / world assets active:
Last audible event and last visible event:
Exact exception / termination reason:
Symbolicated failing thread:
Matching Jetsam or EXC_RESOURCE evidence:
Last durable Turing breadcrumb:
Last MLX command-buffer record:
Highest and last phys_footprint / available memory:
Highest and last MLX active / cache / peak:
Active generation lane(s), decoder, lip sync, compositor, and playback:
Queue depths and retained bytes at failure:
Difference from prior incidents:
New fact, hypothesis, and single next A/B test:
Optimization performed: none unless separately approved and measured
```

Keep contradictions. If one crash is a Metal interactivity abort and another is
jetsam, treat them as two failure classes rather than forcing both into one
memory narrative.
