# Qwen performance results — 2026-09-17

Overall: **DEVICE_QUALIFICATION_PENDING**. This is the first implemented
measurement/candidate checkpoint, not completion of the full execution-engine
program. No speedup has been promoted into production.

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
| C/D/E/G/H arithmetic, fused attention, predictor plans/workspace, kernels/state reuse | NOT IMPLEMENTED | Require corrected device baseline and measured target selection; decision record distinguishes proposals from code |

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
