# Gravitas Plague - Ham Receiver Three-Point Turing Flow

## Complete Architect Implementation Handoff

**Repository:** `/Users/richardfallat/Projects/dev/gravitas-plague`  
**Status:** Architecture and implementation directive  
**Feature:** CatEye81 Script01 -> Rich Script02 -> CatEye81 Script03  
**Production surface:** rolling-bench ham receiver  

---

## 1. Product Contract

The ham receiver becomes one authored, three-point Turing sequence:

```text
player presses play above the ham receiver
-> Script01 CatEye81 runs through actual promptVoice playback completion
-> Script02 Rich starts automatically
-> Script02 runs through actual promptVoice playback completion
-> Script03 CatEye81 starts automatically
-> Script03 runs through actual promptVoice playback completion
-> microphone appears above the ham receiver
-> player may ask CatEye81 follow-up questions
```

There is no microphone, play icon, or interaction lease gap between the three
points.

The final microphone belongs to CatEye81 and uses only Script03's authored
promptVoice context and Script03's reviewed PR transcript as its deterministic
conversation seed.

This feature must reuse the production Turing machinery. It must not introduce:

```text
a Script02-specific runner
a Script03-specific runner
a second generated playback queue
a second speech decoder
a ham-specific Foundation session cache
conversation history
a summary of prior generated speech
walkie open/send effects
head-locked CatEye81 speech
spatial Rich speech from the receiver
```

---

## 2. Audited Repository Baseline

The current implementation already contains:

```text
TuringEpisodeFlowController
  automatic priorScriptPointCompleted progression
  one interaction lease across an automatic chain

TuringCatEye81HamReceiverFlowRoute
  CatEye81 spatial PR and generated speech
  ham-receiver tuning-loop gap bridge

TuringRichRoomFlowRoute
  Rich head-tracked/global PR, filler, and generated speech
  no walkie communication effects

TuringHamReceiverBedActor
  current ham ambient bed
  current gain: -15 dB
  current temporary source:
    Turing/Audio/rolling-bench/Narrow-band-analog.wav

TuringRandomTuningLoopActor.hamReceiver
  ham-radio-tuning-static-01.mp3
  ham-radio-tuning-static-02.mp3
  ham-radio-tuning-static-03.mp3
  ham-radio-tuning-static-04.mp3

TuringStoryHamReceiverInteractionController
  play/microphone gesture ownership
  CatEye81 conversationVoice submission

Rich runtime
  voice: rich_base_clone_v1
  playback rate: 0.85
  generated gain: -5 dB
  PR gain: -5 dB
  filler gain: -11 dB
  existing weighted Rich filler directories

CatEye81 runtime
  voice: cateye81_base_clone_v1
  profile: cateye81.prologue
  route: hamReceiverSpatial
  existing clone artifacts are already generated
```

Do not rebuild either voice clone for this feature.

### New authored media already present

```text
/Users/richardfallat/Projects/dev/gravitas-plague/pr-rich-ham-radio-script02.mp3
  duration: 37.642438 seconds
  size: 637845 bytes
  codec: MP3
  sample rate: 44100 Hz
  channels: mono
  SHA-256:
    4eb04a0656565f1ecc724f13fac847d4f3c3a98bf01302f92a52ed87dd06359d

/Users/richardfallat/Projects/dev/gravitas-plague/pr-cat-eye-81-ham-radio-script03.mp3
  duration: 66.220375 seconds
  size: 1095092 bytes
  codec: MP3
  sample rate: 44100 Hz
  channels: mono
  SHA-256:
    621b8da451b233e182cde4dd6a04fdbb84e578969146d56cf44a4c607a9390d2
```

Install byte-identical copies at:

```text
Gravitas Plague/TuringResources/Turing/Audio/prerecordings/
```

The source files at repository root may remain as authoring inputs until the
user approves their removal.

---

## 3. Exact Sequence State Machine

```text
idle
  ham icon: play
  ambient: stopped
  tuning: stopped

play claimed
  one StoryInteractionArbiter lease
  ham icon: hidden
  physical ham action: disabled
  begin one sequence-scoped ambient session

script01Foundation
  CatEye81 Foundation promptVoice preparation
  ambient: playing at ham receiver
  tuning: playing at ham receiver
  PR: withheld

script01PRAndTTS
  tuning stops when Foundation succeeds
  CatEye81 PR starts spatially
  CatEye81 Fresh2 render/decode begins
  ambient remains
  tuning bridges only missing exact generated indexes

script01Complete
  wait for actual final generated playback completion
  no icon
  no microphone
  ambient remains
  automatically enter Script02

script02Foundation
  Rich Foundation promptVoice preparation begins
  Rich PR remains withheld
  ambient remains spatially attached to the ham receiver
  ham tuning filler is not used for Rich

script02PRAndTTS
  Foundation succeeds
  Rich PR begins globally/head-tracked
  Rich Fresh2 render/decode begins at the same boundary as PR playback
  Rich weighted filler bridges PR-to-generated and missing exact indexes
  ambient remains spatially attached to the ham receiver

script02Complete
  wait for actual final generated playback completion
  no icon
  no microphone
  ambient remains
  automatically enter Script03

script03Foundation
  CatEye81 Foundation promptVoice preparation
  ambient remains
  tuning plays
  PR is withheld

script03PRAndTTS
  tuning stops when Foundation succeeds
  CatEye81 PR starts spatially
  CatEye81 Fresh2 render/decode begins
  ambient remains
  tuning bridges only missing exact generated indexes

script03Complete
  wait for actual final generated playback completion
  stop exact tuning owner
  stop exact sequence ambient owner
  apply microphone gate to hamReceiver
  release sequence interaction lease
  show microphone above ham receiver

follow-up conversation
  pinch begins dictation
  begin a conversation-scoped ambient session
  begin ham tuning filler
  run CatEye81 conversationVoice
  stop tuning when exact segment zero is ready
  play CatEye81 generated speech spatially
  use tuning only for later missing exact indexes
  ambient remains through actual final playback completion
  stop conversation ambient
  restore microphone
```

