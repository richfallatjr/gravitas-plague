# Gravitas Plague — Mind’s Eye

## Complete architect implementation handoff

Date: 2026-08-27  
Repository: `/Users/richardfallat/Projects/dev/gravitas-plague`  
Target: visionOS 27  
Status: implementation specification; no Mind’s Eye runtime exists yet and this
document does not claim an on-device pass.

## Authority and scope

This is the implementation handoff. The earlier file
`Gravitas_Plague_Minds_Eye_Procedural_Handheld_Architect_Discovery_Handoff.md`
was a discovery questionnaire and source of product constraints; its instructions
were not an instruction to implement during discovery. This document incorporates
the verified answers from the current repository plus the product owner's current
direction.

The product owner supplied the first Big Mike image package at repository root in:

```text
big-mike/
```

Treat that folder as owner-authored source. Do not rename, replace, optimize, or
duplicate its files without checking the current worktree first. When implementation
needs the package under the bundled Turing resource hierarchy, move it once; do not
copy it and leave a second root copy.

The worktree already contained unrelated owner edits in battle coordinators and a
battle teardown test. Preserve them. Do not reset or overwrite a dirty worktree.

## 1. Executive summary

Mind’s Eye is a fixed, world-space 16:9 portrait that appears at the active story
device while authored or generated speech is audible. It is not a monitor UI and
does not follow the headset. The card stays stable and parallel to its supporting
surface while the imagery inside it moves with soft, seeded, procedural handheld
motion. Static PNG layers provide the background, character, eyes, and five mouth
poses.

The first vertical slice is Big Mike, current time, alive, in his current room:

- all ten eligible authored Big Mike walkie PR audio files;
- an architect-designed offline lip-sync compiler that consumes the supplied PR
  audio/transcripts and generates one sparse, precomputed pose file per PR;
- precomputed high-quality mouth cues for all ten PRs, with no runtime PR-audio
  analysis or phoneme inference;
- generated Big Mike PromptVoice and ConversationVoice responses using a cheap
  amplitude envelope;
- deterministic blinking;
- smooth shared drift, character parallax, and rare grip correction;
- a softly feathered final viewport edge;
- placement above the wall bundle's visual centroid and approximately 1–2 inches
  toward the room, with bounds-based shelf avoidance.

The architecture must be speaker-driven, not Big-Mike-driven. When Rich's authored
walkie voice is playing, show Rich. When Big Mike is playing, show Big Mike. The same
rule later applies to Dad, CatEye81, and the Broadcaster. Select the actual audible
speaker; never select the portrait from the conversation target, output route, or
physical emitter. If the correct speaker's package is absent, show no portrait and
continue audio. Never substitute the wrong character.

Mind’s Eye is presentation only. It must never own, delay, pause, fail, or advance
story progression. Every visual failure is audio-only fallback.

The authored/generated distinction is hard:

- authored PR lip sync is computed offline and shipped as sparse cue data;
- authored PR runtime performs only cue lookup, playback-clock sampling, and random
  choice among already-loaded variants for the selected pose;
- generated TTS cannot be precomputed because its audio does not exist until runtime,
  so it retains the separate cheap amplitude-envelope path.

There are two required audio-pipeline fixes before lip sync can be considered
correct:

1. Primary prerecordings do not currently emit the existing
   `authoredMediaStarted`/`authoredMediaCompleted` lifecycle events. Authored bridge
   items do. Unify them at the actual endpoint start/completion boundary.
2. No public actual media-position clock is present. Capture a monotonic start
   instant immediately after RealityKit's `playAudio`, then account for pauses and
   resumes. Do not use the underscored/private playback-position API.

Memory is a release gate, not a cleanup item. The owner reports that Turing/Qwen is
already near the device limit, approximately 7.5 GB on an 8 GB device, with prior
`SIGABRT` crashes and greater fragility under Xcode or video capture. The project
also previously exceeded the 4 GB thinned App Store bundle limit. Keep one canonical
copy of every asset, load no more than one vignette package, avoid CPU compositing
at frame rate, and measure physical footprint before and after every package load
and release.

## 2. Existing title-card and rectangle placement architecture

### Closest visual precedents

`StoryTitleCardWorldPresenter` owns exactly one current card and one request ID. It
removes the previous card before replacement and installs a fixed transform under a
world anchor. Its visible entity comes from `StoryTitleCardTextFactory`; it is text,
not an image card. It does not billboard or follow the headset after presentation.
It removes immediately; no reusable fade system is present.

Relevant files:

```text
Gravitas Plague/Gravitas Plague/Story/TitleCards/StoryTitleCardWorldPresenter.swift
Gravitas Plague/Gravitas Plague/Story/TitleCards/StoryTitleCardTextFactory.swift
Gravitas Plague/Gravitas Plague/Story/Cinematic/CinematicWorldCardTransform.swift
```

`YouDiedWorldCardPresenter` is the closest image-plane precedent. It loads a
`TextureResource`, preserves image aspect ratio, creates a
`MeshResource.generatePlane(width:height:)`, applies an `UnlitMaterial` with
transparent blending, and replaces its prior entity. Its transform is derived from
the headset/device and therefore must not be reused for Mind’s Eye placement.

```text
Gravitas Plague/Gravitas Plague/Death/YouDiedWorldCardPresenter.swift
```

### Correct first-slice parent

The walkie, Dad frame, shelf, and succulent are a single wall-bundle USDZ owned by:

```text
Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift
```

Its unscaled world root is named `TuringStoryWalkieBundle_WorldRoot`. The imported
USDZ is scaled by `3.0` beneath that root. The controller resolves these useful
entities:

```text
TuringStoryWallBundle_Shelf
TuringStoryWalkieTalkie_Root
TuringStoryWalkieTalkie_AudioEmitter
TuringStoryWalkieTalkieIcon_Root
TuringStoryDadFrame_Root
TuringStoryDadFrame_AudioEmitter
TuringStoryDadFrameIcon_Root
```

The root's local axes are built directly from `wall.right`, `wall.up`, and
`wall.normal`. Therefore a child with identity rotation is wall-parallel, and local
positive Z points along the chosen wall normal toward the room. Parent Mind’s Eye to
this unscaled world root, not to the imported/scaled USDZ and not to an audio emitter.
It will then follow later shelf-placement adjustment without head tracking.

The current 2D `WallPropOccupancyRegistry` prevents overlap between reserved wall
rectangles during initial placement. It cannot prevent a child plane from
intersecting the shelf's 3D geometry. Mind’s Eye needs its own local-bounds placement
resolver described in section 6.

### Future surface parents

The crank radio and ham receiver are both owned by
`TuringRollingBenchBundleController`, under `TuringRollingBench_WorldRoot`:

```text
Gravitas Plague/Gravitas Plague/Turing/Props/TuringRollingBenchBundleController.swift
```

It resolves the cart, crank-radio root/emitter/icon, and ham-receiver
root/emitter/icon. The same placement protocol should support this root later. Do not
put surface selection into a character package: the speech event's
`interactionSurface` selects the placement root, while its `speakerCharacterID`
selects the vignette.

### Required stable hierarchy

Keep this logical entity hierarchy even if the recommended one-texture compositor
renders only one output plane:

```text
MindEyeCardRoot                 // stable, wall-parallel world placement
  MindEyeViewportRoot          // fixed 1920 x 1080 logical viewport
    MindEyeOutputPlane         // recommended single visible plane
    MindEyeContentRoot         // shared internal handheld transform
      MindEyeBackgroundRoot    // counter-motion state
      MindEyeCharacterRoot     // character parallax state
        MindEyeEyesRoot        // follows character exactly
        MindEyeMouthRoot       // follows character exactly
```

The transform entities can be non-rendering state carriers read by the compositor.
Never apply handheld motion to `MindEyeCardRoot`.

Duplicate prevention follows the title-card precedent: one presentation coordinator
owns one current presentation identity. A start for a new playback handle atomically
replaces or updates it; stale completion events must match the active handle before
they may dismiss anything.

## 3. Complete relevant PR inventory

### Inventory rules

The current repository has 45 prerecording descriptors. Thirty-seven are eligible
device/memory PRs for the eventual speaker-driven feature. Eight are explicitly
excluded physical-room or battle speech. Every one of the 37 eligible descriptors
has `transcriptMode: manual`, a nonempty machine-readable transcript in its descriptor,
and a stable local audio file.

