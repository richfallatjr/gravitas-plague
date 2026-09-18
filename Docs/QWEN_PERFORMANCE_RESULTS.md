# Qwen performance results — updated 2026-09-18

Current source default: **BF16 generation, explicitly approved by the owner**
for normal shipping, without a separate scheme or toggle. Engineering status
remains **DEVICE_QUALIFICATION_PENDING**: the two-pair M2 first screen is
`OUTPUT_LENGTH_REVIEW`, not completed all-voice/full-scene/quality qualification.
The latest shipping-default decision is recorded at the end; earlier opt-in and
pending statements below describe their historical checkpoints.

## Implemented and verified locally

| Work | Status | Evidence |
| --- | --- | --- |
| Allocator-TU fingerprint, Mach-O UUIDs, build/source/model/voice provenance | HOST_VALIDATED | Native wrapper compiled; scoped O0 hardening probes and provenance unit tests |
| Bounded prompt and fixed-code decoder runners | HOST_VALIDATED | Real model/voice scouts with caps, failure attempts retained, ordered readiness and actual ownership recorded |
| Opt-in phase/dtype markers | HOST_VALIDATED | Disabled-path tests and no-added-materialization source audit |
| Complete-run command-buffer accounting | HOST_VALIDATED | Ring wrap, overlapping windows, late completion, capacity and invalid-timestamp tests |
| Scoped hardening A/B selector | MATCHED_DEVICE_SCOUT_COMPLETE | Six same-source Big Mike scouts, exact PCM parity, 28.35% lower median Debug render time; no claimed shipping speedup |
| F1 persistent positional decoder reader | HOST_VALIDATED, opt-in only | Small-file tests plus identical real decoder and Fresh2 PCM |
| Device qualification launch | Build passed | Explicit compiler flag + launch request required; no shipping button |
| C2 generation BF16 containment | OWNER-APPROVED SHIPPING SOURCE DEFAULT; DEVICE_QUALIFICATION_PENDING | Mike sample listening approved; two-pair M2 first screen, changed output length, broader numerical/voice/full-scene/recovery gates remain open |
| D/E/G/H fused attention, predictor plans/workspace, kernels/state reuse | NOT IMPLEMENTED | Require measured target selection; decision record distinguishes proposals from code |

The foundation still lacks actual player-start/ordered-needed app signposts and
a recovered six-segment `device-fixed-request` fixture. Native publication
markers do not pretend to be audible playback. Typical/long/all-five-voice,
full-scene, quality and device recovery qualification remain outstanding.

## Tests

- 27 focused native tests passed: seven positional-reader XCTest cases, five
  workload tests, five marker tests, ten command-buffer/capture tests.
- 32 Python tests passed: twelve provenance and twenty phase-audit/comparison.
- Eleven additional native recovery/cancellation regression tests passed.
- Phase 2R recovery source audit passed.
- The older Phase 2 source audit fails a stale `unloadAll` token expectation in
  FreshInstanceScheduler; that token was already absent in HEAD before this
  change. No runtime change was made to satisfy this obsolete text assertion.
- Debug native package and visionOS device app compile. A first device build
  used a global Swift-condition override and was explicitly rejected for
  qualification because it clobbered the package recovery define. The corrected
  build uses an additive Swift compiler flag and preserves the actual native
  recovery define. Provenance must be captured from the corrected build.

## Real host scouts — correctness only, not device promotion

Machine: local Mac, Debug Cmlx, DEBUG libc++ internal assertions enabled.
Cold driver/filesystem state and competing build work were not controlled.
This tiny fixture is not meaningful sustained speech throughput.

| Attempt | Decoder wall s | Sampled peak footprint MiB | PCM SHA256 |
| --- | ---: | ---: | --- |
| decoder-legacy-04 | 6.418 | 532.8 | `08947fbd490a3f06666ad8c60f37c96347d6110455eab6a7de3aff4db5f7cb87` |
| decoder-positional-01 | 1.657 | 375.3 | same |
| decoder-legacy-05 | 1.046 | 516.9 | same |
| decoder-positional-02 | 0.454 | 268.1 | same |

Every successful decoder scout produced 7,680 trimmed Float PCM samples at
24 kHz. Each had 93 submitted/completed buffers, zero pending and zero failures.
Candidate counters: one persistent data descriptor, 381 positional reads,
422,820,612 bytes, zero EINTR; the index-header open is outside that counter.
The strong cold/warm variation prevents attributing the timing differences to
the candidate alone. Four additional metadata syscalls per tensor/row family
are a potential tradeoff, not free work.

Three two-segment/four-row Fresh2 host scouts also completed. Both generated
segments match **exactly** between legacy and candidate:

- Segment 0: `adb9cf282a5e50100ed6afa812f65d8c0843b636cf803984354c4f12c73e90ab`
- Segment 1: `36fe8acf4669ed6a49b7127a29e09914d270cff9a246b6414381e78ee56a6013`

Legacy wall times were 16.965 and 6.686 seconds; candidate was 8.323 seconds.
These are plainly **not** a repeatable matched speedup result. Actual ownership
was two lanes/two stores/one decoder, no fallback. Legacy and candidate exported
zero MLX active/cache bytes after teardown, and zero command-buffer failures.
Candidate segment 1 completed first; ordered readiness correctly held both
segments until segment 0 was ready, without changing scheduler/playback logic.

## Failed development attempts are retained

`decoder-legacy-01`: harness queried configuration before MLX device startup.
`decoder-legacy-02`: provenance assumed a nonexistent tokenizer.json instead of
the runtime's actual vocab/merges/config inputs. Both stopped before generation.
`decoder-legacy-03`: cooperative cap stopped before model loading because the
new hashing loop retained autoreleased Foundation buffers. Fixed by draining
each 1 MiB chunk; the successful rerun's initial footprint was about 6.9 MiB.
This was a new harness defect, not an existing inference-memory finding.

Reports, attempt logs and failed attempts remain under
`/private/tmp/qwen-performance-20260917/`. No failed/slow attempts were omitted
from a promotion decision. The comparison exporter remains fail-closed on
missing provenance, missing quality/full-scene/recovery evidence, insufficient
paired repetitions or incomparable conditions.

## Prepared Vision Pro build

The final additive-flag device build passed and was re-signed with unchanged
entitlements; strict code-signature verification passed. Manifest:
`/private/tmp/qwen-device-debug-build-manifest.json`; actual compile-command
sidecar uses the same stem with `.commands.json`. The final pre-build source
snapshot and post-build source identity match; both linked binary timestamps
follow the snapshot. Captured commands include allocator (1), native Swift (3),
app Swift (3), Metal (2). Workload hash matches the real host export:
`087841bc22069bac7e81ab7cdf55683f9b7db164c903d86b224ce34ebd8c1278`.

Device build log: `/private/tmp/qwen-visionos-qualification-build-stamped.log`.
Pre-build source: `/private/tmp/qwen-prebuild-source-stamped.json`.
Prepared request: `/private/tmp/qwen-device-requests/request.json`.
Installed UUID/payload/runtime parity and the controlled device run still must
be verified. Build success and a valid signature do not satisfy those gates.