If any point fails:

```text
stop the exact tuning owner
stop the exact sequence ambient owner
cancel generated input and playback for that run
release the interaction lease
restore the ham play icon
do not auto-advance
do not expose a microphone with incomplete Script03 context
```

---

## 4. Canonical Identities

Use these IDs:

```text
Script01:
  scriptPointID:   prologue.hamReceiver.cateye81.001
  prerecordingID:  prologue.room.cateye81.hamReceiver.001
  voicePromptID:   prologue.cateye81.hamReceiver.followUp.001
  characterID:     cateye81
  outputRoute:     hamReceiverSpatial

Script02:
  scriptPointID:   prologue.hamReceiver.rich.002
  prerecordingID:  prologue.room.rich.hamReceiver.002
  voicePromptID:   prologue.rich.hamReceiver.followUp.002
  characterID:     rich
  outputRoute:     roomGlobal

Script03:
  scriptPointID:   prologue.hamReceiver.cateye81.003
  prerecordingID:  prologue.room.cateye81.hamReceiver.003
  voicePromptID:   prologue.cateye81.hamReceiver.followUp.003
  characterID:     cateye81
  outputRoute:     hamReceiverSpatial

All three:
  conversationKey:    object.ham_receiver
  interactionSurface: hamReceiver
```

The current key `object.ham_receiver.cateye81` is character-shaped even though
the surface now contains both Rich and CatEye81. Migrate it atomically to
`object.ham_receiver` in:

```text
Script01 ScriptPoint descriptor
Script01 voicePrompt descriptor
Script02 ScriptPoint and voicePrompt descriptors
Script03 ScriptPoint and voicePrompt descriptors
TuringStoryHamReceiverInteractionController
resource tests
```

On one migration release, clear the old key during Story reset/removal. Do not
dual-write both keys and do not place either key string in a Foundation prompt.

The same conversation key is required by the existing catalog validator across
every progression edge.

---

## 5. Exact ScriptPoint Descriptors

### 5.1 Updated Script01

`Turing/ScriptPoints/prologue.hamReceiver.cateye81.001.json`

```json
{
  "schemaVersion": 2,
  "scriptPointID": "prologue.hamReceiver.cateye81.001",
  "trigger": {
    "kind": "userPlay",
    "delaySeconds": 0
  },
  "transmission": {
    "prerecordingID": "prologue.room.cateye81.hamReceiver.001",
    "voicePromptID": "prologue.cateye81.hamReceiver.followUp.001",
    "characterID": "cateye81",
    "conversationKey": "object.ham_receiver",
    "outputRoute": "hamReceiverSpatial",
    "interactionSurface": "hamReceiver",
    "computeStart": "foundationBeforePrerecording",
    "fillerMode": "none",
    "commSFX": {
      "openBeforePrerecording": false,
      "sendAfterGenerated": false,
      "sendingLeadInAfterGeneratedSeconds": null
    },
    "fixedLeadInSeconds": null,
    "generationPipeline": null,
    "backgroundMusic": null
  },
  "progression": {
    "nextScriptPointID": "prologue.hamReceiver.rich.002",
    "automaticAdvance": true,
    "interactionGateAfterCompletion": "closed"
  }
}
```

### 5.2 New Script02 Rich

`Turing/ScriptPoints/prologue.hamReceiver.rich.002.json`

```json
{
  "schemaVersion": 2,
  "scriptPointID": "prologue.hamReceiver.rich.002",
  "trigger": {
    "kind": "priorScriptPointCompleted",
    "delaySeconds": 0
  },
  "transmission": {
    "prerecordingID": "prologue.room.rich.hamReceiver.002",
    "voicePromptID": "prologue.rich.hamReceiver.followUp.002",
    "characterID": "rich",
    "conversationKey": "object.ham_receiver",
    "outputRoute": "roomGlobal",
    "interactionSurface": "hamReceiver",
    "computeStart": "foundationBeforePrerecording",
    "fillerMode": "continuousFromPrerecordingToGenerated",
    "commSFX": {
      "openBeforePrerecording": false,
      "sendAfterGenerated": false,
      "sendingLeadInAfterGeneratedSeconds": null
    },
    "fixedLeadInSeconds": null,
    "generationPipeline": null,
    "backgroundMusic": null
  },
  "progression": {
    "nextScriptPointID": "prologue.hamReceiver.cateye81.003",
    "automaticAdvance": true,
    "interactionGateAfterCompletion": "closed"
  }
}
```