Descriptor and audio path templates are:

```text
Turing/Prerecordings/<canonical-pr-id>.json
Turing/Audio/prerecordings/<audio-file>
```

On disk, both are under:

```text
Gravitas Plague/TuringResources/
```

The tables below are the complete eligible list at this repository snapshot.

### Big Mike — first candidate, 10 PRs

All are walkie speech and all select `big_mike_current_room`. Durations are current
`ffprobe` format durations and must be recomputed by the cue authoring tool rather
than copied as constants.

| Canonical PR ID | Script point | Role | Audio file | Current duration |
| --- | --- | --- | --- | ---: |
| `prologue.walkie.bigMike.richContact.001` | `prologue.scriptPoint01` | primary | `pr-big-mike-rich-contact.mp3` | 28.238313 s |
| `prologue.walkie.bigMike.scriptPoint03.001` | `prologue.scriptPoint03` | primary | `pr-big-mike-script-point-03.mp3` | 32.444063 s |
| `prologue.walkie.bigMike.scriptPoint05.001` | `prologue.scriptPoint05` | primary | `pr-big-mike-script-point-05.mp3` | 26.749375 s |
| `prologue.walkie.bigMike.scriptPoint05.002` | `prologue.scriptPoint05` | authored bridge after `headlineReading` | `pr-2-script05-big-mike.mp3` | 33.802438 s |
| `chapter01.walkie.bigMike.script07.001` | `chapter01.walkie.bigMike.script07` | primary | `pr-big-mike-script-06.mp3` | 47.464438 s |
| `chapter01.walkie.bigMike.script09.001` | `chapter01.walkie.bigMike.script09` | primary | `pr-big-mike-walkie-script-09.mp3` | 43.702813 s |
| `chapter02.walkie.bigMike.script01.001` | `chapter02.walkie.bigMike.script01` | primary | `pr-big-mike-nukes.mp3` | 27.402438 s |
| `chapter02.walkie.bigMike.script03.001` | `chapter02.walkie.bigMike.script03` | primary | `pr-big-mike-payback-for-dad.mp3` | 28.551813 s |
| `chapter03.walkie.bigMike.scavengerReport.001` | `chapter03.walkie.bigMike.scavengerReport.001` | primary | `pr-big-mike-reports-scavenger.mp3` | 62.537125 s |
| `chapter03.walkie.bigMike.fading.003` | `chapter03.walkie.bigMike.fading.003` | primary | `pr-big-mike-dont-open-door.mp3` | 56.790385 s |

For all ten rows:

- source device and placement surface: `walkie`;
- authored speaker: `big_mike`;
- transcript: the matching descriptor JSON above;
- playback owner: `TuringStoryWalkiePlaybackCoordinator` created through the
  selected `TuringFlowRouteRuntime`;
- actual audible start: `TuringRealityKitAudioSceneBridge.start` calls
  `child.playAudio`, then `TuringSpatialAudioEndpoint` emits `.started`;
- actual authored lifecycle hook: present for authored bridges, missing for the
  primary-prerecording state and must be fixed;
- actual media-position API: not present;
- completion: `AudioPlaybackController.completionHandler` reaches the scene bridge,
  endpoint `.completed`, and active-handle matching in the playback coordinator;
- physical Big Mike visible: no during these device flows;
- Mind’s Eye eligibility: yes unless the correct package/placement is unavailable or
  the physical-character suppression policy is active.

### Rich — 15 eligible PRs

Rich's audio route is often `roomGlobal` or `walkieOutgoingGlobal`. That does not
change placement. A Rich walkie PR shows Rich above the walkie. A Rich ham PR shows
Rich at the ham receiver. A Rich Dad-frame memory shows Rich at the Dad frame/wall
bundle.

| Canonical PR ID | Script point | Surface | Audio file |
| --- | --- | --- | --- |
| `prologue.room.rich.dadPhotoMemory.001` | `prologue.dadPhotoMemory.001` | dadFrame | `pr-rich-dad-photo-memory.mp3` |
| `prologue.room.rich.hamReceiver.002` | `prologue.hamReceiver.rich.002` | hamReceiver | `pr-rich-ham-radio-script02.mp3` |
| `prologue.walkie.rich.scriptPoint02.001` | `prologue.scriptPoint02` | walkie | `pr-rich-script-point-02.mp3` |
| `prologue.walkie.rich.scriptPoint04.001` | `prologue.scriptPoint04` | walkie | `pr-rich-script-point-04.mp3` |
| `chapter01.room.rich.dadFrame.fourChances.001` | `chapter01.dadFrame.rich.fourChances.001` | dadFrame | `pr-dad-frame-02.mp3` |
| `chapter01.room.rich.dadFrame.script03.001` | `chapter01.dadFrame.rich.script03` | dadFrame | `pr-rich-dad-frame-03.mp3` |
| `chapter01.room.rich.hamReceiver.script04.001` | `chapter01.hamReceiver.rich.script04` | hamReceiver | `pr-rich-ham-receiver-script-04.mp3` |
| `chapter01.walkie.rich.script06.001` | `chapter01.walkie.rich.script06` | walkie | `pr-rich-walkie-talkie-script-06.mp3` |
| `chapter01.walkie.rich.script08.001` | `chapter01.walkie.rich.script08` | walkie | `pr-rich-walkie-script-08.mp3` |
| `chapter02.dadFrame.rich.dadDisappeared.001` | `chapter02.dadFrame.rich.dadDisappeared.001` | dadFrame | `pr-rich-dad-photo-dad-disappeared.mp3` |
| `chapter02.hamReceiver.rich.revelation.001` | `chapter02.hamReceiver.rich.revelation.001` | hamReceiver | `pr-rich-ham-receiever-what-do-you-believe.mp3` |
| `chapter02.hamReceiver.rich.script02.001` | `chapter02.hamReceiver.rich.script02` | hamReceiver | `pr-rich-ham-receiver-dad.mp3` |
| `chapter02.walkie.rich.script02.001` | `chapter02.walkie.rich.script02` | walkie | `pr-rich-walkie-obey.mp3` |
| `chapter03.hamReceiver.rich.faith.001` | `chapter03.hamReceiver.rich.faith.001` | hamReceiver | `pr-rich-ham-receiver-faith.mp3` |
| `chapter03.walkie.rich.connectsMen.002` | `chapter03.walkie.rich.connectsMen.002` | walkie | `pr-rich-walkie-connects-men.mp3` |

### Broadcaster — 5 eligible PRs

All are `crankRadio` and select the Broadcaster's eventual vignette.

| Canonical PR ID | Script point | Audio file |
| --- | --- | --- |
| `prologue.room.broadcaster.crankRadio.001` | `prologue.crankRadioBroadcast.001` | `pr-broadcaster-emergency-broadcast.mp3` |
| `chapter02.crankRadio.broadcaster.missingPersons.001` | same | `pr-broadcast-missing-persons.mp3` |
| `chapter02.crankRadio.broadcaster.gridFailure.002` | same | `pr-broadcast-night-lights-went-out.mp3` |
| `chapter02.crankRadio.broadcaster.gravitasPSA.003` | same | `pr-broadcast-psa-propoganda.mp3` |
| `chapter03.crankRadio.broadcaster.continuity.001` | same | `pr-broadcast-gravitas-continuity.mp3` |

### CatEye81 — 5 eligible PRs

All are `hamReceiver` and select the `cateye81` vignette.

| Canonical PR ID | Script point | Audio file |
| --- | --- | --- |
| `prologue.room.cateye81.hamReceiver.001` | `prologue.hamReceiver.cateye81.001` | `pr-cat-eye-81-script01.mp3` |
| `prologue.room.cateye81.hamReceiver.003` | `prologue.hamReceiver.cateye81.003` | `pr-cat-eye-81-ham-radio-script03.mp3` |
| `chapter01.room.cateye81.hamReceiver.script05.001` | `chapter01.hamReceiver.cateye81.script05` | `pr-cat-eye-81-ham-receiver-script-05.mp3` |
| `chapter02.hamReceiver.cateye81.revelation.002` | same | `pr-cat-eye-81-what-we-chose.mp3` |
| `chapter03.hamReceiver.cateye81.antichrist.002` | same | `pr-cat-eye-81-revelations.mp3` |

