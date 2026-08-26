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