`roomGlobal` is intentional. It gives Rich the existing player/head-tracked
endpoint and existing Rich filler without importing the walkie's open/send
effects. The ham ambient remains spatial because it is owned separately by the
sequence-scoped ham bed.

### 5.3 New Script03 CatEye81

`Turing/ScriptPoints/prologue.hamReceiver.cateye81.003.json`

```json
{
  "schemaVersion": 2,
  "scriptPointID": "prologue.hamReceiver.cateye81.003",
  "trigger": {
    "kind": "priorScriptPointCompleted",
    "delaySeconds": 0
  },
  "transmission": {
    "prerecordingID": "prologue.room.cateye81.hamReceiver.003",
    "voicePromptID": "prologue.cateye81.hamReceiver.followUp.003",
    "characterID": "cateye81",
    "conversationKey": "object.ham_receiver",
    "outputRoute": "hamReceiverSpatial",
    "interactionSurface": "hamReceiver",
    "computeStart": "foundationBeforePrerecording",
    "fillerMode": "none",
    "commSFX": {
      "openBeforePrerecording": false,
      "sendAfterGenerated": false,
      "sendingLeadInAfterGeneratedSeconds": null
    },
    "fixedLeadInSeconds": null,
    "generationPipeline": null,
    "backgroundMusic": null
  },
  "progression": {
    "nextScriptPointID": null,
    "automaticAdvance": false,
    "interactionGateAfterCompletion": "microphone"
  }
}
```

Add Script02 and Script03 to `Turing/ScriptPoints/catalog.json` immediately
after Script01.

---

## 6. PR Resource Contract

Create:

```text
Turing/Prerecordings/prologue.room.rich.hamReceiver.002.json
Turing/Prerecordings/prologue.room.cateye81.hamReceiver.003.json
```

### Script02 Rich shape

```json
{
  "schemaVersion": 1,
  "prerecordingID": "prologue.room.rich.hamReceiver.002",
  "speaker": "rich",
  "voiceID": "rich_base_clone_v1",
  "voiceVariantID": "rich_reference_01",
  "audioFile": "pr-rich-ham-radio-script02.mp3",
  "transcriptMode": "manual",
  "transcript": "REVIEWED_VERBATIM_TRANSCRIPT_REQUIRED",
  "summary": "Rich identifies himself over the ham radio, gives only a general Pennsylvania region, and asks CatEye81 what she knows about the reported Gravitas beacon.",
  "voicePromptIntent": "Continue using prologue.rich.hamReceiver.followUp.002.",
  "defaultEmotion": "relieved, cautious, technical, skeptical, trying not to sound desperate"
}
```

### Script03 CatEye81 shape

```json
{
  "schemaVersion": 1,
  "prerecordingID": "prologue.room.cateye81.hamReceiver.003",
  "speaker": "cateye81",
  "voiceID": "cateye81_base_clone_v1",
  "voiceVariantID": "cateye81_reference_01",
  "audioFile": "pr-cat-eye-81-ham-radio-script03.mp3",
  "transcriptMode": "manual",
  "transcript": "REVIEWED_VERBATIM_TRANSCRIPT_REQUIRED",
  "summary": "CatEye81 answers the Pennsylvania station and establishes the authored on-air context before her generated Gravitas-beacon details.",
  "voicePromptIntent": "Continue using prologue.cateye81.hamReceiver.followUp.003.",
  "defaultEmotion": "relieved, guarded, careful, increasingly hopeful"
}
```

### Transcript requirement

The two recordings do not contain embedded transcript metadata, and no exact
transcript was supplied with this handoff. Do not infer or invent their words
from the Story Intents.

Before catalog acceptance:

```text
run the approved speech-to-text transcription workflow on each PR
-> compare the output against the actual waveform
-> manually correct names, callsigns, frequencies, punctuation, and numbers
-> store the reviewed verbatim transcript
-> keep transcriptMode = manual
```

The build or resource test must reject the literal
`REVIEWED_VERBATIM_TRANSCRIPT_REQUIRED`.

The exact reviewed transcript is what enters promptVoice and what is retained
for the final Script03 conversation seed.

---

## 7. Exact PromptVoice Descriptors

### 7.1 Update Script01 conversation key only

In `prologue.cateye81.hamReceiver.followUp.001.json`, change:

```text
"conversationKey": "object.ham_receiver"
```

Do not otherwise rewrite Script01's profile, intent, template, route, or voice.

### 7.2 New Rich Script02 prompt descriptor

`Turing/VoicePrompts/prologue.rich.hamReceiver.followUp.002.json`