### Dad — 2 eligible PRs

Both are `hamReceiver` and select Dad's eventual vignette.

| Canonical PR ID | Script point | Audio file |
| --- | --- | --- |
| `chapter02.hamReceiver.dad.script01.001` | `chapter02.hamReceiver.dad.script01` | `pr-dad-electricity-went-out.mp3` |
| `chapter02.hamReceiver.dad.script03.001` | `chapter02.hamReceiver.dad.script03` | `pr-dad-ham-receiver-do-not-come-looking.mp3` |

### Explicit exclusions — 8 PRs

These do not represent remote-device or Dad-memory Mind’s Eye speech and must not
activate this feature:

| Canonical PR ID | Reason |
| --- | --- |
| `chapter02.room.rich.windowRecognition.001` | physical room/window recognition; its descriptor currently uses `dadFrame` as a routing surface but it is not a Dad-frame Mind’s Eye moment |
| `chapter02.room.rich.womanBattle.001` | physical room/battle speech; same routing caveat |
| `prologue.rich.battle01.mrsDempsey.001` | physical battle speech |
| `chapter01.room.rich.dadFinalBattle.musicThirtySeconds.001` | physical battle speech; transcript mode is `none` |
| `chapter01.room.rich.dadFinalBattle.oneDamageRemaining.001` | physical battle speech; transcript mode is `none` |
| `chapter03.battle.biker.rich.001` | physical battle speech |
| `chapter03.battle.mike.recognition.001` | Rich speaking during physical Mike encounter |
| `chapter03.battle.mike.surrender.002` | Rich speaking during physical Mike encounter |

The two IDs containing `chapter03.battle.mike` are spoken by Rich, not Big Mike.
There is no authored Big Mike voice PR in the physical Mike battle. Robot and Angel
speech are not represented by the current prerecording descriptor catalog and are
outside this feature.

## 4. Big Mike and multi-speaker Turing playback chain

### Canonical identifiers

The repository's canonical character ID is `big_mike`, not `bigMike`. The first
vignette ID is `big_mike_current_room`. Do not alter character metadata to make
portrait routing convenient.

`TuringConversationCharacterID` currently defines:

```text
rich
broadcaster
big_mike
cateye81
dad
```

### Authored PR path

```text
TuringFlowDescriptorStore
  -> TuringPrerecordingStore
  -> TuringAuthoredMediaPlanResolver
  -> TuringAuthoredFlowRunner or TuringFlowEngine staged path
  -> selected TuringFlowRouteRuntime
  -> TuringStoryWalkiePlaybackCoordinator
  -> TuringSpatialAudioEndpoint (or route-equivalent endpoint)
  -> TuringRealityKitAudioSceneBridge.start
  -> Entity.playAudio
  -> AudioPlaybackController.completionHandler
```

Core files:

```text
Gravitas Plague/Gravitas Plague/Turing/Dialog/TuringPrerecordingDescriptor.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringFlowDescriptor.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringAuthoredMediaPlan.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringAuthoredFlowRunner.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringFlowEngine.swift
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringSpatialAudioEndpoint.swift
Gravitas Plague/Gravitas Plague/Turing/Audio/TuringRealityKitAudioSceneBridge.swift
```

`TuringFlowPlaybackLifecycleHub` is already an `AsyncStream` fan-out hub, so a new
feature must not take over the single weak `playbackLifecycleSink` used by live
conversation. The problem is aggregation: each flow creates a playback owner, and
the Mind’s Eye presenter does not know every instance. Add a global spoken-media
presentation hub and have each playback coordinator mirror normalized speech events
into it. Keep the existing local lifecycle hub and sink behavior intact.

The primary-prerecording path stores `ActiveItem.prerecording` only after
`playOneShot` returns. The endpoint's `.started` event can be processed before that
state is installed, and `playbackStarted` has no primary-prerecording case anyway.
Add `startingPrerecording(clip, requestID)` before calling the endpoint, then consume
the matching actual-start event exactly as the authored-bridge and generated paths
already do. Emit matching completion for primary items too.

### Actual speaker selection

For authored PRs, use this precedence:

1. `TuringPrerecordingDescriptor.speaker` — canonical source of truth.
2. `TuringLiveConversationCatalog.Entry.speakerCharacterID` — validated duplicate
   when an entry exists.
3. Reject portrait presentation if those two exist and disagree.

Do not use `conversationTargetCharacterID` for authored speech. The walkie policy
fixes the conversation target to Big Mike, including Rich's outgoing walkie PRs.
Using the target would show Big Mike while Rich is audibly talking, which directly
violates the product requirement.

Add `speakerCharacterID` to `TuringAuthoredMediaItem` when the media plan resolves
the prerecording descriptor. This also covers the second `prologue.scriptPoint05`
authored bridge, which does not have to rely on a live-conversation catalog row.

### PromptVoice and generated segment path

```text
TuringFlowEngine / TuringStagedSpeechRunCoordinator
  -> TuringCharacterQwenRenderSession
  -> decoded [Float] PCM, exact sample rate, currently mono
  -> TuringQwenOutputPostProcessor
  -> TuringGeneratedPlaybackFileStore.write
  -> pending generated segment in playback coordinator
  -> endpoint actual-start event
  -> generated segment completion
  -> transient resource eviction and WAV deletion
```

For a normal PromptVoice continuation, the speaking character is the generated
runtime's `TuringFlowIdentity.characterID`.

### ConversationVoice path

`TuringLiveConversationSeed` intentionally separates the authored immediate speaker
from the conversation target. The generated response request uses
`turn.seed.characterID`, which is `targetContext.targetCharacterID`. Therefore:

- authored cover/PR portrait = `immediateDeviceContext.speakerCharacterID`;
- generated response portrait = `targetContext.targetCharacterID`;
- player microphone/dictation = no character portrait;
- the selected surface remains `turn.selectedSurface` for placement.

`TuringFlowConversationRunner.makeGeneratedOnlyPlayback` creates an identity from
the selected target character runtime. Carry that identity into each normalized
generated start event rather than re-resolving from the surface.

### Normalized presentation event

Add a value-type event context similar to:

```swift
struct TuringSpokenPresentationContext: Sendable, Equatable {
    let playbackRunID: String
    let flowInstanceID: UUID
    let playbackHandle: TuringAudioPlaybackHandle
    let speakerCharacterID: String
    let interactionSurface: StoryInteractionSurfaceID
    let source: Source                 // authored(prID) or generated(segmentIndex)
    let clockOrigin: ContinuousClock.Instant
    let amplitudeEnvelope: TuringSpeechAmplitudeEnvelope?
}
```

The global event stream needs actual start, segment/item completion, pause, resume,
cancel/failure, and whole-response completion. Add generated-segment completion;
the current public lifecycle has generated start and final generated completion but
not individual segment completion.

### Actual playback clock

`ActiveItem` currently records `Date`, which is useful for logs but is not a media
clock. `AudioPlaybackController` exposes play/pause/stop but no supported public
position. Do not call an underscored/private playback-position symbol.

Change `TuringRealityKitAudioSceneBridge.start` to capture
`ContinuousClock.now` immediately after `child.playAudio(prepared.resource)` and
return that origin with the handle. The endpoint's `.started` event must carry the
origin even if the actor receives the event later. Track accumulated paused duration
using monotonic pause/resume instants. The visual time is:

```text
elapsed = now - clockOrigin - accumulatedPausedDuration
```

Clamp to zero and to known cue/envelope duration. Completion still comes from the
audio controller and remains authoritative. If future testing requires sample-frame
accuracy beyond this public RealityKit boundary, that is a separate audio-engine
architecture project, not permission to use private API.

## 5. Texture and layered-rendering path

### Required asset package

Artist deliverables are one canonical folder per vignette under:

```text
Gravitas Plague/TuringResources/Turing/MindsEye/Vignettes/<vignette-id>/
```

The owner-supplied staging folder currently exists at:

```text
big-mike/
  background.png
  character-base.png
  eyes-closed-01.png
  eyes-open-01.png
  mouth-rest-01.png
  mouth-rest-02.png
  mouth-round-01.png
  mouth-small-01.png
  mouth-small-02.png
  mouth-wide-01.png
```