The signed build was subsequently installed successfully on the Vision Pro
(`device-install.json` in the artifact directory). No benchmark was launched:
the headset reports `passcodeRequired: true` and needs the owner to unlock it.
The candidate stays opt-in; normal launches do not start the qualification view.

## First physical-device scout — September 17, evening

After the owner unlocked the Vision Pro, the isolated app-hosted Big Mike
two-segment/four-row control completed without a debugger or profiler attached.
Report: `/private/tmp/qwen-performance-20260917/big-mike-control-20260917-01.json`.

- Render wall: 5.5263 s; model load: 0.8660 s; first-needed PCM: 5.5175 s.
- This is only 0.64 s of deliberately row-capped raw PCM, **not sustained RTF**
  or complete-dialogue/voice-quality evidence.
- Observed two lanes, two weight stores, one decoder, peak render concurrency
  two, no fallback. No player or gameplay timeline was exercised.
- 1,995 command buffers submitted and completed; zero failures or pending.
- Sampled peak physical footprint 3,739.96 MiB, post-teardown 332.19 MiB;
  MLX active/cache bytes both zero after teardown. Thermal state nominal.
- Actual allocator fingerprint: named `shipping-default`, DEBUG hardening,
  internal assertions enabled, unoptimized. Installed Mach-O UUIDs matched.

The strict provenance check correctly rejected this first report because the
new harness used Foundation's collated JSON key ordering for installed inventory
hashes while the host used Python's literal key ordering. Feeding the expected
inventories through Foundation exactly reproduced **both** device hashes;
the signed local bundle's complete file inventories also matched the manifest.
This is a measurement-format defect, not evidence of changed model/voice data.
The original report is retained unmodified and unqualified. A deterministic
cross-language inventory serializer plus regression tests replaces the faulty
serializer for fresh runs; the verifier is not relaxed.

### Matched hardening builds prepared

Three additional native inventory-serialization tests pass. All twelve Python
provenance tests also pass after adding `.xcconfig` to source-identity coverage.

Two signed Debug builds now pass the strict `compare-hardening` build comparison
with no differences outside the intended Cmlx hardening experiment. Both use
the same source identity:
`7b283f049716ecc3d2477d7a1eec5aef32eeffb28998fa15e77a171c3e5d1b7b`.
Both retain Cmlx `-O0`, Swift `-Onone`, existing recovery qualification, coverage
instrumentation, MLX test macros, Fresh2, and unchanged shader commands.

- Control: `hardening-debug-control-canonical-05.manifest.json` and signed
  `hardening-debug-control-05.app` under the artifact directory.
- Candidate: `hardening-fast-only-canonical-05.manifest.json` and signed
  `hardening-fast-only-05.app` under the same directory.
- These app snapshots use APFS copy-on-write clones, not new model copies in
  the repository. They are development-test artifacts, not shipping archives.
- The actual control allocator command selects DEBUG; candidate selects FAST.
  Both explicit overrides remain scoped to Cmlx. Ordinary builds do not load
  either experiment xcconfig.
- Both source snapshots match post-build source, both builds succeeded, and
  signature verification passed. Installed runtime verification is still
  required for **each** build; matching compile commands alone is not a pass.

Earlier experiment attempts are retained, not used as performance evidence:
environment-only builds `control-01/02` retained `shipping-default`; the first
parameterized xcconfig candidate attempts `fast-03/04` retained DEBUG settings.
The build log and compiled-command gate exposed this before candidate install.
Two immutable named xcconfig paths with literal settings resolve the observed
Xcode build-setting reuse. No package cache deletion or global setting change
was needed.

The first named-control request preparation also reused a request filename as
its output filename. The existing no-overwrite guard stopped it before compute;
the retrieved `big-mike-debug-canonical-01.json` is a **request**, not a benchmark
report. New requests use distinct `report-*` outputs. A second launch waited
while the headset locked and its host launch command was terminated; neither
attempt supplies timing evidence. The original successful scout above remains
the only completed device measurement at this point.

The headset then locked/disconnected before the final matched-control install.
Both builds are ready for the owner to unlock/wear the device again. The scoped
device runner `/private/tmp/qwen-performance-20260917/run-device-scout.sh` checks
request/output separation, refuses local overwrite, enforces a 180-second
external watchdog, retrieves the report, and runs strict provenance verification.
No on-device hardening speedup or production promotion is claimed.

## Matched on-device hardening scout — September 17, 19:36–19:39

The owner returned wearing/unlocking the headset. All six unique `readyb`
reports pass strict canonical-05 provenance. The actual installed allocator
fingerprints confirm DEBUG/internal assertions enabled versus FAST/internal
assertions disabled, with Cmlx **unoptimized in both**. Compiler comparison
passes with the remaining settings unchanged. No debugger/profiler was attached
for these six measurements; thermal state was nominal throughout.

| Run | Render s | First-needed PCM s | Sampled peak MiB | Residual MiB | Max GPU-buffer ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| DEBUG 01 | 7.2577 | 7.2491 | 3741.7 | 398.6 | 62.44 |
| DEBUG 02 | 4.6689 | 4.6598 | 3782.5 | 324.0 | 51.92 |
| DEBUG 03 | 4.7265 | 4.7189 | 3745.9 | 403.6 | 54.95 |
| FAST 01 | 5.8736 | 5.8639 | 3781.8 | 359.3 | 54.58 |
| FAST 02 | 3.3683 | 3.3567 | 3784.6 | 405.0 | 54.60 |
| FAST 03 | 3.3864 | 3.3755 | 3785.6 | 326.8 | 51.42 |

Median render **4.7265 → 3.3864 s**, a **28.35% reduction in this tiny Debug
scout**, not a sustained or shipping TTS speedup claim. Both groups' first runs
are slower and remain included. The groups ran sequentially, three per mode;
driver/filesystem warmth is not controlled. Median sampled peak footprint rose
about 1.03%; this is not evidence of a memory improvement.

All six produced precisely two 7,680-sample segments at 24 kHz. PCM hashes match
by segment across both builds: segment 0 `b5da4226c4d5f90dc8467c9d7baddc5a61e464aeef51de984b99e6162c22e95e`,
segment 1 `4078caaaac5350414e3aa44e492272255159104102c296821023c3523a42ee22`.
Observed Fresh2 is two lanes/two weight stores/one decoder, peak render
concurrency two, no fallback or admission violation. Ordered readiness retains
the correct prefix maximum even when segment 1 finishes first. All submitted
GPU buffers completed; zero failures/pending/missing/invalid timestamps. MLX
active and cache bytes are zero after teardown.

Artifact names: `report-big-mike-{debug,fast}-readyb-01.json` through `-03.json`
in `/private/tmp/qwen-performance-20260917/`. Separate `run-*.provenance.json`
files retain strict verification output for each run. Independent audit agrees.

The first reinstall attempt timed out at 60 seconds; a later retry succeeded.
The earlier `report-big-mike-debug-canonical-01.json` verifies against **03**,
not 05, and is excluded from the comparison. `...canonical-02.json` on device
predated the current launch (remote mtime 19:29): a previously queued launch had
completed when the headset was unlocked. It too is excluded, not a new 05 run.
The device inventory before `readyb` proves none of the six fresh report names
existed. No earlier output is deleted or silently mixed into the comparison.

