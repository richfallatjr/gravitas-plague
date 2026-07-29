# Gravitas Plague - Dad Photo Memory Turing Flow

## Architect Implementation Handoff

**Repository:** `/Users/richardfallat/Projects/dev/gravitas-plague`

**Feature:** A play icon above the dad photograph starts a Rich photo-memory
Turing Flow. The flow plays an authored Rich prerecording, runs a generated Rich
promptVoice grounded in authored father backstory, uses the existing Rich filler
while speech computes, and finishes with a microphone above the photograph for
conversationVoice about the photo.

This is a room-object Turing Flow. It is not a walkie transmission.

---

## 1. Required Player Experience

The production sequence is:

```text
Story wall bundle placed
-> play icon appears at the authored dad-photo icon anchor

player taps play
-> the Story interaction is claimed atomically
-> dad-photo icon, walkie actions, door action, and incompatible prop actions hide
-> special dad-memory background music fades in
-> authored Rich PR begins globally/head-tracked
-> promptVoice Foundation preparation begins concurrently with the PR

PR completes
-> if promptVoice segment 0 is not ready, existing Rich filler plays continuously
-> if segment 0 is ready, it starts immediately

promptVoice segments
-> render through the standard Rich Fresh2 pipeline
-> decode through the standard serialized decoder
-> publish immediately by index
-> play in strict index order as each exact next segment becomes ready
-> use existing Rich filler for any compute gap

actual final promptVoice playback completes
-> special dad-memory music fades out
-> dad-photo microphone icon appears
-> walkie does not receive this microphone state

player holds the dad-photo microphone
-> normal dictation begins
-> release submits conversationVoice
-> dad-photo icon hides while conversationVoice computes and plays
-> Rich conversationVoice plays globally/head-tracked
-> existing Rich filler bridges compute gaps

actual final conversationVoice playback completes
-> dad-photo microphone icon returns
-> player may ask another question about the photo
```

The initial memory score ends after actual promptVoice playback completion. It
does not remain under open-ended conversationVoice. If design later requires
music during conversation, that must be an explicit media policy change rather
than an accidental retained player.

---

## 2. Repository Audit

### 2.1 The dad photo and icon anchor already exist

The dad photo is part of:

```text
Gravitas Plague/TuringResources/Turing/Props/
  turing_story_wall_bundle_v1.usdz
```

The authored USD hierarchy contains:

```text
TuringStoryDadFrame_Root
TuringStoryDadFrameIcon_Root
```

The audited authored transforms inside the bundle are:

```text
TuringStoryDadFrameIcon_Root
  translate: (-0.059999995, -0.03, 0.109999985)

TuringStoryDadFrame_Root
  translate: (-0.06, -0.045, 0)
```

`TuringStoryWalkieBundleController` already resolves:

```swift
var dadFrameAudioEmitter: Entity? { anchors?.dadFrameAudioEmitter }
var dadFrameIconAnchor: Entity? { anchors?.dadFrameIconAnchor }
```

The resolver already prefers:

```text
TuringStoryDadFrameIcon_Root
```

and supports the legacy fallback:

```text
TuringStoryDadFrame_IconAnchor
```

The production implementation must use the authored
`TuringStoryDadFrameIcon_Root`. Do not replace its transform with a new
hard-coded position.

### 2.2 The anchor is currently logged but not interactive

`PlagueImmersiveCoordinator.configureTuringWalkieAudioAndInteraction` currently
logs:

```swift
dadFrame: \(turingWalkieBundleController.dadFrameIconAnchor?.name ?? "nil")
```

but installs an action surface only for the walkie. `PlagueImmersiveView`
likewise has gesture routing for walkie play/microphone components but none for
the dad photo.

The missing work is therefore interaction, state ownership, and flow resources.
The prop does not need to be remodeled.

### 2.3 Rich already has the required audio path

The Rich character runtime already supports:

```text
roomGlobal
walkieOutgoingGlobal
walkieOutgoingHeadset
```

For this feature use:

```text
roomGlobal
```

`TuringRichRoomFlowRoute` already:

- routes Rich to `TuringRichHeadsetAudioRoute`;
- uses the existing `TuringStoryWalkiePlaybackCoordinator`;
- applies Rich's configured PR, generated, and filler gains;
- applies Rich's configured 0.85 playback rate;
- rejects walkie open/send effects and fixed walkie lead-ins.

