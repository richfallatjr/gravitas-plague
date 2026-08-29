# Gravitas Plague — Mind’s Eye filler lip sync and generated-mouth recovery

## Architect discovery handoff for a code-complete implementation directive

Date: 2026-08-28  
Repository: `/Users/richardfallat/Projects/dev/gravitas-plague`  
Branch at inspection: `main`  
Inspected commit: `69ce3b7d81cd5e875ade1cefb92a4a8a0db5ffc0`  
Target: visionOS 27 on Apple Vision Pro  
Input device log: `/Users/richardfallat/.codex/attachments/c98e4a6d-c56a-4583-856b-3de031b48146/pasted-text.txt`

## 1. Your assignment

Inspect the repository and this handoff, then write a repository-specific,
code-complete Codex implementation directive for the next Mind’s Eye increment.
The directive must solve both parts of one continuous Turing response:

1. Bundled filler clips need offline-authored lip sync and must participate in the
   Mind’s Eye spoken-presentation lifecycle.
2. Generated Turing speech must no longer silently remain on the rest mouth when
   its visual analysis misses the current 40 ms deadline.

Your output is the implementation directive that another Codex agent will execute.
Do not return another discovery questionnaire or a generic architecture essay. Pin
the directive to the repository you actually inspect, give exact file-by-file
changes and compile-valid Swift/Python/JSON contracts, include tests and device
acceptance gates, and state any SDK API that must be proven by a minimal spike.

Do not implement the changes during this architect pass unless the product owner
explicitly changes the assignment.

## 2. Product outcome

The Mind’s Eye portrait represents the person whose voice is actually audible. A
single response should feel like one unbroken remote presence:

```text
portrait appears slightly before speech
  -> filler clip uses its offline mouth cues
  -> dead air idles at rest with camera motion/blinking
  -> generated segment uses generated mouth cues
  -> inter-segment filler uses its offline mouth cues
  -> portrait remains at rest between clips
  -> response completion removes the portrait
```

The card must not disappear, rebuild, restart its motion seed, or flash a base-only
frame merely because playback changes among filler, dead air, and generated
segments for the same response, speaker, surface, and current vignette.

Hard rules:

- Filler files are fixed bundled audio. Analyze them offline and ship sparse cue
  data. Do not compute filler lip sync on Vision Pro.
- Use the actual audible speaker. Never substitute Big Mike for Rich or any other
  missing character package.
- Missing art, a missing/invalid filler manifest, generated-analysis failure, or a
  late visual must never block, delay beyond the bounded reveal policy, cancel, or
  alter audio/story progression.
- Mouth timing begins at the actual endpoint `.started` clock origin, not when a
  request is submitted.
- Pause/resume must use `TuringPauseAwarePlaybackClock`.
- Preserve one card, one vignette package, one compositor output, and one active
  mouth-playback owner.
- Preserve the existing weighted filler selection and no-immediate-repeat behavior.
- Random mouth-image variants remain deterministic and bounded; they change only
  through the existing semantic-pose variant-plan behavior.
- During silent gaps, use the rest mouth while keep-alive selfie motion and blinking
  continue.
- No runtime file discovery, JSON decoding, audio analysis, or texture loading may
  occur on the main actor.

## 3. What the device run actually proved

### 3.1 Turing audio completed; generated mouth analysis did not

The pasted run does not show a Turing crash or abort. Qwen produced and played all
six requested generated segments, and the run ended with:

```text
completedGeneratedSegmentCount: 6
```

The process physical-footprint samples rose to approximately 5.82 GB during Qwen
work, then fell to approximately 1.93 GB after the Qwen pool unload and later to
approximately 1.70 GB. That is material pressure and must remain part of device
qualification, but the log’s visible failure is generated lip sync, not failed TTS
audio generation.

Every generated segment attempted visual analysis and every attempt failed:

```text
segment 0  analysisUnavailable status=deadlineExceeded
segment 1  analysisUnavailable status=deadlineExceeded
segment 2  analysisUnavailable status=deadlineExceeded
segment 3  analysisUnavailable status=deadlineExceeded
segment 4  analysisUnavailable status=deadlineExceeded
segment 5  analysisUnavailable status=deadlineExceeded
```