At implementation time, move this folder once into the bundled resource hierarchy
and add only the generated metadata/cue files there:

```text
Gravitas Plague/TuringResources/Turing/MindsEye/Vignettes/big_mike_current_room/
  <the supplied PNG files, preserving their hyphenated names>
  manifest.json
  Cues/
    <canonical-pr-id>.lipsync.json
```

The manifest, not a hard-coded filename parser, lists every variant. Preserve the
owner's current hyphenated naming. Do not rename the files to the older underscore
examples. Do not copy PR audio into the vignette. Cue files refer to the existing
canonical audio resource. After the move, do not leave a second image-package copy
at repository root.

### Current supplied-package validation snapshot

As of 2026-08-27:

- nine files are valid 2304 × 1296 RGBA PNGs;
- `mouth-rest-01.png` is zero bytes and must be repaired by the owner or omitted from
  the manifest; the loader/compiler must reject it rather than crash;
- `mouth-rest-02.png`, `mouth-small-01.png`, and `mouth-small-02.png` establish the
  first multi-variant pose groups;
- there is no `mouth-teeth-*` file yet; do not invent, derive, or duplicate one;
- `background.png` contains an alpha channel with observed alpha range 113–255, so it
  is not currently fully opaque. Report that to the owner and do not silently flatten
  it if the opaque-background contract remains required.

Re-run validation when the architect begins because the owner may repair or add files
after this snapshot.

Every image listed by the final manifest must decode as a 2304 × 1296 PNG.
`background.png` must be fully opaque and painted to every edge. Character, eye, and
mouth layers are transparent, full-canvas, pixel-registered overlays. Eyes and mouths
must contain only their changing pixels; the base must not contain a second visible
copy that causes ghosting.

The preceding paragraph is the target contract; the current alpha finding is an
input-validation issue, not authorization for the architect to modify the owner's
art.

Use a top-level runtime catalog to map canonical speakers to available vignettes,
for example:

```text
Gravitas Plague/TuringResources/Turing/MindsEye/catalog.json
```

Only `big_mike -> big_mike_current_room` is locked now. Add Rich and other mappings
only when their real folders and manifest IDs exist. Never fall back from an absent
speaker mapping to another character.

### Validated manifest schema

Use JSON because all neighboring Turing resources are versioned JSON loaded by
`TuringResourceLoader`. The first manifest should decode to a strongly typed Swift
descriptor and use the repository's canonical `big_mike` ID:

```json
{
  "version": 1,
  "vignetteID": "big_mike_current_room",
  "characterID": "big_mike",
  "sourceWidth": 2304,
  "sourceHeight": 1296,
  "viewportWidth": 1920,
  "viewportHeight": 1080,
  "background": "background.png",
  "base": "character-base.png",
  "eyes": {
    "open": ["eyes-open-01.png"],
    "closed": ["eyes-closed-01.png"]
  },
  "mouths": {
    "rest": ["mouth-rest-02.png"],
    "small": ["mouth-small-01.png", "mouth-small-02.png"],
    "wide": ["mouth-wide-01.png"],
    "round": ["mouth-round-01.png"],
    "teeth": []
  },
  "motion": {
    "sharedDriftMaxPixels": [36, 20],
    "sharedRollMaxDegrees": 0.55,
    "sharedScaleMax": 1.018,
    "characterParallaxMaxPixels": [18, 10],
    "backgroundCounterMotion": 0.28,
    "gripCorrectionMaxPixels": [24, 14],
    "gripCorrectionMaxDegrees": 0.25,
    "microTremorEnabled": false
  }
}
```

The example excludes zero-byte `mouth-rest-01.png`. Add it to `rest` only after it is
a valid image. Add `teeth` variants only when supplied. The descriptor may allow an
empty optional pose family, but its offline compiler must remap unsupported phoneme
groups to an explicitly configured available pose before emitting the cue file.

### Required random variant behavior

Sparse PR cue files store the semantic pose (`rest`, `small`, `wide`, `round`, or
`teeth`), not a permanently chosen texture filename. Whenever the active cue enters a
pose whose validated manifest array contains more than one file, select a variant
uniformly at random from that array. Hold the selected texture until the next cue;
do not reroll every rendered frame or on an unrelated timer.

Use a per-playback seeded PRNG so each playback can produce a different variant
sequence while tests can inject a fixed seed. Give mouth, open-eye, closed-eye, and
any future multi-variant groups independent random streams. When a group has more
than one entry, avoid an immediate repeat when possible. A one-entry group always
uses its sole file. Only validated, fully preloaded variants participate in the draw.
Random texture choice is not runtime lip-sync computation: the offline cue already
determined the pose and exact cue time.

Reject unsupported versions, duplicate IDs, path traversal, non-2304 × 1296 source
images, zero-byte or undecodable listed files, wrong viewport size, missing required
pose groups, counter-motion outside 0.20–0.35, and nonfinite/out-of-range motion
values. A rejected manifest is audio-only, not a story error.

### Rendering choice

Two approaches were evaluated.

| Criterion | A: stacked transparent planes | B: one runtime-composited output texture |
| --- | --- | --- |
| Existing precedent | Direct `UnlitMaterial`/transparent-plane precedent exists | Dynamic output APIs exist in the target SDK, but no repository implementation exists |
| Independent motion | Simple entity transforms | Simple UV/transform uniforms in one compositor |
| Fixed center crop | No repository-native parent clipping path is present | Natural: composite through one 1920 × 1080 target |
| Final static feather | Difficult to apply once after moving children | Natural final-pass mask |
| Alpha/order risk | High: several full-canvas transparent planes, z offsets, and sorting | Low: one final transparent plane |
| Draw surfaces | Background + base + eye + mouth, at minimum | One visible card |
| CPU cost | Low if only material swaps | Low only if GPU composed; unacceptable if Core Graphics recomposes per frame |
| Engineering risk | Lower initial code, higher visual correctness risk | Higher initial Metal work, lower ongoing sorting/clipping risk |

Recommend option B: a small GPU compositor writing a single 1920 × 1080 texture
consumed by one transparent `UnlitMaterial` plane. Apply background and character
transforms, eye/mouth selection, center crop, and the final analytic feather in one
pass. Do not create a 1920 × 1080 `CGContext` or new `CGImage` every frame.

The repository has no current `LowLevelTexture`, `TextureResource.DrawableQueue`,
Metal Mind’s Eye compositor, `ModelSortGroupComponent`, or multi-plane ordering
system. Begin implementation with a narrow device spike proving that a dynamically
written texture remains valid in the `UnlitMaterial` path on visionOS 27. If that
spike fails, option A is the fallback only with an explicit viewport clipping shader,
deterministic render ordering, and on-device alpha tests; merely stacking planes is
not acceptance-complete.

Use sRGB color interpretation and premultiplied alpha in the composed output. Validate
the source PNG alpha convention on device. The repository does not state a global
alpha or mipmap contract for these assets.

## 6. 2304 × 1296 overscan, 1920 × 1080 viewport, and placement

### Viewport math

Source and viewport are both 16:9. The fixed viewport is the centered source rect:

```text
source origin X = (2304 - 1920) / 2 = 192 px
source origin Y = (1296 - 1080) / 2 = 108 px
source viewport = [192, 108, 1920, 1080]
```

Never stretch and never rebuild source textures to move them. Convert output-pixel
motion to normalized UV or compositor transforms. For a card of world width `W` and
height `H`:

```text
worldX = pixelX / 1920 * W
worldY = pixelY / 1080 * H
```

The maximum planned shared drift plus grip correction is approximately ±60 px X and
±34 px Y. Character parallax adds ±18 px X and ±10 px Y. Maximum total roll is about
0.8°. The resulting crop needs approximately 2091 × 1195 source pixels. The locked
2304 × 1296 source leaves approximately 213 px horizontal and 101 px vertical safety.
Do not enlarge sources to 2560 × 1440 without device evidence.

Assert the safe crop in unit tests at sampled translation/roll/scale extremes and
log a debug-only clamp counter. Production must clamp rather than expose a source
edge.

### Initial physical size

Physical size was not product-locked. Use a single tuning value, initially 0.56 m
wide × 0.315 m high, which is slightly narrower than the wall bundle's 0.65 m
reservation. Do not encode size in every speaker package unless later art direction
requires per-vignette size.