Outstanding: profiled allocator confirmation, optimized Release baseline,
representative complete dialogue, all voices, quality, recovery/full-scene and
energy qualification. No change has been promoted to ordinary Debug defaults.

### CPU trace attempt — host save failure, not a device crash

A separate FAST run launched under Time Profiler with phase markers enabled.
`report-big-mike-fast-profile-readyb-01.json` passed strict build provenance,
completed with identical PCM and no GPU failures, and measured 3.7184 s render /
3.7059 s first-needed PCM. This instrumented sample is **not** included in the
unprofiled table or median.

xctrace recorded for 25 seconds but failed while saving, then aborted with
`NSGenericException` naming the Instruments `Packages/lock` path. No trace
directory survived and no CPU samples could be recovered. Raw failure details
are retained in `fast-readyb-01-trace-save-failure.txt` in the artifact directory.
Host free disk at failure was about 2.8 GiB; that is a constraint, **not** a
proven cause of the lock exception. The device app did not crash.

The DEBUG control canonical-05 was restored after the capture attempt; the
experimental FAST build is not left installed as an unqualified gameplay
default. Device interaction is complete for this session. The next measurement
checkpoint is fixing the host trace-save problem, obtaining the allocator CPU
confirmation, and measuring a separately labeled optimized Release baseline.

### Owner-requested disk cleanup

The temporary `hardening-debug-control-04.app`,
`hardening-debug-control-05.app`, and `hardening-fast-only-05.app` snapshots
were deleted to reclaim disk space, along with rebuildable Xcode Build output
for Gravitas Plague and Gravitas Crunch. The exact tested app binaries are no
longer available on the host; their manifests, expanded compile-command records,
build logs, device reports, and provenance results remain. The original
`gravitas-tts-profile-20260917.um2OWO` CPU trace and exports were preserved.
The installed device app and repository source/assets were not removed.
APFS sharing means logical artifact sizes overstate reclaimed physical space;
host available space initially increased from about 2.8 to 6.5 GiB.

The owner's subsequent Release build exhausted disk again: both resource copy
and Swift object-file output failed with `No space left on device`. The latest
Xcode activity log (`5C78BC07-F495-42D3-BEBC-A0020AA89240.xcactivitylog`) contained
no separate Swift source error. A 3.7 GiB Debug product had been regenerated
before the Release attempt. That unused Debug product was removed while the
partial Release products and intermediates were retained. Additional cleanup
removed ignored Qwen host-test output, inactive Crunch module/index caches,
an old pre-video Crunch build, and two closed temporary Xcode export-staging
directories. No source, art, audio, saves, archives, or profiling evidence was
removed. Open Instruments data and an unidentified standalone trace were
preserved. Available space increased from about 505 MiB to 10 GiB before the
Release retry. Its build log is retained as
`/private/tmp/qwen-performance-20260917/release-disk-recovery-build.log`.

The retry completed with `BUILD SUCCEEDED` using the normal Release
configuration and generic visionOS destination. The previously failed
`chapter03.walkie.rich.connectsMen.002.mouthframes.json` resource matches the
source byte for byte. About 7.1 GiB remained free with the completed Release
app retained. This is build validation only, not installed-device performance
qualification. No new gameplay or Qwen execution-path edits were needed for
the disk-space recovery.

## Subsequent in-game observation and C1 checkpoint

Owner feedback: approximately 15–33% faster, with the PR compute-ahead buffer
working well. This is a useful subjective observation, **not** a matched A/B
measurement or a claim of realtime/Crunch readiness. The current source was
clean at `2db19ce4d363687617c1988c9cada21b16273631` before C1 work began.

Evidence: owner log
`/Users/richardfallat/.codex/attachments/1c9c249d-d8bb-421d-920e-a2f50066a136/pasted-text.txt`.

| Complete run prefix | Segments | Render wall s | Raw audio s | RTF |
| --- | ---: | ---: | ---: | ---: |
| ED9F | 5 | 47.995 | 24.240 | 1.980 |
| EC19 | 6 | 45.224 | 20.400 | 2.217 |
| EE9F | 6 | 47.716 | 23.520 | 2.029 |
| 8773 | 6 | 40.774 | 16.160 | 2.523 |

The four summaries cover 23 segments, 181.709 seconds of wall time and 84.320
seconds of raw generated audio (pooled RTF approximately 2.155). They report
161,126 submitted/completed command buffers, zero buffer failures, no fallback,
two independent stores/two rendering lanes/one decoder, and `currentOverlap`.
The fifth run is truncated at EOF: neither completion nor failure is inferred.
The selected profile is `deviceDefault`, resolved to 40 operations / 40 MB;
this differs from the earlier 40 operations / 32 MB Debug experiment.
The text log has no installed build/source fingerprint, so configuration alone
cannot prove Release provenance or attribute the observed improvement to one
change. No matched pre-change text/workload is present.

Generation and decoding both remain substantial. Per-run sums of segment decode
time are about 28–32 seconds, but overlap with generation and cannot be divided
by run wall time to claim independent phase percentages. Lazy work can also be
charged to later materialization boundaries. A fresh optimized CPU/GPU profile
is still required to rank the residual bottleneck. A three-second local
Time Profiler save smoke test completed successfully; it only verifies that
host trace saving worked for that attempt, not device profiling or hotspot
removal.

C1 preparation follows the handoff's first proposed arithmetic-preserving
candidate, not a newly measured claim that conversions are the largest cost.
The default production policy remains legacy. The experimental fixed hotset
contains only 102 predictor BF16 scale/bias tensors widened to FP32 once at
owner load, capped at 16 MiB per independent store; packed weights and original
BF16 companions remain unchanged. Full Fresh2 reports now retain each owner's
load/end cache evidence and reject absent/unmaterialized/unused/stale fallback
as a successful candidate scout. These counters describe selections, not
observed GPU conversion-kernel elimination.

### C1 implementation and host verification

Status: **HOST_VALIDATED for the bounded C1 mechanism;
DEVICE_QUALIFICATION_PENDING; NOT PROMOTED.** Normal gameplay still selects
legacy arithmetic. No Fresh2, scheduling, recovery, voice, audio, PR-buffer,
or scene behavior was changed. All artifacts below are under
`/private/tmp/qwen-performance-20260917/`.

- Focused Debug native tests: 11 conversion-cache XCTest cases plus nine Swift
  Testing cases (four cache-qualification, five workload/readiness) passed.
  Coverage includes exact CPU/GPU quantized matmul output, BF16 widening edge
  bits, immutable packed/original data, dtype eligibility, budgets, missing
  tensors/layouts, independent ownership, stale/context rejection, cancellation,
  and lazy-output validity after owner teardown. Log:
  `c1-native-cache-tests-debug-01.log`.
- Python performance tests: 23 passed; build-provenance tests: 12 passed.
  Logs: `c1-python-performance-tests.log`, `c1-python-provenance-tests.log`.
- Optimized native benchmark product built successfully:
  `c1-host-release-benchmark-build-01.log`.
- Normal visionOS Release app built successfully:
  `c1-visionos-release-build-01.log`. Strict deep codesign verification passed.
  This was a host build, not a new installation/device test or candidate enable.