Concrete log lines are 27154–27173, 27560–27561, 29612–29625,
30015–30016, 31526–31527, and 32059–32060.

There is no `[MindEyeGenerated] playback started` entry anywhere in the run. The
presentation coordinator did show/reuse the Big Mike portrait, but
`generatedSpeechFrameTrack` was `nil`, so `startGeneratedMouthIfAvailable` reset the
mouth to rest. The log’s repeated messages:

```text
[MindEyeGenerated] response portrait reused ...
[MindEyeGenerated] segment complete; portrait retained ... mouth=rest
```

confirm portrait continuity, not mouth-track registration. This matches the
product owner’s report that the image appeared to stay on the character base/rest
pose.

### 3.2 Why all six tracks were absent

Production currently uses:

```swift
TuringGeneratedSpeechAnalysisBudget(
    hardBudget: .milliseconds(40),
    postFileWriteGrace: .milliseconds(4)
)
```

`TuringGeneratedPlaybackFileStore.write` starts a detached analysis task, writes
and validates the WAV, then gives the task at most the remaining hard deadline plus
a 4 ms post-write race. Under the two-lane Qwen workload, every analysis task missed
that contract. The resulting `PreparedClip` permanently contains no visual track.
`TuringSpokenPresentationContext` is immutable, and the runtime has no late-track
event that can attach analysis to an already audible segment. Audio correctly
continues, but the rest-mouth fallback becomes permanent for the entire segment.

The implementation directive must correct this without creating an unbounded wait
in front of audio. The architect must choose and fully specify a measured design,
not merely increase a magic timeout. A valid design may combine a realistic
off-main deadline with late track delivery and catch-up against the actual playback
clock, provided stale run/segment/handle results are rejected and audio never waits
unboundedly. If analysis cannot be produced, rest-mouth/audio-only degradation is
still required and must be clearly logged.

### 3.3 The first filler was invisible; later filler retained the card

The run began with an authored Big Mike bridge portrait. Before Qwen loaded, high-
memory preflight removed it:

```text
[MindEyePresentation] dynamic visual detached ...
reason=qwenPreflight.797C8508-F33B-4987-9A24-135D56658783

[TuringHighMemoryPreflight] Mind’s Eye prepared
activeRetained: false
activeReleased: true
```

The authored presentation had a different run identity from the generated response,
so `.retainMatchingRunActive` did not retain it. The first Big Mike filler then
started at log line 27578. No Mind’s Eye card existed during that filler. The Big
Mike card was not rebuilt until generated segment 0 at lines 28351–28354.

After generated segment 0, the coordinator intentionally retained the response
portrait at rest between generated segments. The log has no dynamic detach during
the later filler/dead-air intervals. It detaches only at response completion at
lines 32316–32325. Therefore the implementation must fix two distinct UX gaps:

- establish/reveal the correct portrait for the first filler after Qwen preflight;
- animate the mouth during every filler while retaining the existing no-rebuild
  response continuity for subsequent filler and dead air.

The memory-preflight policy cannot simply be deleted. The solution must measure and
preserve the safety intent. It may release the old authored presentation, then
prepare the generated-response speaker package in time for filler when sufficient
memory is available. The same Big Mike package already coexisted with Qwen later in
this run, so the directive must qualify the actual overlap rather than assume it is
free or impossible.

## 4. Current repository architecture

### Spoken presentation

Relevant files:

```text
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringAudioPlaybackTypes.swift
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringSpokenPresentationEvent.swift
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePresentationCoordinator.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePresentationIdentity.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeSpokenPresentationEventSource.swift
```

`TuringAudioClipKind` already contains `.filler`, but
`TuringSpokenPresentationSource` contains only `.authored` and `.generated`.
`TuringStoryWalkiePlaybackCoordinator.ActiveItem` contains a `.filler` case, but it
has no `startingFiller` state, no request/source tracking, no presentation context,
no pause-aware spoken clock, and no presentation start/completion event.