The current Rich filler catalog is:

```text
Turing/Audio/rich-filler
```

with its existing filename weighting. Do not create a dad-photo filler folder,
copy filler assets, change cadence, or add a new filler selector.

### 2.4 Conversation inputs are already bounded

`TuringConversationInputStore` currently stores, per `conversationKey`:

```text
authored promptVoice Story Context
authored prerecording ID and transcript
conversation prompt variant
```

The dad-photo conversation must use exactly:

```text
player dictation
full Rich character profile
current dad-photo promptVoice authored Story Context
authored dad-photo PR transcript
```

It must not add:

```text
dialogue history
previous generated conversation turns
checkpoint data
room transforms
prop state
walkie state
Battle state
Foundation output from earlier conversations
```

---

## 3. Authored Inputs Required Before Production Enablement

Do not invent father history or infer it from the dad combat character.

The content owner must provide:

| Asset | Canonical production name | Requirement |
| --- | --- | --- |
| Rich PR audio | `pr-rich-dad-photo-memory.mp3` | Final authored Rich recording |
| PR transcript | prerecording JSON below | Exact spoken transcript matching the audio |
| Father backstory | voicePrompt `promptContext` | Authored facts available to promptVoice and conversationVoice |
| Story intent | voicePrompt `intent` | What Rich should say after the PR |
| Memory music | `dad-photo-memory-score.mp3` | Loopable or duration-sufficient authored score |
| Music gain/fades | script-point media descriptor | Authored/tuned values, not hidden constants |

Missing media or placeholder text must fail catalog validation before the icon is
armed. It must not fail after the player taps the photo.

---

## 4. New Resource Identities

Use stable object-specific identities:

```text
scriptPointID:
  prologue.dadPhotoMemory.001

prerecordingID:
  prologue.room.rich.dadPhotoMemory.001

voicePromptID:
  prologue.rich.dadPhotoMemory.followUp.001

conversationKey:
  object.dad_frame

interactionSurface:
  dadFrame

outputRoute:
  roomGlobal
```

Add `prologue.dadPhotoMemory.001` to:

```text
Gravitas Plague/TuringResources/Turing/ScriptPoints/catalog.json
```

The point is user-triggered, independently replayable only when explicitly
reset, and does not automatically advance the Prologue.

---

## 5. Script-Point Descriptor

Extend `TuringFlowDescriptor.Transmission` with optional, backward-compatible
surface and media information:

```swift
struct Transmission: Codable, Sendable, Hashable {
    // Existing properties remain unchanged.
    let interactionSurface: StoryInteractionSurfaceID?
    let backgroundMusic: TuringFlowBackgroundMusicDescriptor?

    var effectiveInteractionSurface: StoryInteractionSurfaceID {
        interactionSurface ?? .walkie
    }
}
```

Existing ScriptPoints 01-05 omit `interactionSurface` and continue to resolve
to `.walkie`. Do not migrate or behaviorally alter them as part of this feature.

Add:

```swift
enum StoryInteractionSurfaceID: String, Codable, Sendable, Hashable {
    case walkie
    case dadFrame
}

struct TuringFlowBackgroundMusicDescriptor:
    Codable,
    Sendable,
    Hashable
{
    enum StopBoundary: String, Codable, Sendable, Hashable {
        case promptVoicePlaybackCompleted
    }

    let resourcePath: String
    let gainDB: Float
    let loops: Bool
    let fadeInSeconds: Double
    let fadeOutSeconds: Double
    let stopBoundary: StopBoundary
}
```

Create:

```text
Gravitas Plague/TuringResources/Turing/ScriptPoints/
  prologue.dadPhotoMemory.001.json
```

Production shape:

```json
{
  "schemaVersion": 2,
  "scriptPointID": "prologue.dadPhotoMemory.001",
  "trigger": {
    "kind": "userPlay",
    "delaySeconds": 0
  },
  "transmission": {
    "prerecordingID": "prologue.room.rich.dadPhotoMemory.001",
    "voicePromptID": "prologue.rich.dadPhotoMemory.followUp.001",
    "characterID": "rich",
    "conversationKey": "object.dad_frame",
    "outputRoute": "roomGlobal",
    "interactionSurface": "dadFrame",
    "computeStart": "withPrerecording",
    "fillerMode": "continuousFromPrerecordingToGenerated",
    "commSFX": {
      "openBeforePrerecording": false,
      "sendAfterGenerated": false,
      "sendingLeadInAfterGeneratedSeconds": null
    },
    "fixedLeadInSeconds": null,
    "generationPipeline": null,
    "backgroundMusic": {
      "resourcePath": "Turing/Audio/Music/dad-photo-memory-score.mp3",
      "gainDB": -18,
      "loops": true,
      "fadeInSeconds": 0.75,
      "fadeOutSeconds": 1.25,
      "stopBoundary": "promptVoicePlaybackCompleted"
    }
  },
  "progression": {
    "nextScriptPointID": null,
    "automaticAdvance": false,
    "interactionGateAfterCompletion": "microphone"
  }
}
```

`gainDB`, fade values, and looping are authored tuning values. The values above
are integration defaults only and must remain resource data so they can be
tuned without code changes.

The important existing choices are:

```text
computeStart = withPrerecording
fillerMode = continuousFromPrerecordingToGenerated
outputRoute = roomGlobal
all commSFX disabled
fixedLeadInSeconds = null
```

---

## 6. Prerecording Descriptor

Create:

```text
Gravitas Plague/TuringResources/Turing/Prerecordings/
  prologue.room.rich.dadPhotoMemory.001.json
```

Shape:

```json
{
  "schemaVersion": 1,
  "prerecordingID": "prologue.room.rich.dadPhotoMemory.001",
  "speaker": "rich",
  "voiceID": "rich_base_clone_v1",
  "voiceVariantID": "rich_reference_01",
  "audioFile": "pr-rich-dad-photo-memory.mp3",
  "transcriptMode": "manual",
  "transcript": "<EXACT AUTHORED RICH PR TRANSCRIPT>",
  "summary": "<SHORT FACTUAL DESCRIPTION OF THE AUTHORED PR>",
  "voicePromptIntent": "The generated Rich continuation is owned by prologue.rich.dadPhotoMemory.followUp.001. Continue after this authored memory without repeating it.",
  "defaultEmotion": "quiet, reflective, emotionally guarded"
}
```

Install the audio at:

```text
Gravitas Plague/TuringResources/Turing/Audio/prerecordings/
  pr-rich-dad-photo-memory.mp3
```

The transcript must be authored and exact. Do not generate a replacement
transcript at runtime and do not use the prerecording summary as the prompt
transcript.

---

## 7. Photo-Memory promptVoice

### 7.1 Do not use walkie wording

The current `voicePrompt_characterIntent.txt` begins with walkie-specific
language. A `roomGlobal` photo memory must not tell Foundation that Rich is
talking over a walkie.

Add an optional prompt template identity:

```swift
enum TuringVoicePromptTemplateID:
    String,
    Codable,
    Sendable,
    Hashable
{
    case characterIntentWalkie
    case roomObjectMemory
}
```

Add to `TuringVoicePromptTriggerDescriptor`:

```swift
let promptTemplateID: TuringVoicePromptTemplateID?

var effectivePromptTemplateID: TuringVoicePromptTemplateID {
    promptTemplateID ?? .characterIntentWalkie
}
```

Existing promptVoice descriptors retain the current template automatically.

Create:

```text
Gravitas Plague/TuringResources/Turing/Prompts/
  voicePrompt_roomObjectMemory.txt
```

Template:

```text
You are {{characterDisplayName}}. You are continuing an aloud personal memory about a photograph of your father.

This is your backstory:
{{characterBackstory}}

This is the authored context for the photograph and your father:
{{storyIntent}}

This is what you just said:
"""
{{prerecordingTranscript}}
"""

Rules:
- Write only the character's new spoken words.
- Continue naturally after what was just said without repeating it.
- Use only the authored father context as episode fact.
- Keep the response personal, specific, and believable to the character.
- Do not invent names, dates, events, relationships, or father history.
- Do not mention game systems, prompts, routing, files, props, HUD, buttons, microphones, audio, Qwen, MLX, Foundation Models, or JSON.
- Segment all speech into natural 3 to 5 second spoken chunks.
- Return a comprehensive 5-6 segment response.
- Every segment must include a short emotional performance description.
- Return JSON only. No markdown. No prose outside JSON.
- Do not include extra keys.

Return this exact sparse JSON schema:
{
  "schemaVersion": 1,
  "segments": [
    {
      "text": "string",
      "emotion": "string"
    }
  ]
}
```