- Earlier build attempts are retained: `c1-native-cache-tests-01.log` exposed
  ambiguous Foundation/MLX `Stream` references in new code, corrected to
  `MLX.Stream`. `c1-native-cache-tests-02.log` then compiled the Release native
  library but failed in pre-existing tests that reference Debug-only stream and
  recovery hooks. Those hooks and tests were not changed or hidden. Debug is
  the correctness-test configuration; Release is the benchmark configuration.

The Apple M4 Mac ran six serial pairs with the same Release executable UUID
`A8499920-7DA8-398C-B3A5-946C4F9725B6`, optimized FAST allocator fingerprint,
`deviceDefault` 40/40 profile, model/voice/payload identities, workload and seed.
Order was AB, BA, AB, BA, AB, BA. The two-segment/four-row Big Mike workload
produces only 0.64 seconds of raw audio. This is **not** sustained RTF or voice
quality qualification. Reports omit the embedded `buildManifest`, so complete
source/compile provenance qualification is also pending.

| Pair | Control render s | C1 render s | Paired wall-time reduction |
| --- | ---: | ---: | ---: |
| 01 | 3.874952 | 1.825216 | 52.90% — initial outlier, not a speed claim |
| 02 | 1.886035 | 1.815093 | 3.76% |
| 03 | 1.881569 | 1.796148 | 4.54% |
| 04 | 1.885915 | 1.838793 | 2.50% |
| 05 | 1.837334 | 1.766096 | 3.88% |
| 06 | 1.838190 | 1.800153 | 2.07% |

All-six render medians: 1.883742 → 1.807623 seconds (4.04% lower).
Subsequent-five medians: 1.881569 → 1.800153 seconds (4.33% lower);
median paired reduction across those five is 3.76%. Median load-inclusive
reduction is only 2.68% across all six, 2.64% for subsequent five. Median load
time increased about 10 ms. Every report says filesystem/driver warmth is
uncontrolled: the first-pair effect is retained, not treated as a controlled
cold measurement, and subsequent runs are not proven warm runs.

All 12 reports match PCM bit-for-bit **by segment index**, not completion order:

- Segment 0, 7,680 samples/24 kHz:
  `adb9cf282a5e50100ed6afa812f65d8c0843b636cf803984354c4f12c73e90ab`.
- Segment 1, 7,680 samples/24 kHz:
  `36fe8acf4669ed6a49b7127a29e09914d270cff9a246b6414381e78ee56a6013`.

Every C1 store materialized all 102 companions (14,024,704 bytes / 13.375 MiB)
in 3.536–3.965 ms. Each gained 1,996 render hits, 224 dtype misses and 2,220
eligibility checks after load. Dtype misses deliberately use the original
BF16 path; no context, stale-generation or unavailable misses occurred. Both
independent owners retained their revision/generation/context/inventory through
render. All buffers completed, with zero failures or pending buffers.

Peak render/decode concurrency was 2/1, with two stores and no fallback.
The recorded cross-segment overlap counter was zero: **these scouts do not
qualify production generation/decoder overlap.** The counter observes render
state at decoder acquisition rather than measuring GPU execution overlap.

Memory is a promotion gate, not dismissed as negligible:

- All-six sampled process-peak median: 3,766.83 → 3,806.92 MiB (+40.09 MiB).
- Scheduler MLX-active peak: 3,101.56 → 3,128.28 MiB (+26.72 MiB).
- Immediate post-unload MLX active/cache bytes: zero in all runs.
- Process residual: control 516.97–1,527.82 MiB; C1 1,339.64–1,726.08 MiB.
  This variability neither proves a leak nor proves complete reclamation;
  repeated-run device physical footprint and allocator/driver attribution remain
  required. The zero MLX count is not a substitute for those measurements.

### Extended bounded correctness attempts

`c1-host-{broadcaster,cateye81}-{control,candidate}-01.json` completed with
identical per-segment PCM and no Metal failures. These are one-pair checks, not
speed or listening-quality acceptance.

`c1-host-{dad,rich}-{control,candidate}-01.json` all ended
`FAILED_OR_BUDGET_STOPPED`: the existing four-row fixture limit was reached
without EOS, and each voice's existing quality policy rejected the segment
before decode. Both policies behaved the same, with zero GPU failures. No PCM
parity or five-voice completion is claimed for those voices. Do not remove the
EOS policy to make a microbenchmark green; use appropriately bounded complete
utterances for their next qualification runs.

The additional four-segment/eight-row queue-refill fixture is checked in as
`Tools/Turing/Performance/Workloads/big_mike-overlap-4x8.json`.
`c1-host-overlap-{control,candidate}-01.json` completed with all four PCM hashes
identical, 15,360 samples per segment, 2.56 seconds total audio, zero failures,
and 7,984 C1 hits per store. Render time was 7.257729 → 6.402813 seconds in this
single pair; it is not a repeated/cold-matched speed estimate. Concurrency
remained 2/1 but the overlap counter still read zero. The fixture's intended
overlap stress is therefore **not proven**; instrument actual phase intervals
in the next device run rather than relabeling this as an overlap pass.

Next work is controlled optimized Vision Pro profiling/qualification, including
actual conversion-kernel reduction, complete five-voice utterances, sustained
compute/decoder overlap, cold/warm and repeated-run memory, quality, recovery,
and full-scene frame timing. This implementation does not establish realtime,
RTF ≤1, or Crunch readiness. The owner's working gameplay policy remains intact.

## September 18 — controlled Vision Pro C1 scout

Decision: **C1 NOT PROMOTED.** Five matched device pairs establish correctness
for this bounded workload, but do not demonstrate a reliable speed improvement.
The existing production legacy policy, independent Fresh2 and PR buffer remain
unchanged. This is not a claim that every longer workload would behave the same.

The owner supplied a ready, wired Vision Pro (RealityDevice14,1, visionOS 27.0
24M5361a). A fresh Release qualification build used the additive
`GR_QWEN_PERFORMANCE_QUALIFICATION` flag with the normal
`GR_TURING_METAL_STREAM_RECOVERY` backend and optimized FAST allocator. No Debug
build or alternate hardening mode was substituted. Source snapshot, successful
build log and all four required compiler-command categories were captured.
Both policies used executable UUID `C78384C5-9AE4-371C-82C6-F2C880596B8A`.
The same executable was re-stamped/re-signed per policy because strict existing
provenance requires the embedded runtime contract to equal the selected policy.
No source/runtime changes occurred between those stamps.

All artifacts remain in `/private/tmp/qwen-performance-20260917/`:

- `c1-device-release-01.source.json` and `c1-device-release-01.build.log`.
- `c1-device-{control,candidate}.manifest.json` and command sidecars.
- `report-big-mike-c1-{control,candidate}-device-{01..05}.json`, plus launch,
  transfer, driver and strict provenance results for each attempt.
- `c1-device-experiment.json`: observed run IDs and verified AB/BA order.
- `c1-device-comparison-01.json`: initial strict comparator output, retained.
- `c1-device-comparison-02.json`: corrected hardware-identity screen, with the
  same reports, experiment and numerical results. The exporter previously
  searched for the word "vision" and rejected the real `RealityDevice14,1`
  identifier. After all device work, the host-only comparer was narrowly fixed
  to accept exact physical-family identifiers and reject Mac/simulator labels;
  26 performance tests pass. This changes no measured/runtime behavior and
  grants no qualification waiver. Both outputs remain comparable, with full
  qualification pending and insufficient repetitions across all five voices.