`playbackStarted` registers only `startingPrerecording`, `startingAuthored`, and
`startingGenerated`. The Phase 1 lifecycle test
`testFillerStartFailureDoesNotEnterSpokenPresentationStream` explicitly locks the
old behavior. That test must be replaced or narrowed; successful filler must now
enter the stream, while failed filler must still produce no false visual start.

The architect directive must define a stable filler media identity. Do not key
runtime state by a weighted-array position. Key by speaker plus canonical bundled
clip identity, and retain the exact resource URL/hash needed to reject stale or
mismatched cue data.

### Current pre-audio reveal worktree

The current worktree contains a newer, not-yet-committed pre-audio reveal handshake:

```text
M  Gravitas Plague/Gravitas Plague/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift
M  Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePresentationCoordinator.swift
?? Gravitas Plague/Gravitas Plague/Turing/Audio/TuringSpokenPresentationReveal.swift
?? Gravitas Plague/Gravitas PlagueTests/Turing/MindsEye/MindEyePreAudioRevealContractTests.swift
```

It requests an idle portrait for authored/generated speech, waits up to 2 seconds
for visual readiness, gives a newly shown portrait a 300 ms beat, skips the beat if
the correct portrait is already visible, and falls back to immediate audio when the
visual is unavailable. The pasted device log predates this local change and does
not qualify it.

Treat the current worktree as authoritative and preserve these owner-requested
changes. Extend the handshake for filler rather than deleting or duplicating it.
When a response portrait is already visible, filler should promote/reuse it without
another 300 ms pause or a motion restart. When the first filler is the first visible
media for the response, reveal it on the same bounded policy before actual filler
audio begins.

### Offline authored lip sync

The existing authored-PR toolchain is substantial and should be reused rather than
forked casually:

```text
Gravitas Plague/Scripts/generate_mind_eye_frame_manifests.py
Gravitas Plague/Scripts/bootstrap_mind_eye_lipsync.sh
Gravitas Plague/Scripts/mind_eye_lipsync/
Gravitas Plague/Scripts/mind_eye_lipsync/config/eligible_authored_prs.json
Gravitas Plague/Scripts/mind_eye_lipsync/schemas/
Gravitas Plague/TuringResources/Turing/MindsEye/AudioFrames/
```

It pins MFA 3.3.9, English US ARPA model versions, Silero VAD 6.2.1, deterministic
hashes, a fixed 48 kHz/60 Hz timeline, and all five required semantic poses:

```text
rest, small, wide, round, teeth
```

Runtime classes include:

```text
MindEyeAuthoredFrameManifest
MindEyeAuthoredFrameIndex
MindEyeAuthoredFrameRuntimeWorker
MindEyeAuthoredFrameTrackStore
MindEyeAuthoredFrameTrack
MindEyeAuthoredMouthPlayback
MindEyeAuthoredFramePlaybackRegistry
MindEyeAuthoredFramePlaybackSystem
MindEyeAuthoredMouthVariantPlan
```

Important constraint: `MindEyeAuthoredFrameIndexValidator` is intentionally locked
to exactly 37 PR manifests and hard-coded speaker counts. Simply appending 51 filler
manifests to `AudioFrames/index.json` will invalidate the production PR corpus. The
directive must either introduce a separately versioned filler registry/index that
reuses the same compact runtime track/playback machinery, or provide a fully tested
schema migration that keeps the 37-PR validation invariant explicit. A separate
filler index is the lower-risk default.

Filler includes verbal phrases and nonverbal sounds. MFA transcripts work for
phrases such as “hold on” and “give me a second,” but coughs, inhales, exhales,
tongue clicks, “mm,” “hmm,” and “ugh” require an explicit offline nonverbal authoring
path. Do not invent spoken transcripts that produce misleading phoneme alignment.
The directive should specify a versioned filler descriptor registry with an
explicit mode such as manual transcript versus nonverbal/audio-feature authoring,
and deterministic offline output for both. Runtime remains lookup-only.

### Generated lip sync

Relevant files:

```text
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringGeneratedSpeechAnalysisBudget.swift
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringGeneratedSpeechAnalysisWorker.swift
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringGeneratedSpeechAnalyzer.swift
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringGeneratedSpeechFrameTrack.swift
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringGeneratedPlaybackFileStore.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeGeneratedFrameTrackAdapter.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeGeneratedMouthPlayback.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeGeneratedFramePlaybackRegistry.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeGeneratedFramePlaybackSystem.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeDynamicOutputSurface.swift
```