```json
{
  "schemaVersion": 1,
  "voicePromptID": "prologue.rich.hamReceiver.followUp.002",
  "speakerID": "rich",
  "voiceID": "rich_base_clone_v1",
  "characterProfileID": "rich",
  "listenerProfileID": "cateye81",
  "outputContext": "roomGlobal",
  "conversationKey": "object.ham_receiver",
  "promptTemplateID": "richHamReceiver",
  "intent": "I’m relieved to hear another living person answer, but I’m trying not to sound too eager or give away more than I should over an open frequency. I’m somewhere in Pennsylvania, and for now I’m only giving my handle and general region. I’ve heard fragments about a Gravitas beacon that can request an antigen delivery by drone, but I have never heard the beacon myself and I do not know whether the reports are real.\n\nI need CatEye81 to tell me what she personally heard, what came from another operator, and whether anyone actually confirmed receiving an antigen package. I need the band, exact dial frequency, sideband mode, transmission schedule, and the identifying sound or code that separates the real Gravitas relay from interference or somebody imitating it. My ham equipment is old and only partly functional, so I need the numbers spoken slowly and repeated clearly. I may also need to know what information the relay expects, whether a handle and grid square are enough, and how long I have to remain on frequency after making contact.\n\nI’m trying to sound technical and skeptical because that is easier than admitting how badly I need this to be real. A working Gravitas relay would be the first concrete evidence that somebody outside the immediate area is still organized and capable of helping. I also do not want this contact with CatEye81 to disappear after one exchange. I want to establish a dependable frequency and time to call again, compare what each of us is hearing, and trade only information we can verify.",
  "emotion": "relieved, guarded, technical, skeptical, quietly desperate for the report to be real"
}
```

### 7.3 New CatEye81 Script03 prompt descriptor

`Turing/VoicePrompts/prologue.cateye81.hamReceiver.followUp.003.json`

```json
{
  "schemaVersion": 1,
  "voicePromptID": "prologue.cateye81.hamReceiver.followUp.003",
  "speakerID": "cateye81",
  "voiceID": "cateye81_base_clone_v1",
  "characterProfileID": "cateye81.prologue",
  "listenerProfileID": "rich",
  "outputContext": "hamReceiverSpatial",
  "conversationKey": "object.ham_receiver",
  "promptTemplateID": "cateye81HamReceiver",
  "intent": "I’m relieved the Pennsylvania station asked about the Gravitas beacon because I’ve been holding onto information I wasn’t sure I would ever get to share. Three nights ago, I copied the same automated identifier twice on the sixty-meter band. Later, I heard another operator report that Gravitas accepted their request and delivered a sealed antigen package by drone. I did not witness the delivery myself, but I heard enough of the exchange to believe the relay is real.\n\nThe automated beacon is on 5.3465 megahertz upper sideband, sixty-meter Channel Two. It transmits three short digital bursts and repeats the same identifier near the top and bottom of the hour. After the identifier is copied cleanly, the operator moves to 5.3305 megahertz upper sideband, Channel One, and checks in with a handle and six-character Maidenhead grid square. The grid gives Gravitas a general delivery area without broadcasting a street address.\n\nA legitimate relay repeats the station’s handle and returns a short confirmation code when the request is accepted. The operator should write that code down, remain near the receiver, and keep monitoring the voice channel because Gravitas may request another check-in before dispatching the drone. I have also heard imitation signals on nearby frequencies, so the repeated identifier and confirmation code matter. The real relay does not ask for a full name or exact address.\n\nI want to give the Pennsylvania station every detail I copied, but I need to distinguish what I heard personally from what another operator reported. I’m hopeful this could keep somebody alive, and I’m relieved to finally have useful information instead of another rumor. I should speak slowly when giving the frequencies, ask for them to be repeated back, and ask the other station to tell me whether the identifier matches the one I heard.",
  "emotion": "relieved, careful, technically precise, hopeful, explicit about what remains secondhand"
}
```

Do not summarize, augment, or split either authored intent into extra fields.
The descriptor contains the Story Intent once.

---

## 8. Prompt Templates and Exact Foundation Inputs

### 8.1 Rich Script02 promptVoice template

Add `Turing/Prompts/voicePrompt_richHamReceiver.txt`.

Copy the active production `voicePrompt_characterIntent.txt` structure and
sparse JSON schema. Change only the delivery-specific opening and the fixed
speaker references:

```text
You are Rich. You are talking to CatEye81 over ham radio. You respond and paraphrase the Story intent.

This is your backstory:
{{characterBackstory}}

This is the current story intent. Paraphrase this:
{{storyIntent}}

This is what you just said prior to what you are going to say next:
"""
{{prerecordingTranscript}}
"""
```

Use the existing production promptVoice rules and sparse JSON schema after
that header.

The exact Foundation payload is:

```text
full Rich profile from Turing/Characters/rich.json
exact Rich Script02 Story Intent above, once
exact reviewed transcript of pr-rich-ham-radio-script02.mp3, once
production promptVoice rules
production sparse JSON schema
```

It must not contain:

```text
Script01 CatEye81 intent
Script01 CatEye81 PR
Script01 generated response
conversation history
runtime checkpoint data
room or prop state
conversationKey
scriptPoint IDs
audio route names
```

### 8.2 CatEye81 Script03 promptVoice

Reuse the existing:

```text
Turing/Prompts/voicePrompt_cateye81HamReceiver.txt
```

The exact Foundation payload is:

```text
full cateye81.prologue profile
exact CatEye81 Script03 Story Intent above, once
exact reviewed transcript of pr-cat-eye-81-ham-radio-script03.mp3, once
existing CatEye81 ham promptVoice rules
existing sparse JSON schema
```

It must not include the generated output from Script01 or Script02.

### 8.3 Script03 conversationVoice

Reuse:

```text
Turing/Prompts/conversationPrompt_cateye81HamReceiver.txt
```

After Script03 completes, the exact Foundation conversation input is:

```text
full cateye81.prologue profile
exact CatEye81 Script03 Story Intent
exact reviewed CatEye81 Script03 PR transcript
current player dictation
existing CatEye81 ham conversation rules
existing sparse JSON schema
```

It must not include:

```text
Script01 Story Intent or PR
Rich Script02 Story Intent or PR
any generated promptVoice response
any prior conversationVoice response
dialogue history
summaries or open-thread metadata
```

`TuringFlowEngine` already updates the shared conversation input store per
point. Add a test proving that Script03 overwrites the shared surface key before
the final microphone is exposed.

### 8.4 Fresh Foundation requirement

Every promptVoice and every conversationVoice query must continue through the
stateless Foundation gateway:

```text
one runPrompt call
-> one new LanguageModelSession
-> one response
-> session scope ends
```

Do not retain one Foundation session across Script01, Script02, and Script03.

---

## 9. Sequence-Scoped Ham Audio Ownership

### Current defect

`TuringCatEye81HamReceiverFlowRoute` currently starts and stops
`TuringHamReceiverBedActor` using a point-level `playbackRunID`. With three
automatic points this would stop the ambient bed after Script01, leave it absent
for Rich, and restart it for Script03.

That violates the required continuous ham-radio sound.

### Required owner

`TuringEpisodeFlowController` already owns the full automatic sequence through
`activeSequenceID`. Add a generic sequence lifecycle hook there.

```swift
protocol TuringFlowSequenceLifecycleControlling:
    Sendable
{
    func begin(
        sequenceID: UUID,
        initialDescriptor: TuringFlowDescriptor
    ) async throws

    func pointWillBegin(
        sequenceID: UUID,
        descriptor: TuringFlowDescriptor
    ) async throws

    func pointDidFinish(
        sequenceID: UUID,
        descriptor: TuringFlowDescriptor,
        succeeded: Bool,
        hasAutomaticSuccessor: Bool
    ) async

    func end(
        sequenceID: UUID,
        finalDescriptor: TuringFlowDescriptor?,
        succeeded: Bool,
        reason: String
    ) async
}
```

Provide a no-op default and a surface resolver:

```swift
protocol TuringFlowSequenceLifecycleResolving:
    Sendable
{
    func lifecycle(
        for surface: StoryInteractionSurfaceID
    ) async -> any TuringFlowSequenceLifecycleControlling
}
```

For `.hamReceiver`, return:

```swift
actor TuringHamReceiverSequenceLifecycle:
    TuringFlowSequenceLifecycleControlling
{
    private let bed:
        any TuringHamReceiverBedControlling

    private var activeOwnerID: String?

    func begin(
        sequenceID: UUID,
        initialDescriptor: TuringFlowDescriptor
    ) async throws {
        let ownerID =
            "hamReceiver.sequence.\(sequenceID.uuidString)"

        guard activeOwnerID == nil else {
            throw TuringRuntimeError.invalidConfig(
                "Ham receiver sequence audio already has an owner."
            )
        }

        activeOwnerID = ownerID
        try await bed.beginSession(
            ownerID: ownerID
        )
    }

    func pointWillBegin(
        sequenceID: UUID,
        descriptor: TuringFlowDescriptor
    ) async throws {
    }

    func pointDidFinish(
        sequenceID: UUID,
        descriptor: TuringFlowDescriptor,
        succeeded: Bool,
        hasAutomaticSuccessor: Bool
    ) async {
    }

    func end(
        sequenceID: UUID,
        finalDescriptor: TuringFlowDescriptor?,
        succeeded: Bool,
        reason: String
    ) async {
        guard let ownerID = activeOwnerID else {
            return
        }

        activeOwnerID = nil
        await bed.endSession(
            ownerID: ownerID,
            reason: reason
        )
    }
}
```

The episode controller must call `end` on:

```text
success
point failure
catalog failure after ownership begins
cancellation
explicit reset
immersive teardown
ham receiver removal
```

Call sequence-lifecycle `end` before releasing the
`StoryInteractionArbiter` sequence lease. That prevents an icon from appearing
while the old ambient owner is still alive.

`TuringFlowEngine` may write Script03's `.microphone` gate before control
returns to the episode controller. Do not duplicate or move that gate write.
The still-active sequence lease keeps the microphone presentation hidden. The
observable order is:

```text
engine records microphone gate
-> episode controller ends sequence audio
-> episode controller releases sequence lease
-> arbiter exposes the microphone icon
```

### Route adjustment

Remove `receiverBed.beginSession` and `receiverBed.endSession` from
`TuringCatEye81HamReceiverFlowRoute`.

The CatEye route continues to own only its point-scoped tuning gap:

```text
foundation begins
-> tuning beginGap(point playbackRunID)

Foundation completes
-> tuning endGap(point playbackRunID)

generated exact index missing
-> playback coordinator invokes the same tuning bridge

point finishes or fails
-> tuning endGap(point playbackRunID)
```

The Rich route does not touch the tuning bridge.

---

## 10. Rich Script02 Audio Contract

Use `TuringRichRoomFlowRoute`; do not duplicate it.