The workload was the same two-segment/four-row Big Mike fixture used on the Mac:
0.64 seconds of raw audio, not a sustained complete-dialogue acceptance test.
Runs were fresh processes, profiler unattached, phase markers off, isolated
from the immersive scene, with deviceDefault resolving to 40 operations / 40 MB.
Every run started and ended at thermal state Fair. Filesystem/driver warmth
and clocks within that thermal category remain uncontrolled.

| Pair / order | Control render s | C1 render s | C1 / control |
| --- | ---: | ---: | ---: |
| 1 / AB | 2.838173 | 3.102566 | 1.093156 |
| 2 / BA | 3.024118 | 2.989618 | 0.988592 |
| 3 / AB | 3.120735 | 3.066271 | 0.982548 |
| 4 / BA | 3.169972 | 3.049932 | 0.962132 |
| 5 / AB | 2.926788 | 2.939271 | 1.004265 |

Median **paired** render ratio is 0.988592 (1.14% lower time), with the defined
95% bootstrap interval [0.962132, 1.093156]. This crosses no improvement and
does not meet the proposed 3% screening threshold. Independently calculated
side medians are 3.024118 seconds control and 3.049932 seconds C1; the median
of paired ratios is not the ratio of those two medians. First-needed PCM side
medians are 3.013972 / 3.043935 seconds. Cold-load medians are 0.537313 /
0.552846 seconds; load-inclusive medians are 3.563598 / 3.620291 seconds.
Neither the first slower pair nor any other attempt was discarded.

Every installed export passed strict build provenance. Source, binary,
compiler, model, voice, workload and sampling identities match between policies.
All ten PCM payloads are identical by segment index: 7,680 samples each at
24 kHz, with device hashes
`b5da4226c4d5f90dc8467c9d7baddc5a61e464aeef51de984b99e6162c22e95e`
and `4078caaaac5350414e3aa44e492272255159104102c296821023c3523a42ee22`.
Cross-platform Mac/device bit identity is not claimed or required by this pair.

All runs retained two lanes, two independent weight stores and one decoder,
with no fallback or remaining leases. Every C1 store materialized 102
companions / 14,024,704 bytes, gained 1,996 render hits and 224 intentional
dtype misses, and had zero stale/context/unavailable misses. Owner, model
revision, generation and inventory were stable. There were zero GPU failures
or pending buffers. Total submitted/completed buffers were 14,120 control and
12,701 C1; fewer buffers is not proof of attributed GPU speed or eliminated
conversion-kernel counts.

Sampled process-peak medians were 3,803.44 / 3,824.25 MiB. Immediate residual
process footprint varied: control 344.91–425.64 MiB, C1 338.45–419.16 MiB;
MLX active/cache residual bytes were zero throughout. Full-scene memory headroom,
same-launch repeated-run behavior, five-voice quality, recovery stress and
sustained generation/decoder overlap remain unqualified.

### Profiling failure, preserved evidence and restoration

After the ten unprofiled runs, a separate 15-second Time Profiler launch used
the C1 request with phase markers enabled. The app completed successfully with
the same PCM, zero GPU failures, and 3.314875 seconds render wall time. That
instrumented timing is **excluded** from the comparison.

The Mac `xctrace` process then aborted while saving with `NSGenericException`:
`Attempt to lock .../Instruments/Packages/lock failed unexpectedly` (exit 134).
The immediate attempt to copy the device report also failed with ENOSPC. Host
free space briefly dropped to about 101 MiB, then recovered automatically after
the profiler exited; no user files or unrelated Instruments captures were
deleted. The observations do not isolate the package-lock exception's cause.
No valid saved Time Profiler trace survived, so no new CPU/GPU hotspot finding
is claimed.

The successful app report was recovered afterward as
`report-big-mike-c1-candidate-profile-01-recovered.json` and passed strict
provenance. Raw failure details are in
`c1-device-candidate-profile-01.driver.log`. The control profiling request was
not launched. Further captures were stopped rather than repeated blindly.

The verified, signed normal pre-test Release app was restored from the local
APFS clone. The install command timed out, but a fresh installed-app query
confirmed a new container containing `c1-production-restore.app` under the
correct bundle ID, version 4.3 build 33; no reinstall was blindly repeated.
Automatic normal launch also timed out and no Plague process was observed.
The follow-up lock-state query reported `passcodeRequired: true`; the user can
unlock and open the normal app manually. Installation is confirmed; a restored
running main-menu session is not claimed. Saves/resources were not removed.

Next checkpoint: resolve the Instruments save/temporary-space problem before
another wearing session, obtain a usable optimized device phase trace, then
rank the remaining handoff candidates. Do not promote C1 from the Mac result or
these statistically inconclusive microbenchmarks.

## September 18 — largest-cost attribution, not another promoted optimization

The owner requested largest expected end-to-end gains first. The preserved
original large hotspot was 52.02% of sampled Qwen/MLX CPU time in DEBUG tree
verification, not a remaining 54% wall-time slowdown. Current Release control
fingerprints FAST/optimized/internalAssertionsEnabled=false. See the decisions
document for the superseding investigation order and measured-versus-inferred
boundary.

Implemented opt-in in-memory recording of the existing diagnostic scopes,
stage labels, shape/dtype metadata and explicit cap/drop accounting. Report
serialization stays after the measured work. No new tensor evaluation, waits,
scheduling or production arithmetic changes. Completed per-segment generation
and decode timers are now exported rather than discarded by the bounded
report. Comparisons reject differing phase-instrumentation states.

Validation: native Release executable build succeeded; 17 focused Swift tests,
31 performance Python tests and the source audit passed. Normal gameplay has no
recording session and retains the legacy arithmetic/Fresh2/currentOverlap path.
No device build/install or source-asset changes occurred in this turn.

### Larger isolated M4 workload

Fixture `big_mike-phase-attribution-4x32.json`: four segments, each capped at 32
generated rows, production reference prefix unchanged. All four decodes recorded
56 input rows: 24 reference plus 32 generated. Total raw output 10.24 s.

| Condition | Render s | First-needed PCM s | Sampled peak MiB |
| --- | ---: | ---: | ---: |
| Phase recording on, profiler unattached | 7.734984 | 3.752959 | 4012.28 |
| Phase recording off, profiler unattached | 7.556536 | 3.992704 | 3879.11 |
| Phase recording on, Time Profiler attached | 8.011315 | 4.328059 | 4018.49 |

These are three differently instrumented individual runs, **not an optimization
A/B or a reliable instrumentation-overhead estimate**. Their PCM hashes match
by segment, all have zero GPU failures and preserve two generation lanes/two
stores/one decoder. Host performance is not a headset forecast.

The first report contains 1,092 completed scopes, 140 metadata records and 12
events; 892 scopes and 31,568 metadata inspections were capped. No scope was
pending or had invalid timestamps. Recorded inner-stage/I/O durations are
samples, not complete cost partitions. Outer generation/decoder elapsed
intervals overlap and cannot be added into a percentage of request wall time.