Update `TuringDialogueService.generateVoicePrompt` to select the template from
the descriptor/request. Do not branch on the literal ScriptPoint ID.

### 7.2 Voice prompt descriptor

Create:

```text
Gravitas Plague/TuringResources/Turing/VoicePrompts/
  prologue.rich.dadPhotoMemory.followUp.001.json
```

Shape:

```json
{
  "schemaVersion": 1,
  "voicePromptID": "prologue.rich.dadPhotoMemory.followUp.001",
  "speakerID": "rich",
  "voiceID": "rich_base_clone_v1",
  "characterProfileID": "rich",
  "listenerProfileID": "rich",
  "outputContext": "roomGlobal",
  "conversationKey": "object.dad_frame",
  "promptTemplateID": "roomObjectMemory",
  "intent": "<AUTHORED STORY INTENT FOR RICH'S FOLLOW-UP>",
  "emotion": "<AUTHORED PERFORMANCE INTENT>",
  "promptContext": "Father Memory Context:\n<AUTHORED FATHER BACKSTORY AND PHOTO FACTS>\n\nStory Intent:\n<AUTHORED FOLLOW-UP INTENT>"
}
```

The implementation must reject `<AUTHORED...>` sentinels during catalog
validation.

The full Rich character profile remains supplied from:

```text
Turing/Characters/rich.json
```

The father backstory belongs in this point's authored `promptContext`, not in
the global Rich character profile. This keeps the global profile reusable and
prevents unrevealed father facts from leaking into unrelated Rich prompts.

---

## 8. conversationVoice Contract

### 8.1 Prompt variant

Add:

```swift
case roomObjectMemory
```

to `TuringConversationPromptVariant`, mapped to:

```text
Turing/Prompts/conversationPrompt_roomObjectMemory.txt
```

The variant must be declared by descriptor data. Remove the need to infer prompt
shape from a hard-coded ScriptPoint ID for this new path.

Template:

```text
You are Rich. You respond to the statement about the photograph of your father.

This is your backstory:
{{characterBackstory}}

This is the authored context established for the photograph and your father:
{{promptContext}}

This is what you said before the player responded:
"""
{{prerecordingTranscript}}
"""

This is the statement you are responding to:
"""
{{userInput}}
"""

Rules:
- Respond to the statement in Rich's voice.
- Use only the supplied father and photograph context as episode fact.
- If the player asks beyond the supplied context, answer with ordinary reasoning, memory uncertainty, or say that Rich does not know.
- Do not invent episode lore, father history, names, dates, or events as fact.
- Segment all speech into natural 3 to 5 second spoken phrases.
- Return a comprehensive 5-6 segment response answering the player.
- Every segment must include a short emotional performance description.
- Return JSON only. No markdown. No prose outside JSON.
- Do not include extra keys.

Return this exact sparse JSON schema:
{
  "schemaVersion": 1,
  "segments": [
    {
      "text": "string",
      "emotion": "string"
    }
  ]
}
```

The exact Foundation input contract is:

```text
full Rich character backstory
dad-photo promptVoice promptContext
authored dad-photo PR transcript
current player dictation
```

The generated promptVoice text is not conversation history and is not appended.
No prior conversationVoice output is appended.

### 8.2 Runtime request

The dad-photo controller submits:

```swift
TuringFlowConversationRequest(
    characterID: "rich",
    outputRoute: .roomGlobal,
    conversationKey: "object.dad_frame",
    playerDictation: transcript,
    interactionLease: lease,
    interactionSurface: .dadFrame
)
```

`TuringFlowConversationRunner` must continue using:

```text
TuringCharacterQwenRenderer
Fresh2 scheduler
one serialized speech decoder
TuringStoryWalkiePlaybackCoordinator
Rich head-tracked endpoint
Rich filler catalog
```

No dad-photo-specific renderer, decoder, playback queue, or filler controller is
permitted.

---

## 9. Interaction Surface State

### 9.1 Existing defect to avoid