### Centroid and 1–2 inch front placement

Add a method on the owning bundle controller that computes placement geometry before
the Mind’s Eye entity is added. Use the imported bundle's bounds relative to the
controller's unscaled world root; do not call `root.visualBounds` after adding the
card, or the card will contaminate its own centroid.

Recommended initial values, all centralized and tunable:

```text
front offset from visual centroid: 0.0381 m (1.5 inches)
allowed tuning range:              0.0254–0.0508 m (1–2 inches)
initial vertical lift:             0.10 m above visual centroid
shelf clearance:                   0.0127 m (0.5 inch)
card width:                        0.56 m
card height:                       0.315 m
```

Resolve in the wall-bundle root's local coordinates:

```text
desiredX = assetBounds.center.x
desiredY = assetBounds.center.y + verticalLift
desiredZ = assetBounds.center.z + frontOffset

if shelf bounds exist:
    resolvedY = max(desiredY, shelfBounds.max.y + shelfClearance + cardHeight / 2)
    resolvedZ = max(desiredZ, shelfBounds.max.z + shelfClearance)
else:
    resolvedY = desiredY
    resolvedZ = desiredZ
```

This places the window higher and toward the room while preventing the plane from
passing through the shelf even when the shelf lies above the raw centroid. If the
shelf entity is absent, use the aggregate asset bounds. If bounds are nonfinite or
empty, use the tuned centroid offset fallback. Emit a debug placement log containing
the asset bounds, shelf bounds, unclamped position, resolved position, and whether
each clamp fired.

Use identity local orientation beneath the bundle root. No billboard component,
head-pose update, or emitter-relative transform is allowed.

For the future rolling bench, expose the same placement-geometry protocol from
`TuringRollingBenchBundleController` and clamp against the relevant radio/bench
visual bounds. Do not block the Big Mike slice on perfect rolling-bench tuning.

## 7. Procedural smooth-random motion owner

No RealityKit ECS `System` or `SceneEvents.Update` subscription currently drives
card motion. `PlagueImmersiveView` publishes a 60 Hz main-thread `Timer`, but this is
not a render callback and should not gain another continuous visual workload.

Add a RealityKit component/system registered once at app initialization. Keep the
seeded motion state as value types in the component/system and keep the main-actor
presentation coordinator responsible only for start, asset changes, pause/resume,
and teardown. If the dynamic texture compositor needs command encoding outside the
ECS update, the System should publish only compact current transforms/pose state to
that renderer; it must not decode images or allocate a frame-sized buffer per tick.

Use quintic smootherstep for every random transition:

```text
u = clamp((t - startTime) / duration, 0, 1)
s = u³ × (u × (u × 6 - 15) + 10)
value = lerp(startValue, targetValue, s)
```

Use separate deterministic PRNG substreams for shared drift, character parallax,
grip correction, blink, and amplitude accents. A production run seed can derive from
`vignetteID + media identity + flowInstanceID`; tests inject a fixed seed. Use a
center-biased bounded target distribution, such as the average of two uniforms
remapped to -1...1, so motion does not live at its clamps.

Motion band A — shared stabilized handheld drift:

```text
target interval:  1.6–4.2 s
transition:       0.9–2.6 s
hold:             0–0.8 s
X:                ±36 px
Y:                ±20 px
roll:             ±0.55°
scale:            1.000–1.018
```

Motion band B — character sway/parallax:

```text
target interval:  2.4–6.0 s
transition:       1.2–3.8 s
X:                ±18 px
Y:                ±10 px
scale delta:      ±0.003
background:       -characterOffset × 0.28
allowed multiplier range: 0.20–0.35
```

Eyes and mouth inherit the character transform exactly. They never have independent
handheld motion.

Motion band C — rare grip correction:

```text
interval:         7–18 s
onset:            0.18–0.35 s
settle:           0.6–1.2 s
X:                ±24 px
Y:                ±14 px
roll:             ±0.25°
```

Settle into the current drift trajectory, not back to zero. Optional micro-tremor is
disabled by default. If tested later, its range is 8–12 Hz, 0.15–0.45 output pixels,
and 0.003–0.012° roll. Remove it if it shimmers or reads as vibration.

Transform motion updates every rendered frame. Mouth and eye state changes remain
approximately 8–12 per second. Never quantize handheld motion to mouth updates.
Motion starts when the card becomes visible, pauses with speech/app suspension,
resumes continuously, and resets on dismissal.

Recommended blink defaults are a seeded 2.4–6.5 second interval, 80–140 ms closed
duration, and a small deterministic double-blink probability. These values are
tunable, not locked art direction. Missing closed-eye art means open-eyed playback,
not failure.

## 8. Background/character parallax implementation

The compositor receives three matrices or compact equivalent values:

1. shared content drift applied to both background and character;
2. `characterOffset` and character scale applied to base, eyes, and mouth;
3. `-characterOffset × counterMotion` applied to background.

The viewport and feather stay static. The background is sampled from its transformed
2304 × 1296 source into the fixed 1920 × 1080 target. The character base, selected eye,
and selected mouth are sampled using the same character transform so pixel alignment
cannot drift. Grip correction contributes to shared drift before parallax.

All calculations should remain in logical output pixels until the final transform.
Do not mix source-pixel and output-pixel limits. The compositor then converts the
logical output transform to source UVs using the fixed center crop.

Add a debug mode that shows the hard 1920 × 1080 viewport, source boundaries,
current offsets/roll/scale, seed, active eye/mouth, and clamp count. Debug data must
not be present in the production visual.

## 9. Authored PR cue preprocessing

### Hard requirement: design an offline pose compiler

The architect owns an offline lip-sync pose system as part of this feature. Authored
PR audio already exists, so no PR waveform analysis, speech recognition, forced
alignment, phoneme inference, or pose generation is allowed in the application at
playback time.

The offline compiler consumes:

```text
canonical PR descriptor
manual transcript from that descriptor
the exact supplied audio file under Turing/Audio/prerecordings
the vignette manifest's available semantic pose groups
```

It emits one small sparse cue file per PR. Runtime preloads and decodes that cue file
and all referenced pose variants before the PR becomes audible. At actual audio start,
runtime performs only a monotonic-clock lookup into already-decoded cue data and a
random draw from an already-loaded variant array. There must be no first-cue texture
load, audio decode, waveform scan, alignment task, or model startup on the playback
critical path.

The compiler must be reproducible from a documented command, version its output,
fail clearly when supplied audio/transcript/art changes, and support batch generation
of every PR selected for a vignette. It must never rewrite or normalize the canonical
PR audio in place.

### Available and missing tools

The repository has a `Scripts/` directory and the current host has:

```text
/opt/homebrew/bin/python3
/opt/homebrew/bin/ffmpeg
/opt/homebrew/bin/ffprobe
```

No forced aligner, phoneme timing library, viseme mapper, or existing lip-sync tool
is present. Design the repository-owned offline compiler around an authoring-only
forced aligner, then normalize its output with a small Python entry point in
`Scripts/`. Do not add the aligner or a neural lip-sync model to the application
bundle, and do not commit the aligner's model/cache/environment. If the chosen aligner
has nondeterministic output, pin its version/configuration and make the final cue
normalization deterministic.

### Cue schema

Store each cue beside the vignette under `Cues/<canonical-pr-id>.lipsync.json`.
Correct the duplicate `audioAsset` key in the earlier conceptual example and add an
audio hash:

```json
{
  "version": 1,
  "compilerVersion": "mind-eye-lipsync-v1",
  "prID": "prologue.walkie.bigMike.richContact.001",
  "audioAsset": "pr-big-mike-rich-contact.mp3",
  "audioSHA256": "<lowercase SHA-256 of source audio bytes>",
  "transcriptSHA256": "<lowercase SHA-256 of normalized transcript>",
  "durationSeconds": 28.238313,
  "cues": [
    { "time": 0.000, "pose": "rest" },
    { "time": 0.120, "pose": "small" },
    { "time": 0.240, "pose": "wide" }
  ]
}
```

The authoring script must:

1. resolve the PR descriptor and existing audio without copying it;
2. reject non-manual or empty transcripts for the high-quality path;
3. decode/probe the exact current audio;
4. run or consume forced-alignment phoneme timings;
5. map phonemes to poses;
6. insert `rest` over real silence;
7. coalesce identical adjacent poses and enforce a practical 60–100 ms minimum hold;
8. write duration and SHA-256;
9. resolve unavailable semantic groups, such as the currently absent `teeth` group,
   through an explicit compiler mapping rather than a runtime guess;
10. validate monotonic finite times within duration;
11. write deterministically so repeated runs do not churn Git;
12. run a batch completeness check proving that every eligible PR for this vignette
    has exactly one current cue file and no orphan cue remains.

Starting phoneme map, to be validated against the delivered art:

```text
rest   silence and pauses
small  M/B/P closures, reduced/narrow consonant transitions
wide   AA/AE/AH/EH/IH/IY/AY and default voiced-open speech
round  W/OW/UH/UW/AO/OY
teeth  F/V/S/Z/SH/ZH/CH/JH/TH/DH
```

The aligner output is not shipped. Only the sparse cue JSON is shipped. An audio
edit invalidates its cue immediately through the audio SHA-256 check. A transcript
edit invalidates it through the transcript SHA-256. A filename match without matching
hashes is not valid.

Decode and validate cue JSON when a flow becomes eligible or is armed, never in the
actual audio-start critical section. If the asset finishes loading after audio has
already started, join late by sampling the current monotonic elapsed time. Never hold
audio for the portrait.

At runtime, select the latest cue whose `time <= elapsed`, using a cursor for forward
play and binary search after resume/late join. On every pose entry, use the random
variant rule from section 5. Cue duration mismatch beyond a small documented
tolerance, malformed cues, missing files, or hash mismatch uses `rest` or suppresses
the mouth visual while audio continues. It must never trigger runtime PR-audio
analysis or reuse the generated-TTS amplitude mapper.

The first cue authoring pass must produce ten Big Mike files, one for every row in
the Big Mike table, including both independent `prologue.scriptPoint05` PRs.

## 10. Turing amplitude-flap implementation

Generated PCM first becomes available in
`TuringCharacterQwenRenderSession.onSegmentDecoded` as `[Float]`, an exact sample
rate, and currently one channel. The playback coordinator then runs
`TuringQwenOutputPostProcessor.processForPlayback` and writes a temporary Float32
non-interleaved WAV through `TuringGeneratedPlaybackFileStore`.

Compute the envelope from `processedAudio`, not the preprocessed samples and not by
rereading the WAV. Put this off-main work beside `TuringGeneratedPlaybackFileStore.write`
and add the immutable result to `PreparedClip`. Extend pending/starting/active
generated states to retain the `PreparedClip`, rather than discarding everything but
the file URL.

Recommended inexpensive envelope:

- mix channels only if future generated audio is not mono;
- RMS windows of approximately 20–30 ms;
- publish envelope samples at 10 Hz, with finer internal windows averaged into each
  bucket;
- derive a per-segment floor and ceiling from robust percentiles, not absolute PCM
  thresholds;
- map true silence to `rest`, low energy to `small`, and medium/high energy primarily
  to `wide`;
- use deterministic, rate-limited `round`/`teeth` accents only on sustained voiced
  buckets, never independent random chatter;
- use attack/release smoothing, threshold hysteresis, and an 80–100 ms minimum hold;
- clamp invalid/nonfinite samples to zero, as the WAV writer already does.

Envelope analysis is O(n), runs once while PCM is already resident, and should be
tiny relative to Qwen decode and WAV I/O. Signpost it and measure first-audio latency.
Do not make envelope availability a playback gate: if analysis fails, play the audio
and use `rest`.

At actual generated segment start, publish the envelope with the monotonic clock
origin. Sample it using the same pause-aware elapsed clock as PR cues. On segment
completion, reset the mouth to rest and release that envelope. At overall response
completion or cancellation, dismiss the correct active portrait and discard every
pending envelope using the existing run/handle stale checks.

## 11. Blurred-edge viewport mask options

The final composition should fade softly into the room while all internal layers
move underneath a fixed viewport edge.

Recommended path: implement an analytic, static feather in the final compositor
pass. A rounded-rectangle signed-distance mask with separately tunable horizontal,
vertical, and corner feather widths is sufficient. Multiply the final premultiplied
alpha once. The mask never follows background or character motion.

Fallback order:

1. analytic final-pass feather;
2. reusable static mask texture applied in the same final pass;
3. hard rectangle while the compositor/mask is unavailable.

Do not make `edge_mask.png` a required artist-delivery file without a later product
decision; it is not in the locked folder contract. Provide a debug switch that
disables the feather and displays the hard viewport.

Soft alpha already works for current transparent unlit image planes, but the
repository has no multi-layer Mind’s Eye alpha/order test. Validate on device against
bright/dark rooms, portal content, and bloom. Fuzzy metal, glass, decorative frame,
scanlines, and transmission UI are stretch work and are not part of the first slice.

## 12. Resource ownership and teardown

### Bundle behavior

`Gravitas Plague/TuringResources/Turing` is an Xcode folder reference, so directory
hierarchy is preserved in the application bundle. `TuringResourceLoader` resolves
subdirectory-relative resources. New Swift files under the app's synchronized source
group should be discovered automatically; the architect must still verify target
membership and the built product rather than editing the project file preemptively.

### Decoded cost

One uncompressed 2304 × 1296 RGBA8 texture is:

```text
2304 × 1296 × 4 = 11,943,936 bytes = 11.39 MiB
```

The original one-file-per-pose baseline has nine source textures: one background,
one base, two eyes, and five mouths. The supplied package introduces additional pose
variants, so cost scales by 11.39 MiB for every full-canvas variant:

```text
9 currently valid supplied sources        = 102.52 MiB
10 sources after mouth-rest-01 is repaired = 113.91 MiB
11 sources after one teeth pose is added   = 125.30 MiB
one 1920 × 1080 RGBA8 output               =   7.91 MiB
10 repaired sources + one output           = 121.82 MiB
11 sources + one output                     = 133.21 MiB
```

Full mip chains add roughly one third. A double/triple-buffered dynamic output adds
another one/two output surfaces. PNG disk compression does not reduce decoded GPU
memory.

### Required loading policy

- One vignette package maximum. No process-wide cache of every character.
- Read and validate manifest/image metadata first without decoding every PNG.
- Prewarm only the next eligible speaker package when a surface/flow is armed, but
  prewarm every validated variant in that package before presentation. Cue-time
  texture loads are forbidden.
- Never delay audio. If prewarming misses the deadline, remain audio-only or join
  late only after the complete package is ready, sampling the current cue time.
- Avoid `TextureResource.load(named:)` as an uncontrolled global-cache strategy for
  package images. Give one package owner all texture references and release them
  together.
- Decode source images sequentially inside autorelease pools so transient full-size
  `CGImage` memory does not stack.
- Measure a tight-alpha-bounds packing path for transparent eye/mouth overlays. The
  source deliverable remains full-canvas and pixel registered, but a loader or
  authoring build step may crop transparent borders while retaining each crop's
  source origin. This can substantially reduce resident pose memory.
- Do not commit generated packed duplicates unless their App Store size cost is
  explicitly accepted. Prefer build intermediates or runtime preparation.
- If texture creation fails or a memory warning arrives, immediately release the
  portrait and continue audio.

`TuringHighMemoryPreflightCoordinator` currently waits for active battle runtime and
closes/unloads the door portal; it does not know about Mind’s Eye. Add an
`evictInactive` hook so preflight can guarantee that no stale vignette survives into
a Qwen run. An actively visible vignette may be required during streamed TTS and
cannot simply be discarded without losing the feature, so the on-device footprint
gate must include the active package cost rather than assuming preflight eliminates
it.

Log `TuringMemoryBudgetProbe` boundaries for manifest metadata load, each texture or
packed layer, output allocation, show, dismiss, source release, and final package
release. A release test must show the expected footprint trend after RealityKit and
autorelease pools have had a chance to drain; do not claim immediate deallocation
from dropping one Swift reference alone.

### Teardown boundaries

Release presentation identity, update state, compositor resources, package textures,
tasks, and stream subscriptions on:

- speech item/response completion;
- playback cancel/failure;
- live-conversation cancellation or stale response;
- chapter cancel/reset/change;
- story teleport;
- operation-mode teardown;
- walkie/wall bundle reset;
- rolling-bench reset/unload;
- immersive shutdown;
- app backgrounding as appropriate;
- memory pressure.

`PlagueImmersiveCoordinator.tearDownOperationModeRuntime` and `.shutdown()` already
centralize the important Story controllers and bundle resets. Bind Mind’s Eye there
and make cleanup idempotent.

## 13. Failure handling

Required behavior:

| Failure | Result |
| --- | --- |
| Missing speaker catalog entry or vignette folder | audio only |
| Missing/invalid manifest | audio only |
| Missing/invalid background | audio only |
| Missing/invalid character base | audio only |
| Missing open eye | character may remain without an eye overlay only if art validates; otherwise audio only |
| Missing closed eye | remain open-eyed; disable blink |
| Missing mouth rest | do not show a broken face; audio only |
| Missing non-rest mouth pose | substitute rest for that pose only |
| Zero-byte/undecodable listed variant | exclude it before presentation; if its pose group becomes empty, use that group's declared fallback |
| Missing/malformed/hash-mismatched PR cue | rest mouth or no mouth visual; never analyze authored PR audio at runtime |
| Envelope failure | rest mouth |
| Motion/system failure | static portrait |
| Compositor failure | try validated hard/stacked fallback; otherwise audio only |
| Feather failure | hard rectangle |
| Placement root/bounds unavailable | audio only |
| Physical-character suppression active | no portrait |
| Any stale completion/cancel event | ignore unless run and handle match |

Every error should produce one concise diagnostic with speaker, surface, media ID,
and fallback. Avoid per-frame log spam. No error from this subsystem may throw into
`TuringFlowEngine`, alter a progression hold, delay an interaction gate, or stop
audio.

## 14. Test plan

### Unit tests

- catalog and descriptive filename decoding;
- canonical `big_mike` mapping and rejection of `bigMike`;
- manifest schema/version/path validation;
- rejection of the current zero-byte `mouth-rest-01.png` unless it is repaired;
- exact 2304 × 1296 source validation and 1920 × 1080 viewport validation;
- center-crop origin `(192, 108)`;
- output-pixel-to-world/UV conversion;
- smootherstep endpoints and zero endpoint velocity;
- seeded trace determinism and independent PRNG substreams;
- center-biased random target distribution;
- every motion clamp and no nonfinite output;
- character/background `-0.28` counter-motion;
- no source-edge exposure at sampled extrema;
- blink scheduling, pause, resume, and missing-eye fallback;
- PR cue monotonic decoding, hash/duration validation, cursor, binary-search resume,
  and missing-cue fallback;
- offline compiler completeness for all ten Big Mike PR IDs, audio/transcript hash
  invalidation, deterministic output, and orphan-cue rejection;
- uniform seeded pose-variant selection, independent variant streams, and no
  immediate repeat when a group has more than one valid file;
- one random variant draw per pose entry, with no per-frame reroll;
- envelope RMS, normalization, silence, hysteresis, hold, smoothing, and cancellation;
- actual-speaker routing for Rich walkie versus Big Mike conversation target;
- surface routing independent of head-tracked/global/spatial output route;
- stale handle/run completion cannot dismiss a replacement portrait;
- excluded eight PR IDs never produce a presentation request;
- missing assets never affect a mocked audio/progression completion.

### Integration tests

- each of the ten Big Mike PRs starts `big_mike_current_room` at actual audio start;
- both PRs in `prologue.scriptPoint05` use their independent cue files;
- authored PR playback performs no audio analysis, forced alignment, model work, or
  cue-time texture I/O;
- all active pose variants are loaded before presentation and the selected variant
  is held until the next sparse cue;
- primary prerecordings and authored bridges emit symmetric actual start/completion;
- Rich walkie PR displays Rich above the walkie even though the conversation target
  is Big Mike and its audio is `walkieOutgoingGlobal`/head-tracked;
- missing Rich package results in audio only, never Big Mike substitution;
- generated Big Mike PromptVoice selects Big Mike and drives its segment envelope;
- live ConversationVoice selects the target response speaker only when generated
  response audio actually starts;
- player dictation does not display a character portrait;
- card remains wall-parallel and stable while internal motion is smooth;
- mouth and eyes remain registered to character parallax;
- card follows shelf placement adjustment through its parent root;
- shelf-bounds clamp prevents geometry intersection;
- physical Chapter 3 Mike encounter suppresses the feature, including Rich battle
  PRs;
- chapter/mode/immersive cancellation removes card, textures, tasks, and subscriptions;
- audio and story complete normally under every injected visual failure.

### On-device visual and performance tests

- handheld effect reads as gently stabilized phone footage, not floating UI wobble;
- parallax is visible but not theatrical;
- no source edges, stretching, z fighting, alpha halos, or stereo discomfort;
- feather works against bright and dark room content and near portals;
- the card is clearly higher and 1–2 inches forward without intersecting shelf;
- PR mouth timing remains convincing across all ten Big Mike files;
- TTS mouth motion does not chatter during noise or silence;
- no main-thread frame-time regression from motion/compositing;
- no first-audio delay with cold or missing portrait assets;
- physical footprint is recorded cold, visible, during Qwen generation/playback, after
  dismissal, after a second run, and after mode/immersive teardown;
- run with TestFlight-equivalent configuration, then separately with capture/debug
  overhead; do not use `SIGABRT` alone as proof of memory pressure.

## 15. Exact existing files to modify

The architect should verify the current worktree before editing. Expected changes:

```text
Gravitas Plague/Gravitas Plague/GravitasPlagueApp.swift
  Register the new RealityKit component/system once.

Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift
  Own/bind the presentation coordinator, surface placement providers, physical-
  encounter eligibility, reset, mode teardown, and immersive shutdown.

Gravitas Plague/Gravitas Plague/Turing/Flow/TuringAuthoredMediaPlan.swift
  Carry the canonical authored speaker on each media item.

Gravitas Plague/Gravitas Plague/Turing/Audio/TuringAudioPlaybackTypes.swift
  Carry an actual monotonic start origin, and actual pause/resume instants if the
  normalized event is implemented at the endpoint layer.

Gravitas Plague/Gravitas Plague/Turing/Audio/TuringRealityKitAudioSceneBridge.swift
  Capture the closest supported actual play/pause/resume clock boundary.

Gravitas Plague/Gravitas Plague/Turing/Audio/TuringSpatialAudioEndpoint.swift
  Forward the timestamped endpoint events.

Gravitas Plague/Gravitas Plague/Turing/Audio/TuringFlowPlaybackLifecycle.swift
  Add context/events only if extending this existing stream. Preserve current sink
  semantics. A separate normalized spoken-presentation event file is preferred if it
  avoids destabilizing live-conversation behavior.

Gravitas Plague/Gravitas Plague/Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift
  Add starting-primary state, symmetric primary lifecycle events, generated segment
  completion, envelope retention, timestamp/pause accounting, and global event fanout.

Gravitas Plague/Gravitas Plague/Turing/Audio/TuringGeneratedPlaybackFileStore.swift
  Compute/store the cheap processed-PCM envelope with `PreparedClip`.

Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWalkieBundleController.swift
  Expose a safe Mind’s Eye parent and placement geometry computed without the card.

Gravitas Plague/Gravitas Plague/Turing/Props/TuringRollingBenchBundleController.swift
  Implement the same placement-provider protocol when non-walkie portraits are wired.

Gravitas Plague/Gravitas Plague/Turing/Memory/TuringHighMemoryScenePreparing.swift
  Allow inactive Mind’s Eye resources to be evicted during Qwen preflight without
  changing battle/door guarantees.

Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter03/Chapter03Coordinator.swift
  Publish physical Mike encounter eligibility/suppression without exposing mutable
  chapter state to the renderer.
```

Avoid modifying every chapter/script-point descriptor. Routing is derived from the
existing canonical PR descriptor, flow identity, live-conversation seed, and
interaction surface. Do not put 37 ad hoc show/hide calls into chapter coordinators.

## 16. Exact files and resources to add

Names may be adjusted to repository style, but keep responsibilities separated:

```text
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeDescriptor.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeCatalogStore.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeAssetPackage.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeAssetPackageLoader.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePresentationCoordinator.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePlacementProvider.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePlacementResolver.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeSpokenPresentationEvent.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeMotionComponent.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeMotionSystem.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeMotionModel.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeLipSyncCue.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePoseVariantSelector.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeAmplitudeEnvelope.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeCompositor.swift
Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeCompositor.metal

Gravitas Plague/Gravitas PlagueTests/Turing/MindsEye/MindEyeDescriptorTests.swift
Gravitas Plague/Gravitas PlagueTests/Turing/MindsEye/MindEyePlacementResolverTests.swift
Gravitas Plague/Gravitas PlagueTests/Turing/MindsEye/MindEyeMotionModelTests.swift
Gravitas Plague/Gravitas PlagueTests/Turing/MindsEye/MindEyeLipSyncCueTests.swift
Gravitas Plague/Gravitas PlagueTests/Turing/MindsEye/MindEyePoseVariantSelectorTests.swift
Gravitas Plague/Gravitas PlagueTests/Turing/MindsEye/MindEyeAmplitudeEnvelopeTests.swift
Gravitas Plague/Gravitas PlagueTests/Turing/MindsEye/MindEyeSpeakerRoutingTests.swift
Gravitas Plague/Gravitas PlagueTests/Turing/MindsEye/MindEyeLifecycleTests.swift

Scripts/generate_mind_eye_lipsync.py
Scripts/validate_mind_eye_assets.py

Gravitas Plague/TuringResources/Turing/MindsEye/catalog.json
Gravitas Plague/TuringResources/Turing/MindsEye/Vignettes/big_mike_current_room/...
```

Do not create duplicate audio, PNG, model, or generated authoring-environment copies
elsewhere in the repository.

## 17. Open questions and `NOT PRESENT` findings

These are implementation facts or remaining art-direction decisions, not permission
to block the first slice:

- `PRESENT, NOT YET BUNDLED`: the owner-supplied `big-mike/` image folder at repository
  root. Nine files currently decode; `mouth-rest-01.png` is zero bytes.
- `NOT PRESENT`: Mind’s Eye runtime, manifest, catalog, offline cue compiler, generated
  cue files, compositor, component/system, and tests.
- `NOT PRESENT`: supported public playback-position clock. Use the timestamped
  monotonic approximation specified above.
- `NOT PRESENT`: primary-prerecording actual start/completion lifecycle event.
- `NOT PRESENT`: generated per-segment completion in the public flow lifecycle.
- `NOT PRESENT`: a global stream aggregating all newly created playback coordinators.
- `NOT PRESENT`: forced aligner, offline pose compiler, or viseme tool in `Scripts/`.
- `NOT PRESENT`: existing RealityKit frame-update system or Scene update subscription
  for this use.
- `NOT PRESENT`: existing dynamic texture/compositor implementation in the repository.
- `NOT PRESENT`: existing multi-transparent-plane ordering policy.
- `NOT PRESENT`: declared Mind’s Eye alpha/mipmap policy or on-device feather proof.
- `NOT PRESENT`: guaranteed public texture-cache eviction after a
  `TextureResource` reference is dropped; measure real release behavior.
- `NOT PRESENT`: Rich, Dad, CatEye81, and Broadcaster vignette IDs/assets. The runtime
  must be ready for them but must not invent or substitute art.
- `NOT PRESENT`: a supplied `teeth` mouth pose. The offline compiler must use an
  explicit available-pose mapping until art is supplied.
- Input issue: supplied `background.png` currently has alpha values below 255 and is
  not fully opaque under the original background contract.
- Tunable: physical card width. Start at 0.56 m.
- Tunable: vertical lift. Start at 0.10 m, then let shelf bounds clamp upward.
- Tunable: front offset within 1–2 inches. Start at 1.5 inches.
- Tunable: feather widths and optional short show/dismiss fade. Existing title cards
  remove immediately; do not add a fade that extends story ownership.
- Tunable: blink cadence and amplitude thresholds, within the behavior above.

The dynamic-texture API must be proven in a minimal visionOS 27 device spike before
the complete compositor is built. Validate the supplied images and move the package
once into the canonical vignette folder during integration; do not convert or
duplicate it as a workaround.

## 18. Recommended narrowest implementation path and acceptance gates

### Phase 0 — preserve and validate incoming art

1. Re-check Git status and locate the owner's Big Mike folder.
2. Re-run validation because the owner may have repaired or added files.
3. Report the zero-byte rest variant, absent teeth pose, and nonopaque background;
   never silently repair owner art.
4. Move the package once from repository root into the canonical Turing vignette
   location. Do not copy it or leave a duplicate.
5. Preserve its hyphenated filenames and add the manifest/catalog entry without
   copying audio.

Gate: one canonical Big Mike package passes the offline validator; app bundle size
change is recorded.

### Phase 1 — actual speech event contract

1. Add canonical authored speaker to media items.
2. Add `startingPrerecording` and symmetric actual primary events.
3. Timestamp actual audio starts with `ContinuousClock` at the scene bridge.
4. Add generated segment completion and global normalized fanout.
5. Prove Rich-walkie speaker selection with no visual implementation.

Gate: tests show exact actual speaker, surface, media identity, clock origin, pause,
resume, completion, and stale-event rejection for authored primary, authored bridge,
PromptVoice, and ConversationVoice.

### Phase 2 — static card and geometry-safe placement

1. Implement manifest/package loader and one-card coordinator.
2. Build the 0.56 m 16:9 output plane under the wall-bundle world root.
3. Apply centroid/front placement and shelf bounds clamp.
4. Show static Big Mike at actual Big Mike PR start and remove at completion.
5. Verify Rich PR requests Rich and becomes audio-only until Rich art exists.

Gate: no head following, no shelf intersection, no duplicate card, audio unaffected by
all asset/placement failures.

### Phase 3 — GPU composition and motion

1. Prove the dynamic output texture on device.
2. Composite background/base/open eyes/rest mouth through fixed viewport.
3. Add deterministic per-frame shared drift, parallax, and grip correction.
4. Add blink and static final feather.
5. Prove no source edge at extrema and no per-frame CPU image allocation.

Gate: smooth on-device image, stable card, correct parallax, acceptable alpha, no
measurable main-thread regression.

### Phase 4 — authored lip sync

1. Design and document the repository-owned offline pose compiler and its pinned
   authoring-only alignment dependency/configuration.
2. Add batch cue generation and validation scripts.
3. Generate all ten sparse Big Mike cue files from the current supplied PR audio and
   manual transcripts, recording both hashes.
4. Preload/decode cue data and every valid pose variant before presentation.
5. Drive semantic poses from the pause-aware monotonic clock, with one random
   manifest-variant draw each time a cue enters a multi-variant pose.
6. Validate both PRs inside `prologue.scriptPoint05` independently.

Gate: every Big Mike PR uses a hash-valid sparse cue; authored playback performs no
audio analysis or texture I/O; repeated playbacks vary multi-variant pose selection;
and every failure still produces uninterrupted audio.

### Phase 5 — generated TTS and lifecycle

1. Compute/store processed-PCM envelope with each `PreparedClip`.
2. Drive each generated segment at 8–12 pose decisions per second.
3. Keep rest mouth through segment gaps and dismiss on real response completion.
4. Add every chapter/mode/immersive/background/memory teardown hook.

Gate: Big Mike PromptVoice and live ConversationVoice work, stale/cancelled responses
cannot animate, and repeated runs release resources.

### Phase 6 — memory and release qualification

1. Measure one full package, packed-overlay variant, dynamic output buffers, Qwen
   overlap, dismissal, and second-run behavior.
2. Run with portals/props/story systems present, then with capture/debug overhead.
3. Confirm no duplicate resources in source or built bundle and recheck thinned size.
4. If memory is unsafe, optimize transparent-overlay residency or output buffering;
   do not shrink the locked source contract or weaken audio progression.

Final acceptance is one complete offline-compiled Big Mike authored PR and one Big
Mike generated response on device, plus batch-generated sparse files and automated
coverage for all ten Big Mike PR identities, random selection among supplied pose
variants, correct Rich walkie routing, physical Mike suppression, audio-only failure,
stable teardown, and measured memory. Only after that proof should the other speaker
folders be wired through the same catalog and event contract.