The trace confirms the FP32 promotion mechanism in the sampled generation path:
BF16 step Q/K projections widen to FP32 after RoPE; sampled subsequent attention,
projections, predictor inputs and caches are FP32. Decoder intervals overlap
generation substantially. See the decisions document for the interval unions
and why C2 now takes priority over small conversion caches or predictor-graph
construction tweaks.

Evidence under `/private/tmp/qwen-performance-20260917/`:

- `phase-attribution-host-4x32-01.json` and `...-off-01.json`, their logs and
  attempt reports.
- `phase-attribution-release-build-02.log`, `phase-attribution-tests-02.log`,
  `phase-attribution-python-tests-01.log`.

### Host profiling save recovered; device save remains unproven

A minimal 3-second host smoke saved/exported an 8.3 MiB trace, albeit recording
exit 54 after killing its sleep target at the limit. Evidence is in
`/private/tmp/qwen-host-trace-save-20260918.FTV6wo/RESULT.md`.

A subsequent actual native Release workload saved successfully and recording
exited **0**. The app completed synthesis before the 20-second cap. Saved trace,
report, CPU export and analysis are in
`/private/tmp/qwen-host-cpu-20260918.E2pT48/`. This demonstrates host profiling now
works; it does not establish that device capture save/disk failures are fixed.
No shared Instruments state or unrelated trace was deleted.

The full-process CPU export has 7.797 sampled CPU seconds and no
`__tree_sub_invariant` samples. Its leading all-process SHA256 cost is benchmark
provenance hashing before the timed render, not a production TTS optimization
target. Native/MLX stacks cover 4.219 sampled CPU seconds. Do not turn nested
diagnostic wrapper stacks or GPU waits into independent CPU cost percentages.

The narrower CPU analysis records 2.332 sampled CPU seconds in dynamic
generation, 0.454 in decoder stacks, and 0.168 in the native safetensors reader.
These inclusive groups overlap. Ordinary allocation/free work remains spread
across symbols; no new removable 50%-scale bottleneck was established. The
trace retains one `Data stream: Time Mapping` issue. Use `cpu-refined.json` and
`RESULT.md` in that directory, not the old generic analyzer's broad diagnostic
wrapper or allocator-template pattern totals, to interpret this capture.

### September 18 — full production-segment benchmark preflight

Owner requirement supersedes row-truncated scouts for performance decisions.
New fixture `big_mike-production-response-full.json` contains all five exact
accepted texts from real response ED9F0AF5-7303-42F2-AE7E-B4922FE26E84.
The production ceiling stays 160 rows, with natural EOS required per segment.
Final native report validation also rejects skipped EOS-before-audio segments;
the gameplay scheduler itself was not changed. Python comparison independently
checks complete PCM/timing coverage, EOS and row counts. Legacy fixture hashes
remain unchanged.

Local Release preflight completed all five segments naturally: 48, 68, 52, 60
and 75 generated rows; 24.24 seconds raw audio, 19.110919 seconds render wall,
6.471183 seconds first-needed PCM. This single M4 run validates the harness,
not a headset speedup or optimization A/B. Fresh2/two stores/one decoder and
currentOverlap remain intact; each segment retained 159 conditioning reference
rows and the separate 24-row decoder prefix. No production arithmetic change.
All 53,429 command buffers completed with zero failures or pending buffers.
Sampled peak physical footprint was 4,756.43 MiB.

Validation: 20 focused Swift tests, 46 performance Python tests and 14 provenance
tests passed. Evidence under `/private/tmp/qwen-device-phase-20260918.CYleSb/`
includes `full-segment-host-01.json`, its log and attempt record, and test/build
logs. A missing explicit return in the first local compile was repaired; the
failed compile log is preserved. Vision Pro full-segment measurement remains
pending; do not infer device results from this preflight.

### September 18 — two complete Vision Pro replays, normal app restored

The owner wore/unlocked the M2 Vision Pro for two fresh-process full-response
replays. The exact Release build and installed export passed provenance checks;
both reports also passed independent completion/telemetry validation. Neither
run enabled a new arithmetic optimization: `.legacy`, independentFresh2,
two lanes/two stores/one decoder, currentOverlap, production performance mode,
greedy sampling, full 159-row conditioning and the 24-row decoder prefix remain
unchanged. The current deviceDefault resolves to 40 operations / 40 MB.

| Metric | Run 01 | Run 02 |
| --- | ---: | ---: |
| Full segments / natural EOS | 5 / 5 | 5 / 5 |
| Raw speech duration, s | 24.240 | 24.240 |
| Render wall, s | 19.075721 | 18.980802 |
| Raw-audio RTF | 0.786952 | 0.783036 |
| First-needed PCM from render start, s | 6.918619 | 6.810206 |
| Engine setup before render, s | 0.519664 | 0.515007 |
| Setup plus render, s | 19.595386 | 19.495809 |
| Sampled peak physical footprint, MiB | 5347.71 | 5062.74 |
| Residual physical footprint, MiB | 344.52 | 335.83 |
| Completed / submitted command buffers | 71227 / 71227 | 71227 / 71227 |
| Failed / pending command buffers | 0 / 0 | 0 / 0 |

Both produced rows 48/68/52/60/75, and all five PCM hashes/sample counts match
exactly between runs. Thermal state stayed nominal. Residual MLX active/cache
bytes are zero after owner teardown. Fresh2 peak render concurrency is two,
decode concurrency one, with actual cross-segment render/decode overlap and
no residency fallback. This establishes approximately 1.27x raw-audio realtime
for this isolated Big Mike workload, not an optimization gain or live-game RTF.

These runs exclude the immersive scene, Foundation Models, real playback,
live-input work and gameplay publication callbacks. Their pre-timing identity
hashing reads model files; fresh engine does not mean disk/driver-cold. The
historical roughly 48-second game run is NOT a matched baseline: build/source,
callback work, observation and cache conditions differ, and its reported
command-buffer count is different. Do not infer that rendering, one visual
feature, or a model change caused the gap.

Complete outer phase interval unions (seconds): generation 17.291/17.263,
decode 11.271/11.398, their overlap 9.504/9.699, prefill 2.812/2.766. Generation
or decode covers 19.058/18.962 seconds. These overlapping, inclusive elapsed
scopes cannot be summed as independent CPU/GPU costs. Both runs retain five
generation and five decode outer scopes, with zero pending/invalid timestamps.
Inner sampling caps dropped 1697 scopes and 77644 metadata inspections per
run; only 160 row scopes cover a 303-row workload. Approximately 42% of command
buffers lack a phase context. GPU timestamps are not mapped to scope clocks.
The tiny admission-wait scope also excludes waiting to enter the decoder actor.

Metadata on both actual-device runs confirms initial BF16 step projections
widen to FP32 after RoPE, followed by FP32 cache/attention and later projections.
C2 therefore remains a concrete generation-side investigation, not a measured
win. No BF16 implementation/promotion, Fresh2 serialization, visual shutdown,
quality-gate relaxation, sampling change or gameplay optimization was performed.

Artifacts: `/private/tmp/qwen-device-phase-20260918.CYleSb/` contains
`report-full-segments-01.json`, `report-full-segments-02.json`, both launch and
validation/provenance records, requests, the build log/source snapshot/manifest,
and the signed app UUID `736D433B-685D-3D2B-8D89-7D8685DE562E` in the manifest.
The native generic qualification-pending label is not a five-voice/release pass;
these are completed full-workload observations with verified build provenance.