`TuringFlowInteractionGateController` currently owns one global state and
`StoryInteractionArbiter` maps that state directly to the walkie presentation.
If the dad-photo flow simply calls the existing completion method, the
microphone will appear over the walkie.

That is incorrect.

### 9.2 Surface-aware state

Make gate state surface-aware while preserving existing walkie APIs:

```swift
struct TuringInteractionSurfaceGate: Sendable, Equatable {
    let surfaceID: StoryInteractionSurfaceID
    let state: TuringFlowInteractionGateController.State
    let ownerFlowInstanceID: UUID?
}
```

The controller should retain independent stable states:

```text
walkie
dadFrame
```

Only one may be `.busy` because `StoryInteractionArbiter` still grants one
exclusive Turing lease. Stable idle capabilities may coexist:

```text
walkie microphone
dad frame play
door open
```

The first accepted tap receives the exclusive lease. Once claimed, incompatible
surfaces hide synchronously.

Required API direction:

```swift
func armPlay(
    surfaceID: StoryInteractionSurfaceID,
    reason: String
)

func beginFlow(
    identity: TuringFlowIdentity,
    surfaceID: StoryInteractionSurfaceID
)

func applyCompletionGate(
    _ gate: TuringFlowDescriptor.Progression.InteractionGate,
    identity: TuringFlowIdentity,
    surfaceID: StoryInteractionSurfaceID
)

func beginConversation(
    conversationRunID: UUID,
    surfaceID: StoryInteractionSurfaceID
)

func restoreMicrophoneAfterConversation(
    conversationRunID: UUID,
    surfaceID: StoryInteractionSurfaceID
)
```

Existing no-surface wrappers must delegate to `.walkie`, preserving
ScriptPoints 01-05.

### 9.3 Story arbiter additions

Add capabilities:

```swift
case dadFramePlay
case dadFrameMicrophone
```

Add presentation:

```swift
enum StoryDadFramePresentation: String, Sendable, Equatable {
    case hidden
    case play
    case microphone
}
```

Add `dadFramePresentation` to `StoryInteractionSnapshot`.

Rules:

| Runtime state | Dad frame | Walkie | Door |
| --- | --- | --- | --- |
| Dad memory armed, no exclusive owner | Play | Preserve its stable state | Open if otherwise legal |
| Dad memory flow active | Hidden | Hidden | Hidden |
| Dad promptVoice complete | Microphone | Preserve its stable state | Open if otherwise legal |
| Dad conversation active | Hidden | Hidden | Hidden |
| Dad conversation complete | Microphone | Preserve its stable state | Open if otherwise legal |
| Door or battle owns interaction | Hidden | Hidden | Existing door/battle rule |
| Story teardown | Removed | Removed | Existing teardown |

Do not make the dad-frame controller hide the walkie directly. Presentation is
derived from the arbiter snapshot; exclusivity is enforced by the lease.

---

## 10. Dad-Frame Icon and Gestures

Add distinct components:

```swift
struct TuringStoryDadFramePlayComponent: Component, Codable {}
struct TuringStoryDadFrameMicrophoneComponent: Component, Codable {}
```

Do not reuse `TuringStoryWalkiePlayComponent` because gesture routing must know
which conversation surface was activated.

Add:

```text
Turing/Interaction/TuringStoryDadFrameIconController.swift
Turing/Interaction/TuringStoryDadFrameActionComponents.swift
Turing/Interaction/TuringStoryDadFrameInteractionController.swift
```

The visual must reuse the same established sticker system used by the walkie:

```text
WallStickerStyle
play.circle
mic.circle
UnlitMaterial icon generation
same icon scale as the walkie icon
authored anchor orientation
```

Install the icon under:

```text
TuringStoryDadFrameIcon_Root
```

Create a physical hit target from `dadFrameRoot.visualBounds`, but do not make
the entire shelf trigger the photo memory.

Add RealityKit gestures to `PlagueImmersiveView`:

```swift
TapGesture()
    .targetedToEntity(
        where: .has(TuringStoryDadFramePlayComponent.self)
    )
```

and:

```swift
DragGesture(minimumDistance: 0)
    .targetedToEntity(
        where: .has(TuringStoryDadFrameMicrophoneComponent.self)
    )
```