The analyzer is the intentionally cheap runtime path for audio that cannot exist
offline. Do not route generated TTS through the filler/PR compiler. Preserve serial,
off-main analysis and the audio-continuation guarantee. Add explicit diagnostic
events for analysis queued, ready before audio, attached late with elapsed catch-up,
unavailable, registered, unregistered, and stale result rejected.

## 5. Filler resource inventory and weighting

Current bundled roots:

```text
Turing/Audio/big-mike-filler  27 unique files, 132 weighted entries
Turing/Audio/rich-filler      24 unique files, 120 weighted entries
```

The weights are encoded in the final underscore token. The runtime parser also
supports `weight-`, `weight_`, and `w-`. Preserve the filename and weight semantics;
do not copy or rename the owner’s audio merely to satisfy the lip-sync system.

Current `TuringFillerCatalogActor` expands each unique URL into a repeated weighted
URL array, which loses structured clip metadata. The directive should specify a
structured immutable filler record containing at least canonical ID, speaker,
resource path/URL, weight, audio hash, cue-manifest path/hash, and authoring mode.
Weighted random choice can still preserve the exact distribution without shipping
or loading duplicated audio/manifests.

Big Mike files, which are the currently visible filler target:

```text
big-mike-filler-alright_alright-alright_1.mp3
big-mike-filler-clear-03_8.mp3
big-mike-filler-tongue-click-02_10.mp3
big-mike-filler_alright_2.mp3
big-mike-filler_clear-01_10.mp3
big-mike-filler_clear-02_10.mp3
big-mike-filler_cough-01_5.mp3
big-mike-filler_cough-02_5.mp3
big-mike-filler_exhale-02_5.mp3
big-mike-filler_exhale_1.mp3
big-mike-filler_give-me-a-second_2.mp3
big-mike-filler_hmm_6.mp3
big-mike-filler_hold-on_2.mp3
big-mike-filler_hold-up-hold-up_1.mp3
big-mike-filler_inhale_2.mp3
big-mike-filler_let-me-think_1.mp3
big-mike-filler_listen_2.mp3
big-mike-filler_look_3.mp3
big-mike-filler_mm_7.mp3
big-mike-filler_tongue-click-01_9.mp3
big-mike-filler_ugh_10.mp3
big-mike-filler_umm-01_10.mp3
big-mike-filler_umm-02_10.mp3
big-mike-filler_wait_2.mp3
big-mike-filler_ya-heard_1.mp3
big-mike-filler_yeah-no_2.mp3
big-mike-filler_you-know_5.mp3
```

Rich also has 24 bundled filler files, but the current Mind’s Eye catalog has no
Rich vignette. Author Rich filler cue data now if that is the clean corpus contract,
but runtime must remain audio-only until a Rich package is mapped. Never display Big
Mike for Rich filler.

Current Mind’s Eye visual catalog entries are only:

```text
big_mike -> big_mike_current_room
cateye81 -> cateye81_bunker
```

Current filler configuration is present for Big Mike and Rich only. Broadcaster,
CatEye81, and Dad currently declare no filler directories.

## 6. Required runtime behavior for the directive

The architect must provide exact contracts for all of the following.

### Filler identity and event lifecycle

- Add a filler source identity to the spoken-presentation domain.
- Add a `startingFiller` request state so endpoint `.started` can be matched by
  request ID before the active audible state is installed.
- Resolve filler speaker from the configured output character for that run, then
  validate it against the structured filler descriptor. Do not infer speaker from
  the route or current portrait.
- Create the pause-aware clock at the actual endpoint start instant.
- Emit filler started, paused, resumed, completed, cancelled, and failed semantics
  without confusing filler completion with whole-response completion.
- Ensure stale completion from an older filler cannot dismiss or mutate the current
  generated segment/card.
- A failed filler start emits no false visual start and proceeds through the current
  dead-air/generated reconciliation rules.

### One continuous response portrait