Layering:

```text
ham receiver ambient:
  spatial at TuringHamReceiverAudioRoute endpoint
  -15 dB
  continuous for the full three-point sequence

Rich PR:
  existing Rich head-tracked/global endpoint
  current Rich PR gain

Rich filler:
  existing Rich weighted filler catalog
  current random cadence and gain
  same endpoint as Rich

Rich generated promptVoice:
  existing Rich head-tracked/global endpoint
  current Rich generated gain and 0.85 playback rate
```

Do not play:

```text
ham tuning fillers during Rich Script02
walkie ambient static
walkie sending static
walkie open sound
walkie send sound
Rich speech spatially from the ham receiver
```

Rich filler may overlap the spatial ham ambient. It must not overlap Rich PR or
Rich generated speech.

---

## 11. CatEye81 Script01 and Script03 Audio Contract

Layering:

```text
ham receiver ambient:
  spatial
  -15 dB
  remains under tuning, PR, and generated speech

ham tuning loop:
  spatial
  random one of four established files
  transient resource
  one exact active handle
  active only during Foundation wait or an exact generated-index gap

CatEye81 PR:
  spatial at the ham receiver endpoint

CatEye81 generated promptVoice:
  spatial at the same endpoint
```

The ambient bed and tuning loop are separate lanes. Starting or stopping tuning
must never stop the ambient bed.

An out-of-order later generated segment does not stop tuning. Only the exact
next required segment may stop the gap.

---

## 12. Turing Compute and Playback Contract

All three points retain the established pipeline:

```text
fresh Foundation session per request
-> accepted 3-5 second text segments
-> exactly two Fresh Qwen render workers
-> per-segment render state release
-> one serialized speech decoder
-> immediate file-backed decoded WAV publication
-> strict index-ordered playback
-> actual playback completion advances the cursor
```

For Script01 and Script03:

```text
tuning begins
-> Foundation completes
-> tuning stops
-> PR starts
-> Fresh2 starts from the accepted Foundation response
-> decoded segment 0 may publish while PR plays
-> PR actual completion opens generated precedence
-> exact next generated segment plays immediately when available
```

For Script02:

```text
ham ambient continues
-> Foundation begins
-> Rich PR remains withheld
-> Foundation returns successfully
-> Rich PR starts
-> Fresh2 begins from the accepted Foundation response at the same boundary
-> Rich filler bridges from PR completion to exact generated segment 0
-> generated playback starts immediately when exact next index is available
```

Neither new PR may become audible before its point's Foundation response has
returned successfully. A Foundation failure means the corresponding PR never
starts.

There is no:

```text
wait-for-all generated segments
minimum clip runway
minimum decoded-duration runway
duration-estimate completion
batch-level playback barrier
new Fresh scheduler
new decoder coordinator
```

Do not overlap Rich and CatEye81 Qwen runs across point boundaries. The next
point begins only after the prior point's actual ordered playback completion and
its run resources have completed their normal release.

---

## 13. Interaction and Icon Contract

Update `TuringStoryHamReceiverInteractionController.scriptPointID` only if the
canonical Script01 ID changes. Under this handoff it remains:

```text
prologue.hamReceiver.cateye81.001
```

Update its conversation key to:

```text
object.ham_receiver
```

The controller continues to submit final follow-up conversations as:

```swift
TuringFlowConversationRequest(
    conversationRunID: conversationRunID,
    characterID:
        TuringCatEye81VoiceIdentity.characterID,
    outputRoute: .hamReceiverSpatial,
    conversationKey: "object.ham_receiver",
    playerDictation: transcript,
    interactionLease: lease,
    interactionSurface: .hamReceiver
)
```

Presentation:

```text
before play:
  play icon

Script01, Script02, Script03:
  hidden

after Script03 actual completion:
  microphone icon

conversation dictation/Foundation/Qwen/playback:
  hidden

after conversation actual completion:
  microphone icon
```

The icon state remains derived from
`TuringFlowInteractionGateController` and `StoryInteractionArbiter`. Do not add
a second local icon state machine that can disagree with the interaction gate.

---

## 14. Input Store Ordering

The final conversation seed must be deterministic.

At the start of every point, `TuringFlowEngine` writes that point's:

```text
character profile ID
authored Story Intent
reviewed PR transcript
output route
```

to `object.ham_receiver`.

Required order:

```text
Script01 writes CatEye81 Script01 context
Script02 overwrites it with Rich Script02 context
Script03 overwrites it with CatEye81 Script03 context
Script03 promptVoice actual completion
microphone becomes available
conversation reads CatEye81 Script03 context
```

The final microphone must not appear until the Script03 write and actual
playback completion are both true.

---

## 15. Files to Add