The microphone uses hold-to-dictate and release-to-submit, matching the walkie
interaction ergonomics. There must be one active dictation owner across both
surfaces. Starting dad-photo dictation while walkie dictation is active must be
rejected by the central interaction lease.

---

## 11. Memory Music Ownership

The score requires its own audio lane because Rich PR/filler/generated audio
must play concurrently.

Add:

```text
Story/Audio/StoryMemoryMusicActor.swift
Turing/Flow/TuringFlowMediaCueCoordinator.swift
```

Use an actor-owned `AVQueuePlayer` plus `AVPlayerLooper`, following the
off-main ownership pattern in `StoryAftermathMusicActor`.

```swift
actor StoryMemoryMusicActor {
    struct Token: Hashable, Sendable {
        let id: UUID
        let flowInstanceID: UUID
    }

    func start(
        descriptor: TuringFlowBackgroundMusicDescriptor,
        flowInstanceID: UUID
    ) async throws -> Token

    func stop(
        token: Token,
        reason: String
    ) async
}
```

Requirements:

- Use direct linear volume conversion: `pow(10, gainDB / 20)`.
- Do not install an `AVAudioMix`.
- Do not synthesize or substitute a hum/noise bed.
- Do not route the music to `dadFrameAudioEmitter`.
- Do not run timers or file loading on `MainActor`.
- Use token identity so stale completion/cancellation cannot stop a newer cue.
- Fade from silence to the configured target.
- Fade out only after actual promptVoice playback completion, flow failure, or
  cancellation.
- Stop and release the player during Story teardown.

If the post-battle aftermath loop is playing, the music coordinator must own the
transition policy. It must not let two unrelated background tracks accumulate.
The safe production behavior is:

```text
capture currently active Story background owner
-> fade that owner down
-> play dad-memory score
-> fade dad-memory score out
-> restore the prior Story background owner
```

Do not make the dad-memory actor retain Battle01 or its coordinator.

---

## 12. Engine Integration

`TuringFlowIdentity` must carry the effective interaction surface:

```swift
let interactionSurface: StoryInteractionSurfaceID
```

The descriptor store constructs identity with:

```swift
descriptor.transmission.effectiveInteractionSurface
```

At point start:

```text
claim Turing lease for dadFrame
-> mark dadFrame busy
-> start memory music
-> start normal Turing Flow
```

At successful actual promptVoice playback completion:

```text
stop memory music at configured boundary
-> apply microphone gate to dadFrame
-> release exclusive Turing lease
```

At failure:

```text
stop memory music
-> release Turing lease
-> restore dadFrame play
-> do not expose dadFrame microphone without a valid conversation seed
```

At conversation start/completion:

```text
beginConversation(surfaceID: .dadFrame)
restoreMicrophoneAfterConversation(surfaceID: .dadFrame)
```

Do not add a ScriptPoint-ID switch to `TuringFlowEngine`. Behavior must come
from the descriptor's route, interaction surface, filler mode, and media cue.

---

## 13. Conversation Seed Commit Ordering

Before dad-photo conversation can be enabled, commit:

```swift
await inputStore.updatePrerecording(
    id: prerecording.prerecordingID,
    transcript: prerecording.transcript,
    for: "object.dad_frame"
)

await inputStore.updatePromptVoiceStoryContext(
    promptVoiceContext.storyContext,
    for: "object.dad_frame"
)

await inputStore.updatePromptVariant(
    .roomObjectMemory,
    for: "object.dad_frame"
)
```

The authored promptVoice Story Context should be committed before Foundation
submission, as the staged promptVoice executor already does. The microphone
still remains unavailable until promptVoice audio actually completes.

This provides deterministic conversation inputs without storing dialogue
history.

---

## 14. Files to Modify

Expected existing files:

```text
Gravitas Plague/Gravitas Plague/
  PlagueImmersiveCoordinator.swift
  PlagueImmersiveView.swift
  Story/Interaction/StoryInteractionTypes.swift
  Story/Interaction/StoryInteractionArbiter.swift
  Turing/Dialog/TuringConversationSeed.swift
  Turing/Dialog/TuringDialogueService.swift
  Turing/Dialog/TuringVoicePromptTriggerDescriptor.swift
  Turing/Flow/TuringEpisodeFlowController.swift
  Turing/Flow/TuringFlowConversationRunner.swift
  Turing/Flow/TuringFlowDescriptor.swift
  Turing/Flow/TuringFlowEngine.swift
  Turing/Flow/TuringFlowIdentity.swift
  Turing/Flow/TuringFlowInteractionGateController.swift
```