- Model response-level visual ownership separately from per-clip mouth ownership.
- Filler start may attach/reuse the response portrait and install a filler track.
- Filler completion stops only filler mouth playback and returns to rest. It does
  not detach the response portrait.
- Dead air retains the portrait at rest with keep-alive motion and blinking.
- Generated start replaces filler mouth ownership on the same visual and samples
  from the actual generated clock.
- Generated completion returns to rest and retains the portrait until the next clip
  or `.responseCompleted`.
- Speaker, surface, run, cancellation, lifecycle reset, memory-pressure teardown,
  physical-character suppression, or application shutdown may still replace or
  remove the card under existing policy.
- If the speaker/surface changes, atomically replace with the correct portrait; do
  not reuse the wrong package.

### Offline filler track runtime

- Validate and load filler indices/manifests off-main and serially.
- Verify audio and manifest hashes and exact sample timeline.
- Prewarm the selected filler track before playback when possible.
- Do not load all 51 expanded weighted entries. Unique manifests are tiny; define
  the measured cache policy, lease ownership, and eviction behavior.
- Reuse the authored compact pose-run representation, clock mapper, semantic pose
  enum, and variant-plan rules where compatible.
- Do not add another RealityKit update system if the existing authored system can
  be generalized safely. If a separate component/system is chosen, justify it and
  keep one active mouth controller.
- A missing/invalid track shows the correct portrait at rest and continues filler
  audio; it must not substitute another clip or character.

### Generated analysis recovery

- Keep audio publication/playback bounded and independent of visual-analysis
  success.
- Replace the current permanent-nil outcome with a measured policy that can attach
  a valid late analysis to the matching audible segment and catch up from its
  pause-aware actual playback clock.
- Reject analysis for stale run IDs, segment indices, request IDs, playback handles,
  speakers, surfaces, or already completed segments.
- If analysis becomes ready before actual start, install normally from frame zero.
- If it becomes ready after actual start, install at the current elapsed frame with
  no rewind and no portrait rebuild.
- If the segment ends first, discard the result and release all task/track state.
- Bound analysis concurrency at one and prove it runs off-main even while Qwen is
  active.
- Measure analysis duration and scheduler delay separately. The current log only
  reports final deadline failure and a small post-file wait, which hides whether
  compute was slow or starved.
- Do not permit an orphaned analysis task to retain full PCM after segment/run
  teardown.

### High-memory preflight

- Preserve Qwen’s high-memory preflight and its ability to release an old/mismatched
  active presentation.
- Define when the new generated-response portrait may be loaded for the first
  filler and how low/critical memory pressure changes that decision.
- No visual is allowed to prevent Qwen from starting or audio from playing.
- Qualify control versus enabled physical footprint, first-filler package overlap,
  Qwen peak, post-unload recovery, ten-cycle behavior, Xcode debug, and video
  capture. Use measured deltas, not a guessed 8 GB process limit.

## 7. Authoring requirements

The directive must include a host-only, deterministic workflow that an engineer can
run after filler files are added, removed, renamed, reweighted, or replaced.

At minimum specify commands and contracts for:

1. Inventory unique audio files without duplicating weight-expanded entries.
2. Parse and validate weight metadata.
3. Resolve a stable canonical filler ID and explicit speaker.
4. Require a versioned descriptor entry for every unique filler audio file.
5. Decode audio with the same AVFoundation-parity timeline rules as authored PRs.
6. Run transcript/MFA/VAD for verbal clips and deterministic offline nonverbal
   analysis for nonverbal clips.
7. Emit all five semantic pose families where the audio evidence requires them;
   silence must be rest.
8. Emit sparse/compact runtime data plus provenance and SHA-256 hashes.
9. Validate exact audio duration/sample count against the shipped resource.
10. Produce a review report/preview for every clip.
11. Publish atomically through staging; never write partial production sets.
12. Audit the built app for exactly one copy of each filler audio and cue manifest,
    with no authoring workspace, decoded PCM, MFA output, or duplicate weighted
    resources in the bundle.

The product owner may replace audio in place. Hash mismatch must therefore fail the
authoring/validation gate clearly rather than silently playing stale mouth cues.