```text
Gravitas Plague/Gravitas Plague/Turing/Flow/
  TuringFlowSequenceLifecycle.swift
  TuringHamReceiverSequenceLifecycle.swift

Gravitas Plague/TuringResources/Turing/Audio/prerecordings/
  pr-rich-ham-radio-script02.mp3
  pr-cat-eye-81-ham-radio-script03.mp3

Gravitas Plague/TuringResources/Turing/Prerecordings/
  prologue.room.rich.hamReceiver.002.json
  prologue.room.cateye81.hamReceiver.003.json

Gravitas Plague/TuringResources/Turing/Prompts/
  voicePrompt_richHamReceiver.txt

Gravitas Plague/TuringResources/Turing/ScriptPoints/
  prologue.hamReceiver.rich.002.json
  prologue.hamReceiver.cateye81.003.json

Gravitas Plague/TuringResources/Turing/VoicePrompts/
  prologue.rich.hamReceiver.followUp.002.json
  prologue.cateye81.hamReceiver.followUp.003.json

Gravitas Plague/Gravitas PlagueTests/
  TuringHamReceiverThreePointFlowResourceTests.swift
  TuringHamReceiverSequenceLifecycleTests.swift
  TuringHamReceiverThreePointPromptTests.swift
```

---

## 16. Files to Modify

```text
Gravitas Plague/Gravitas Plague/Turing/Flow/
  TuringEpisodeFlowController.swift
  TuringCatEye81HamReceiverFlowRoute.swift

Gravitas Plague/Gravitas Plague/Turing/Interaction/
  TuringStoryHamReceiverInteractionController.swift

Gravitas Plague/TuringResources/Turing/ScriptPoints/
  catalog.json
  prologue.hamReceiver.cateye81.001.json

Gravitas Plague/TuringResources/Turing/VoicePrompts/
  prologue.cateye81.hamReceiver.followUp.001.json
```

Do not change:

```text
Qwen sampling configuration
Fresh2 scheduler
speech decoder
Rich clone artifacts
CatEye81 clone artifacts
Rich playback rate
Rich gains
CatEye81 gains
ham ambient gain
ham tuning gain
room placement
rolling-bench geometry
walkie ScriptPoints
crank-radio ScriptPoints
Dad-photo flow
```

---

## 17. Catalog and Resource Validation

Extend validation to prove:

```text
all three descriptors exist
Script01 -> Script02 -> Script03 edge order is exact
both edges are automatic
Script02 and Script03 triggers are priorScriptPointCompleted
all three conversation keys equal object.ham_receiver
all three interaction surfaces equal hamReceiver
Script01 character and route are cateye81/hamReceiverSpatial
Script02 character and route are rich/roomGlobal
Script03 character and route are cateye81/hamReceiverSpatial
Script01 and Script02 completion gates resolve closed
Script03 completion gate is microphone
each PR speaker, voice, and prompt identity match its point
both new PR files match expected SHA-256
both reviewed transcripts are nonempty
neither transcript contains REVIEWED_VERBATIM_TRANSCRIPT_REQUIRED
```

Do not weaken the catalog validator to permit malformed identities.

---

## 18. Required Logs

Sequence:

```text
[TuringHamSequence] began
  sequenceID
  ownerID
  initialScriptPointID
  ambientResource

[TuringHamSequence] point began
  sequenceID
  scriptPointID
  characterID
  outputRoute
  ambientOwnerUnchanged

[TuringHamSequence] point completed
  sequenceID
  scriptPointID
  actualPlaybackCompleted
  automaticSuccessor
  interactionGate

[TuringHamSequence] ended
  sequenceID
  finalScriptPointID
  succeeded
  reason
  ambientReleased
```

Prompt:

```text
[TuringFoundationPrompt] BEGIN
  scriptPointID
  voicePromptID
  characterProfileID
  outputContext
  conversationKey
  exact rendered prompt
[TuringFoundationPrompt] END
```

Conversation:

```text
[TuringConversationInput] resolved
  characterID: cateye81
  conversationKey: object.ham_receiver
  profileID: cateye81.prologue
  promptContextSHA256
  prerecordingTranscriptSHA256
  dialogueHistoryIncluded: false
```

Audio:

```text
ambient owner began/ended
tuning owner began/ended
PR actual started/completed
generated segment published/started/completed
Rich filler started/completed
```

Logs must prove the ambient owner ID is unchanged across all three points.

---

## 19. Unit and Integration Tests

Add deterministic tests:

```text
testHamCatalogContainsThreePointSequenceInOrder
testScript01AutomaticallyAdvancesToRichScript02
testRichScript02AutomaticallyAdvancesToCatEyeScript03
testOnlyScript03ReturnsMicrophone
testOneInteractionLeaseSpansAllThreePoints
testNoIntermediateHamIconPresentation

testHamAmbientBeginsOnceForThreePointSequence
testHamAmbientDoesNotStopBetweenScript01AndScript02
testHamAmbientDoesNotStopBetweenScript02AndScript03
testHamAmbientStopsAfterScript03ActualCompletion
testFailureStopsExactAmbientAndTuningOwners

testRichScript02UsesRoomGlobalRoute
testRichScript02UsesExistingRichFillerCatalog
testRichScript02DoesNotUseHamTuningGapBridge
testRichScript02DoesNotUseWalkieCommEffects
testRichScript02PRIsWithheldUntilFoundationReturns

testCatEyeScript01UsesHamTuningGapBridge
testCatEyeScript03UsesHamTuningGapBridge
testCatEyeScript03PRIsWithheldUntilFoundationReturns
testCatEyePRAndGeneratedSpeechUseSameSpatialEndpoint
testAmbientRemainsIndependentFromTuningLane

testScript02PromptContainsFullRichProfile
testScript02PromptContainsExactIntentOnce
testScript02PromptContainsReviewedPRTranscriptOnce
testScript02PromptContainsNoScript01GeneratedSpeech

testScript03PromptContainsFullCatEyePrologueProfile
testScript03PromptContainsExactIntentOnce
testScript03PromptContainsReviewedPRTranscriptOnce
testScript03PromptContainsNoRichContext

testFinalConversationUsesScript03StoryIntent
testFinalConversationUsesScript03PRTranscript
testFinalConversationDoesNotUseScript01Context
testFinalConversationDoesNotUseScript02Context
testFinalConversationContainsNoDialogueHistory

testNewPRResourcesMatchApprovedHashes
testNewPRDescriptorsRejectTranscriptPlaceholder
testFreshFoundationSessionPerPointAndConversation
testGeneratedPlaybackAdvancesOnlyFromActualCompletion
```