Expected new code:

```text
Gravitas Plague/Gravitas Plague/
  Story/Audio/StoryMemoryMusicActor.swift
  Turing/Flow/TuringFlowMediaCueCoordinator.swift
  Turing/Interaction/TuringStoryDadFrameActionComponents.swift
  Turing/Interaction/TuringStoryDadFrameIconController.swift
  Turing/Interaction/TuringStoryDadFrameInteractionController.swift
```

Expected new resources:

```text
Gravitas Plague/TuringResources/Turing/
  Audio/Music/dad-photo-memory-score.mp3
  Audio/prerecordings/pr-rich-dad-photo-memory.mp3
  Prerecordings/prologue.room.rich.dadPhotoMemory.001.json
  Prompts/conversationPrompt_roomObjectMemory.txt
  Prompts/voicePrompt_roomObjectMemory.txt
  ScriptPoints/prologue.dadPhotoMemory.001.json
  VoicePrompts/prologue.rich.dadPhotoMemory.followUp.001.json
```

Also update:

```text
Turing/ScriptPoints/catalog.json
```

---

## 15. Logging Contract

Required logs:

```text
[TuringDadPhoto] anchors resolved
  root: TuringStoryDadFrame_Root
  iconAnchor: TuringStoryDadFrameIcon_Root
  anchorSource: authoredUSDZ

[TuringDadPhoto] presentation changed
  state: play|hidden|microphone
  capability: dadFramePlay|dadFrameMicrophone|none
  arbiterRevision: ...

[TuringDadPhoto] play claimed
  scriptPointID: prologue.dadPhotoMemory.001
  interactionSurface: dadFrame
  conversationKey: object.dad_frame

[TuringDadPhotoMusic] started
  resource: ...
  gainDB: ...
  loops: ...
  flowInstanceID: ...

[TuringDadPhoto] promptVoice completed
  actualPlaybackCompleted: true
  conversationSeedReady: true
  nextPresentation: microphone

[TuringDadPhoto] conversation submitted
  characterID: rich
  outputRoute: roomGlobal
  conversationKey: object.dad_frame
  userInputUTF16: ...
  dialogueHistoryIncluded: false

[TuringDadPhotoMusic] stopped
  boundary: promptVoicePlaybackCompleted
  priorStoryMusicRestored: true|false
```

Log the exact Foundation prompt through the existing Foundation prompt logging
path. Do not create a dad-photo logger that omits the raw request.

---

## 16. Required Tests

### Asset and catalog

```text
testDadFrameAuthoredIconAnchorResolves
testDadPhotoScriptPointIsInCatalog
testDadPhotoDescriptorUsesRoomGlobal
testDadPhotoDescriptorDisablesAllWalkieEffects
testDadPhotoDescriptorUsesRichCharacterAndFillerPolicy
testDadPhotoResourcesRejectAuthoredPlaceholderSentinels
```

### Interaction

```text
testDadFramePlayAppearsAtAuthoredAnchor
testDadFrameTapClaimsExactlyOneTuringLease
testDadFrameIconHidesSynchronouslyAfterClaim
testWalkieAndDoorHideWhileDadMemoryOwnsLease
testDadFrameMicrophoneAppearsOnlyAfterActualPromptVoicePlaybackCompletion
testWalkieMicrophoneDoesNotAppearForDadMemoryCompletion
testDadConversationCompletionRestoresDadFrameMicrophone
testDoorOrBattleOwnershipHidesDadFrameInteraction
testStoryTeardownRemovesDadFrameTargets
```

### Speech

```text
testDadPRAndPromptVoicePreparationOverlap
testDadPRCompletesBeforeGeneratedSegmentZeroCanPlay
testRichFillerBridgesDadPRToLateSegmentZero
testDadGeneratedAudioUsesRoomGlobalHeadTrackedRoute
testDadFlowUsesExistingRichFillerCatalogAndWeighting
testDadFlowDoesNotStartWalkieStaticOpenOrSendEffects
testDadConversationUsesOnlyPlayerProfileContextAndAuthoredPR
testDadConversationDoesNotStoreDialogueHistory
testDadConversationUsesSameFresh2RendererAndDecoderAsOtherRichFlows
```