## 8. Tests the implementation directive must require

### Host/tooling tests

- Exactly 27 unique Big Mike and 24 unique Rich filler files at this snapshot.
- Exact weighted totals: 132 Big Mike and 120 Rich.
- Weight parsing for final `_N`, `weight-`, `weight_`, and `w-` forms.
- Unique clip identity does not change merely because weight changes.
- Audio replacement changes the hash and invalidates stale cues.
- Verbal, silence-padded, cough, inhale/exhale, tongue-click, and hesitation fixture
  coverage.
- Deterministic byte-identical clean builds.
- No direct production overwrite; staged atomic publishing only.
- Bundle audit proves no duplicate audio or authoring artifacts.

### Swift unit/integration tests

- Successful filler enters the spoken-presentation stream at actual endpoint start.
- Failed filler start does not emit a false started event.
- Filler pause/resume uses the correct pause-aware clock.
- Filler completion returns to rest without detaching the response card.
- Dead air retains motion/blinking/rest mouth.
- First filler after Qwen preflight reveals the correct Big Mike portrait on the
  bounded lead-in contract.
- Filler following generated segment N reuses the card and motion seed.
- Generated segment following filler reuses the card and replaces only mouth
  playback.
- Wrong/missing speaker package is audio-only, never Big Mike substitution.
- Stale filler completion and stale late generated analysis are ignored.
- Generated analysis ready before start registers from frame zero.
- Generated analysis ready after start registers at the correct elapsed frame.
- Generated analysis missing/invalid/deadline-exhausted remains rest without
  affecting audio.
- Run cancellation, response completion, memory pressure, scene reset, and shutdown
  leave zero mouth registry entries, zero retained analysis PCM/tasks, and no card.
- One unique vignette package maximum remains enforced.
- Source audits prove blocking I/O/decoding/analysis is off-main and serial.

### Vision Pro acceptance sequence

Run at least one full six-segment Big Mike conversation with the same conditions as
the supplied log and verify:

```text
first filler: portrait visible before audio, filler mouth moving
dead air: portrait retained, rest mouth, motion and blinking continue
generated 0...5: each segment logs a registered mouth track or an explicit measured
                 degradation reason; no silent permanent-rest failure
inter-segment filler: offline mouth cues, no card rebuild or motion restart
response end: one clean detach and complete task/lease teardown
```

Repeat no-debugger, Xcode-debug, and video-capture passes. Report actual timing,
memory, and failure evidence. TestFlight-equivalent qualification remains separate
and must not be claimed from an Xcode run.

## 9. Compatibility and non-goals

Preserve all existing Mind’s Eye compositor, crop, feather mask, alpha, placement,
camera motion, blink, physical-character suppression, and one-package memory
contracts. This increment is not authorization to redesign the art package, move
the card, copy assets, change filler volume/weights, change dialogue generation, or
alter story progression.

Do not add filler art for Rich, Broadcaster, Dad, or CatEye81. Their correct package
must exist in the speaker catalog before runtime can show them. Cue authoring may be
future-ready, but the visual runtime remains exact-speaker/audio-only on missing art.

Do not delete the rest-mouth fallback. It is the required safe fallback; the defect
is that all six generated segments reached it silently and permanently under the
real workload.

## 10. Required architect output format

Return one implementation document containing:

1. Verified repository audit and corrections to this handoff.
2. Exact chosen architecture and ownership/state diagrams.
3. Exact versioned JSON schemas and representative complete examples.
4. Exact Swift types, actor isolation, event cases, state transitions, and stale-
   result rules.
5. Exact Python tool changes and runnable authoring commands.
6. File-by-file create/modify list.
7. Migration plan that preserves the locked 37-PR authored set.
8. Focused unit, integration, source-audit, memory, GPU, and device tests.
9. Build/test/validation commands that match the current Xcode project.
10. A mandatory `PASS / BLOCKED / FAIL` completion-report template with evidence.

The resulting directive must be executable by Codex without inventing missing
contracts. If a genuine product decision cannot be derived from the repository,
identify the exact blocker and provide the smallest owner choice needed. Do not use
ordinary implementation details as reasons to stop.