After testing, the first normal-app install command reached its 60-second
host timeout. The owner correctly noted the headset was still loading; a host
command timeout alone is not proof that device installation failed. The next
attempt completed, and a fresh installed-app query confirmed the ordinary
signed Release app, version 4.3/build 33, at container
`651BED4F-94E5-47EC-9B52-06FC24B8A863/c1-production-restore.app`. No further
install was issued after the owner's loading report. Saves were not removed.
Normal app installation is verified; main-menu launch was not performed or
claimed. No further headset testing was requested this turn.

### 2026-09-18 C2 generation BF16 implementation and host observations

Owner backed up at `ae65c8b` and approved the opt-in experiment. See
`QWEN_BF16_CONTAINMENT_EXPERIMENT.md` for exact arithmetic boundaries and the
preserved Fresh2/gameplay contract. Production remains `.legacy`; C2 is not a
shipping selection, and no device install was performed in this implementation
turn. Decoder precision and C1 cache are unchanged.

Local evidence: `/private/tmp/qwen-c2-20260918.wD4kqR/`. Release native benchmark
build passed. Eleven arithmetic tests (including two opt-in Metal GPU tests),
eleven existing conversion-cache tests, eight full-workload contract tests,
four evidence-export tests and the opt-in actual-model test passed. Python:
58 performance/evidence tests and 14 provenance tests passed; existing phase
diagnostic source audit passed with no added evaluation/readback sites.

The initial numerical test failed in fast RMSNorm (31 element assertions).
Source inspection found BF16 normalization was rounded before affine weighting
on both CPU and Metal. C2 now uses FP32 through the affine operation and rounds
once to BF16. Original thresholds were retained; failure log is preserved at
`/private/tmp/qwen-c2-host-tests-20260918.log`, repaired run at
`/private/tmp/qwen-c2-host-tests-20260918-r2.log`.

Actual-model prefill probe: Big Mike's complete first production segment, full
159-row default conditioning, one unchanged raw weight store, 169-token prompt.
All 59 captured tensors matched bitwise across two legacy passes; the calibration
JSON was persisted before C2 ran. All C2 captures were finite and shape-correct,
with BF16 prompt/hidden/valid per-layer K/V and FP32 codec logits. Observed prompt
NRMSE was 0.001134, final-hidden NRMSE 0.011335, worst captured NRMSE 0.019474.
Raw-head argmax stayed 1988; top-two margin changed 0.31679 to 0.32744. These
are unthresholded numerical observations, not sampled-token or quality approval.

Six fresh-process full-response runs completed (30 natural-length segments),
all natural EOS, finite PCM and no pending/failed command buffers. Within each
policy all five PCM hashes repeated exactly across three runs. Across policies,
all five PCM hashes changed. Rows were legacy 48/68/52/60/75 (24.24 seconds),
C2 48/62/56/63/81 (24.80 seconds). Full-precision vocabulary heads do not make
earlier BF16 activations bit-equivalent. Earliest residual-token divergence is
segment 0, row 0, codebook column 2; this is retained in `quality-comparison.json`.

| Run | Render seconds | First PCM seconds | Peak footprint MiB | Capture |
| --- | ---: | ---: | ---: | --- |
| Legacy evidence | 27.171 | 7.827 | 4979.4 | WAV/code evidence |
| C2 evidence | 23.757 | 6.937 | 5165.4 | WAV/code evidence |
| C2 01 | 29.357 | 8.345 | 5624.4 | Off |
| Legacy 01 | 36.473 | 10.747 | 5138.2 | Off |
| Legacy 02 | 42.260 | 14.867 | 5104.4 | Off |
| C2 02 | 34.987 | 11.593 | 5017.0 | Off |

All host attempts reported thermal state 1 (fair), with substantial elapsed-time
drift. Retain every run; do not cherry-pick the first pair, pool capture and
non-capture runs, compare these to the earlier M2 result, or claim a production
speedup. Raw output length/work differs. Host build provenance is not a fresh
strict device qualification manifest. M2 performance, all-five-voice listening,
predictor/generated-step numerical checks, calibrated quality thresholds,
full-scene memory/latency and recovery remain pending. No gate is relaxed.

Evidence export retains native CPU PCM/code arrays only when explicitly asked,
serializes float32 WAV and code JSON after render timing, and reports itself
ineligible for performance promotion. The comparison verifies filenames,
hashes, reference identity, UInt64 seeds, all codebook ranges, PCM format and
EOS separately; its result is `EVIDENCE_COMPARABLE / NOT_A_QUALITY_PASS`.

Generic visionOS Release qualification-build compile/link/sign also succeeded
(`visionos-incremental-build.log`). This was incremental compile validation,
not a fresh provenance-qualified performance build and not an installed-device
test. No headset app was replaced. About 1.6 GiB of host disk space remains;
avoid duplicate app/model payloads while preparing the next device qualification.

### 2026-09-18 C2 M2 Vision Pro first screen — historical pre-shipping decision

The opt-in and listening-pending status in this checkpoint preceded the owner's
subsequent sample approval and explicit shipping-default directive recorded below.

The owner approved the device experiment. One signed Release qualification app
served both complete explicit runtime contracts: legacy baseline and C2
`bf16Candidate`, differing only in generation arithmetic and its canonical
policy fingerprint. The manifest's `alternateRuntimeContracts` is an exact
single-candidate list, not a wildcard or waiver of source/build/UUID, payload,
sampling, topology, recovery or playback controls. All seven report exports
passed strict provenance against that same manifest.

Artifacts: `/private/tmp/qwen-c2-device-20260918.3dMy6t/`.

- Installed UUID: `55B34289-D6CF-32F6-983B-3585A14CBDCF`.
- Manifest `c2-device.manifest.json`, SHA256
  `40b3d745dcc6a89f23eb1be2564c4cf1f04627abbfba998a0a020faafca7b555`;
  actual compile commands in `c2-device.manifest.commands.json`.
- Frozen `c2-device.source.json` records relevant-source SHA256
  `5fc0a4e0921f3e76ea1d38f0656fb5168690974bc80edc3f2f24093efc31af10`.
  The first `c2-device.build.log` failed copying model resources because disk
  was full; that failed attempt remains retained. The unchanged-source retry
  `c2-device.retry1.build.log` passed, then the manifest was captured and the app
  signed. No stale build UUID or failed log was accepted as successful evidence.

The uninstrumented timing cohort ran A01/B01/B02/A02 on physical M2 Vision Pro
(`RealityDevice14,1`, visionOS 27.0 build 24M5361a). Exact-request launch receipts,
the previous-PID termination chain and receipt timestamps confirm AB/BA order.
All four passed strict validation, with thermal state 0→0, profiler unattached,
phase markers off and no PCM/code evidence retention. Full five-segment Big Mike
conditioning remains 159 reference rows with the separate 24-row decoder prefix;
independent Fresh2, two lanes/two stores/one decoder, currentOverlap, unchanged
seed/voice/quality settings, 160-row ceiling and deviceDefault 40/40 remain intact.