### Music

```text
testDadMemoryMusicStartsBeforePRPlayback
testDadMemoryMusicDoesNotOccupyRichSpeechEndpoint
testDadMemoryMusicStopsAfterActualPromptVoicePlaybackCompletion
testDadMemoryMusicStopsOnFailureAndCancellation
testStaleMusicTokenCannotStopNewerMemoryCue
testPriorStoryBackgroundMusicRestoresAfterDadMemory
testDadMusicUsesDirectGainWithoutAudioMixOrSyntheticHum
```

Tests must use completion events and continuations. Do not use arbitrary sleeps
to prove audio ordering.

---

## 17. Vision Pro Acceptance

1. Enter Story and complete the existing room placement.
2. Confirm the dad frame remains part of the wall bundle.
3. Confirm the play icon is centered at `TuringStoryDadFrameIcon_Root`.
4. Confirm the icon matches the walkie sticker style and size.
5. Confirm the play icon is selectable without selecting the whole shelf.
6. Tap play once.
7. Confirm the icon disappears immediately.
8. Confirm a second tap cannot start another flow.
9. Confirm the door and walkie cannot start conflicting work.
10. Confirm dad-memory music fades in without hum or gain distortion.
11. Confirm Rich PR plays from the player/headset, not from the picture.
12. Confirm promptVoice computes while the PR plays.
13. Confirm Rich filler starts only when the PR ends before segment zero is ready.
14. Confirm the filler uses files from the existing Rich filler directory.
15. Confirm generated segment zero starts as soon as it is the exact next ready
    segment.
16. Confirm no batch/wait-for-all playback barrier exists.
17. Confirm every Rich segment is global/head-tracked.
18. Confirm no walkie open, send, ambient-static, or sending-static effect plays.
19. Confirm memory music fades out only after actual final promptVoice playback.
20. Confirm the microphone appears above the dad photo, not the walkie.
21. Hold the photo microphone and speak about the image.
22. Confirm release submits one conversationVoice request.
23. Confirm the exact prompt includes Rich's profile, authored father context,
    authored PR transcript, and current dictation.
24. Confirm no prior generated turns or dialogue history are present.
25. Confirm Rich filler bridges any conversation compute gap.
26. Confirm conversationVoice plays globally/head-tracked.
27. Confirm the dad-photo microphone returns after actual conversation playback.
28. Repeat conversation at least three times.
29. Open the door and confirm photo interaction hides according to arbiter rules.
30. Tear down Story and confirm icon, music, dictation, and Tasks release.

---

## 18. Rejection Checks

Reject the implementation if any of the following is present:

```text
ScriptPoint-ID switch for dad-photo playback behavior
new Rich filler folder or filler cadence
dad-photo-specific Qwen renderer or decoder
Rich speech emitted spatially from the frame
walkie static or comm effects in the photo flow
walkie microphone shown after dad-photo promptVoice
dialogue-history accumulation
generated promptVoice text appended as conversation history
background music sharing the one-shot Rich speech endpoint
background player retained after flow failure or Story teardown
hard-coded replacement for the authored icon-anchor transform
MainActor AVAudioPlayer/AVQueuePlayer setup or file loading
sleep-based audio completion
placeholder father history shipped as production content
```

---

## 19. Completion Report

The implementation report must include:

```text
exact authored dad-frame anchor resolved on device
all files added and modified
final PR filename and exact transcript
final father backstory/promptContext
final promptVoice raw Foundation input
final conversationVoice raw Foundation input
proof output route is roomGlobal
proof existing Rich filler directory and cadence were used
proof no walkie comm effects ran
proof promptVoice Foundation overlapped PR playback
proof segment zero played without a wait-for-all barrier
proof dad-photo microphone appeared after actual playback completion
proof walkie microphone did not receive the dad-photo gate
music start/stop token logs
three repeated conversationVoice device results
memory snapshots before flow, after promptVoice, and after teardown
remaining authored-content or device failures
```

Do not report completion based on compilation alone. The interaction surface,
audio route, filler behavior, music lifecycle, and repeated conversation path
must be proven on Vision Pro.