Use event barriers and exact fake completion callbacks. Do not use arbitrary
sleeps to prove ordering.

---

## 20. Vision Pro Acceptance

Run from a fresh Story session:

1. Place the rolling bench and ham receiver.
2. Confirm one play icon above the ham receiver.
3. Press play once.
4. Confirm the icon disappears synchronously.
5. Confirm ham ambient begins spatially at the receiver.
6. Confirm tuning plays while Script01 Foundation is pending.
7. Confirm Script01 PR is withheld until Foundation succeeds.
8. Confirm tuning stops before Script01 PR.
9. Confirm CatEye81 Script01 PR is spatial at the receiver.
10. Confirm CatEye81 TTS computes while the PR plays.
11. Confirm tuning bridges any missing exact generated segment.
12. Confirm Script01 generated playback completes without an icon flash.
13. Confirm Rich Script02 starts automatically.
14. Confirm the same ham ambient continues without a restart.
15. Confirm Rich Script02 PR remains silent while Foundation is pending.
16. Confirm Rich PR starts only after Foundation returns successfully.
17. Confirm Rich PR and TTS are global/head-tracked, not emitted by the cart.
18. Confirm Rich weighted filler is used.
19. Confirm no ham tuning filler plays during Rich Script02.
20. Confirm no walkie open/send sound plays.
21. Confirm Script02 completes without an icon flash.
22. Confirm CatEye81 Script03 starts automatically.
23. Confirm the same ambient session continues.
24. Confirm tuning plays while Script03 Foundation is pending.
25. Confirm Script03 PR is withheld until Foundation succeeds.
26. Confirm Script03 PR and TTS are spatial at the receiver.
27. Confirm frequencies are spoken clearly and preserve authored values.
28. Confirm the final CatEye81 generated segment completes fully.
29. Confirm tuning and ambient stop cleanly.
30. Confirm one microphone icon appears above the ham receiver.
31. Ask a follow-up about the identifier or confirmation code.
32. Confirm conversation input uses Script03 context and PR.
33. Confirm tuning and ambient begin during follow-up preparation.
34. Confirm tuning stops when exact segment zero is ready.
35. Confirm CatEye81 answer plays spatially.
36. Confirm the microphone returns after actual completion.
37. Remove the rolling bench during an active test and confirm every owner,
    Task, endpoint handle, and interaction lease releases.

Repeat with an injected Foundation failure at each point and an injected Qwen
failure at each point. Each failure must restore play and leave no audio owner.

---

## 21. Static Rejection Checks

Reject the implementation if any of these are present:

```text
Script01 automaticAdvance false
Script02 trigger priorConversationPlaybackCompleted
Script02 outputRoute walkieOutgoingGlobal
Script02 walkie open/send effects enabled
Script03 final gate other than microphone
different conversation keys across the chain
ambient endSession in CatEye point-level route finish
Rich ham tuning filler
CatEye Rich filler
conversation history in a prompt
generated promptVoice text saved as conversation history
Foundation session retained across requests
wait-for-all generated playback gate
transcript placeholder in production resources
```

Suggested checks:

```bash
grep -RIn \
  'prologue.hamReceiver.rich.002\\|prologue.hamReceiver.cateye81.003' \
  "Gravitas Plague/TuringResources/Turing"

! grep -RIn \
  'REVIEWED_VERBATIM_TRANSCRIPT_REQUIRED' \
  "Gravitas Plague/TuringResources/Turing/Prerecordings"

! grep -n \
  'receiverBed.endSession' \
  "Gravitas Plague/Gravitas Plague/Turing/Flow/TuringCatEye81HamReceiverFlowRoute.swift"
```

---

## 22. Completion Report

Codex must return:

```text
files added
files modified
installed PR SHA-256 values
reviewed Script02 PR transcript
reviewed Script03 PR transcript
exact rendered Script02 promptVoice input
exact rendered Script03 promptVoice input
exact rendered post-Script03 conversationVoice input from a controlled test
proof one interaction lease spans all three points
proof one ambient owner spans all three points
proof Rich uses roomGlobal plus existing Rich filler
proof CatEye81 uses hamReceiverSpatial plus tuning filler
proof no intermediate icon appears
proof final microphone appears only after Script03 actual completion
unit and integration test results
Vision Pro result
remaining failure boundary, if any
```

Do not report device completion based only on compilation or mocked playback.