| Timing run | Render wall s | First-needed PCM s | Sampled peak MiB | Raw audio s |
| --- | ---: | ---: | ---: | ---: |
| A01 legacy | 25.258503583 | 9.152913667 | 5551.004486083984 | 24.24 |
| B01 C2 | 25.015274833 | 9.245157083 | 5036.738449096680 | 24.96 |
| B02 C2 | 23.651934875 | 8.358028292 | 4833.144676208496 | 24.96 |
| A02 legacy | 25.151233125 | 9.235302041 | 5062.051040649414 | 24.24 |

Arithmetic mean legacy→C2: wall **25.204868354→24.333604854 s** (−3.456727%),
first PCM **9.194107854→8.801592688 s** (−4.269203%), sampled peak
**5306.527763→4934.941563 MiB** (−7.002436%), raw-audio RTF
**1.039804800→0.974904041** (−6.241629%). These are ratios of means, not the
paired estimator. B01/A01 and B02/A02 wall ratios are **0.9903704212** and
**0.9403886783**; median paired ratio **0.9653795497**, two-pair bootstrap interval
**[0.9403886783, 0.9903704212]**. Two pairs do not establish robust uncertainty,
tail behavior or a sustained gameplay gain; first PCM slightly regressed in B01.

Both legacy repeats generated rows **48/68/52/60/75** (303 total); both C2
repeats generated **47/65/53/62/85** (312 total). Thus C2 produced nine additional
rows and 0.72 additional seconds (+2.970297%), not truncated or reduced output.
All segments reached natural EOS. Within each policy the five PCM hashes repeat
exactly, but across policies output differs. Changed token work means the wall
reduction is not identical-work arithmetic proof; the RTF difference also reflects
the longer audio denominator. Fixed-work/content/quality review remains required.

`c2-performance-screen.json` uses the actual-ID `c2-experiment.json`, existing
unchanged gates and only the four timing reports. It reports `COMPARABLE`, no
errors or threshold-regression reviews, **OUTPUT_LENGTH_REVIEW** and
**DEVICE_QUALIFICATION_PENDING**. This is two pairs for one voice, not the gate's
five valid pairs for each of all five voices. No external evidence PASS was
invented; independent quality/recovery/full-scene review remains missing. The
comparison's missing independent-provenance-review package does not negate the
separately successful strict per-run build verification.

Separate `report-c2-audio-a01.json` / `report-c2-audio-b01.json` retain native WAVs
and exact code rows in `c2-audio-a01.evidence/` / `c2-audio-b01.evidence/`.
`c2-quality-comparison.json` reports **EVIDENCE_COMPARABLE / NOT_A_QUALITY_PASS**,
with matching work/voice/reference identities and verified payloads. All five
PCM/code outputs differ; earliest segment-0 divergence is row 0, codebook column
2 (zero-based). Owner listening approval remains pending. Hashes and token
divergence do not establish quality; numerical and all-voice gates remain open.
Evidence-retention runs are excluded from timing aggregates.
The owner was presented `current-mike-full-response.wav` and
`bf16-mike-full-response.wav` in the artifact directory: all five native PCM
segments concatenated in order, verified bit-exact, without normalization or
resampling. These previews are listening aids, not additional performance runs.

All seven renders completed all five segments naturally with zero failed/pending
Metal buffers. The four timing and two audio runs stayed thermal 0→0. The separate
phase-enabled `report-c2-dtype-b01.json` is provenance-qualified but **validation
failed** for thermal 0→1. Retain that diagnostic attempt; no rerun was made and it
is not performance evidence. Actual dtype interpretation is separate from policy
labels, numerical acceptance and performance qualification.

The independent dtype audit found sampled BF16 prompt, Q/K/V projections,
post-RoPE attention and K/V caches across all five segments, with FP32
talker/predictor logits and decoder tensors. Caps dropped 116,252 metadata
inspections and 1,733 scope entries; this is not complete dtype/kernel coverage.
PCM repeats exactly within A01/A02/audio-A and within B01/B02/audio-B/dtype-B,
without making the instrumented/evidence runs timing controls or quality passes.
The next user-facing review is the retained native A/B audio; any subsequent
bounded in-game pilot needs explicit approval, not immediate production promotion.

Normal-app restoration is **verified complete**. `restore.json` records success
and `restored-app.json` confirms the same bundle, version 4.3/build 33, at
`FEBFE3DE-0074-4A51-935F-A7922378C0DF/c1-production-restore.app`, restored from
`/private/tmp/qwen-performance-20260917/c1-production-restore.app`. This was an
in-place update: no uninstall, save deletion or data-container deletion. The
installation receipts do not claim a normal gameplay launch. This benchmark
round is complete; production remains `.legacy`, with no C2 promotion or
gameplay/visual/concurrency change.

### 2026-09-18 owner approves BF16 as the normal shipping default

After hearing the retained Big Mike A/B previews, the owner approved that sample
and explicitly requested BF16 as the **shipping default**, not a separate test
scheme, process switch or gameplay toggle. This is a user-authorized release
decision, not automatic completion of the engineering gates. The listening
approval covers the presented Mike sample only, not all five voices or scenarios.

`TuringQwenNativeExecutionPolicy.production` now selects
`Self(arithmetic: .bf16Candidate)`, fingerprint
`f7188d490a7d756b1ebc8c65b754bcd8c2e20ec3e45a6ddd70068f465cf665f3`.
All other policy fields remain unchanged; scheduler diagnostics now identify
the selected arithmetic and fingerprint. Fresh2, voices/reference conditioning,
sampling, decoder precision/I/O, PR/playback, recovery and visuals are unchanged.
Explicit legacy selection remains available for measurement/reference tests;
ordinary gameplay requires no opt-in.

The existing first screen remains approximately **3.5% lower mean wall time**
from two Big Mike pairs, with **303→312 rows / 24.24→24.96 seconds** of output.
Its saved `OUTPUT_LENGTH_REVIEW` and evidence `NOT_A_QUALITY_PASS` are not changed
into PASS by the shipping decision. Five-voice listening, calibrated numerical
acceptance, additional matched repetitions, sustained full-scene and device
recovery qualification remain pending; no installed gameplay speedup is claimed.

The external `ShippingPolicyCheck.swift` in the C2 device artifact directory
compiled and ran against the actual repository policy source: PASS for the
shipping tuple/fingerprints, explicit legacy override, structured task inheritance
of that override, detached-task BF16 default, and restoration to BF16 afterward.
This allocates no model and is not an inference or device qualification test.
Four native test files were updated for the shipping default while preserving
explicit legacy arithmetic/probe baselines; the full native suite has **not**
been rerun after these edits.

The ordinary Release build completed successfully (exit 0), with log
`/private/tmp/qwen-c2-device-20260918.3dMy6t/c2-shipping-default.build.log`.
Deep/strict signature verification passed. Actual app and native Swift commands
are optimized, omit `GR_QWEN_PERFORMANCE_QUALIFICATION`, and retain native
`GR_TURING_METAL_STREAM_RECOVERY`. The 58 performance/evidence and 25 provenance
Python tests also passed after the default change. This new build has not been
installed or played: the headset retains the verified restored legacy app until
the next ordinary Xcode build/run installs the BF16-default app.
