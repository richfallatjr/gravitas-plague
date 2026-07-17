# Turing Prologue ScriptPoint04/05 Architect Handoff

Status: implementation handoff. This is for extending the existing Turing Flow, not replacing it. Preserve the current ScriptPoint01/02/03 engine path, descriptor schema, playback coordinator behavior, prompt rendering path, and continuation architecture unless a scoped change below explicitly requires an extension.

## Goal

Add the next two authored prologue script points:

- `prologue.scriptPoint04`: Rich speaks through a prerecording plus generated Turing prompt voice TTS. After playback completes, the walkie opens for the player's conversation voice.
- `prologue.scriptPoint05`: Big Mike responds after that conversation completes. Its generated TTS must use the Script Voice audiobook/longform flow, with static/filler bridging available while generation catches up.

Keep the same user-facing "headline" opening used in the early canary work:

```text
Rich you gotta hear this shit.
```

## Current State To Respect

Existing flow resources:

- `Gravitas Plague/TuringResources/Turing/ScriptPoints/catalog.json`
- `Gravitas Plague/TuringResources/Turing/ScriptPoints/prologue.scriptPoint01.json`
- `Gravitas Plague/TuringResources/Turing/ScriptPoints/prologue.scriptPoint02.json`
- `Gravitas Plague/TuringResources/Turing/ScriptPoints/prologue.scriptPoint03.json`
- `Gravitas Plague/TuringResources/Turing/Prerecordings/*.json`
- `Gravitas Plague/TuringResources/Turing/VoicePrompts/*.json`

Existing flow behavior:

- ScriptPoint01:
  - Big Mike PR + prompt voice.
  - `nextScriptPointID = prologue.scriptPoint02`
  - `automaticAdvance = false`
  - Opens microphone after completion.
  - ScriptPoint02 starts only after actual conversation playback completes.
- ScriptPoint02:
  - Rich PR + prompt voice.
  - Auto-advances to ScriptPoint03.
- ScriptPoint03:
  - Big Mike PR + prompt voice.
  - Currently terminal and opens microphone.
  - Currently triggers Battle01 through `TuringPrologueCompletionCoordinator` / `PrologueStoryActionRouter`.

Important production classes:

- `TuringEpisodeFlowController`
- `TuringFlowDescriptor`
- `TuringFlowCatalogValidator`
- `TuringFlowEngine`
- `TuringStoryWalkiePlaybackCoordinator`
- `TuringFlowRouteRuntime`
- `TuringPrologueCompletionCoordinator`
- `TuringEpisodeContinuationSnapshot`
- `TuringStoryDestinationPlanner`
- `TuringVoiceScriptLongformRunner`
- `TuringPhase1AudiobookRunner`

## Narrative Authoring

### ScriptPoint04 Rich

Prerecording headline:

```text
Rich you gotta hear this shit.
```

Prompt voice / generated TTS source:

```text
I can't believe this thing is laying in my room. It's not a person anymore it's a monster. I am still freaking out. We need the police. But police services have been down for weeks. I need to get this thing out of here.
```

Implementation intent:

- Rich has just encountered the aftermath in his room.
- He is panicked, immediate, and still trying to reason through it.
- The generated prompt voice must not repeat the headline verbatim unless needed for continuity.
- After the full Rich transmission finishes, open the walkie conversation voice/microphone.

### ScriptPoint05 Big Mike

Prompt voice / generated TTS source:

```text
I'm trying to support Rich but he may have messed up. You can't just neutralize anything you please. I'll just let him know he did what he had to do. Drag that thing out into the woods. I read this article to change the subject but nobody's buying that.
```

Implementation intent:

- Big Mike is supportive but knows Rich crossed a line.
- He rationalizes the act aloud without sounding fully convinced.
- He tells Rich to drag the body/thing into the woods.
- The "article" beat is an awkward subject-change attempt.
- Nobody buys the subject change.

## Required Flow Shape

The requested setup is "same setup as before with a twist":

1. ScriptPoint04 should mirror ScriptPoint01's conversational gate pattern.
2. ScriptPoint04 should be Rich-owned, not Big Mike-owned.
3. ScriptPoint04 should use a PR headline, then generated Turing prompt voice TTS.
4. ScriptPoint04 should open for conversation voice after playback completes.
5. ScriptPoint05 should trigger after actual conversation playback completion from ScriptPoint04.
6. ScriptPoint05 should use Big Mike's Script Voice audiobook/longform flow for generated speech rather than only the short prompt voice path.
7. Big Mike static/filler must bridge dead air during ScriptPoint05 longform generation.

Architectural decision required before wiring production triggers:

- Decide whether ScriptPoint04/05 are post-Battle01 points, or whether ScriptPoint03 should no longer be terminal/Battle01-starting.
- Today ScriptPoint03 completion commits `.script03PromptVoiceCompleted` and routes Battle01. Do not silently add 04/05 after 03 without deciding how Battle01 and door state should interact.

Recommended production sequence if this is the continuation after ScriptPoint03/Battle01:

```text
01 PR+prompt -> mic -> conversation -> 02 PR+prompt -> 03 PR+prompt -> Battle01/door beat -> 04 Rich PR+prompt -> mic -> conversation -> 05 Big Mike script-voice/audiobook
```

Recommended sequence if this replaces the current ScriptPoint03 terminal:

```text
01 PR+prompt -> mic -> conversation -> 02 PR+prompt -> 03 PR+prompt -> 04 Rich PR+prompt -> mic -> conversation -> 05 Big Mike script-voice/audiobook -> Battle01/next beat
```

Do not make this choice implicitly inside the resource files. The story gate owner should be explicit.

## Proposed Resource IDs

Script points:

- `prologue.scriptPoint04`
- `prologue.scriptPoint05`

Prerecording:

- `prologue.walkie.rich.scriptPoint04.001`

Voice prompts:

- `prologue.rich.scriptPoint04.followUp.001`
- `prologue.bigMike.scriptPoint05.followUp.001`

Audio assets:

- `Gravitas Plague/TuringResources/Turing/Audio/prerecordings/pr-rich-script-point-04.mp3`

If ScriptPoint05 has no PR and is generated-only, do not fake a prerecording. Either extend the descriptor model to support generated-only points, or add an explicit static/lead-in descriptor type. If a temporary PR is required to preserve schema 2, create a deliberate static-only PR descriptor and name it as such, for example:

- `prologue.walkie.bigMike.scriptPoint05.staticLeadIn.001`
- `pr-big-mike-script-point-05-static-leadin.mp3`

Do not point ScriptPoint05 at an unrelated old PR just to satisfy validation.

## Descriptor Examples

### ScriptPoint04 Descriptor

```json
{
  "schemaVersion": 2,
  "scriptPointID": "prologue.scriptPoint04",
  "trigger": {
    "kind": "priorScriptPointCompleted",
    "delaySeconds": 0
  },
  "transmission": {
    "prerecordingID": "prologue.walkie.rich.scriptPoint04.001",
    "voicePromptID": "prologue.rich.scriptPoint04.followUp.001",
    "characterID": "rich",
    "conversationKey": "dialogue.big_mike.rich",
    "outputRoute": "walkieOutgoingGlobal",
    "computeStart": "withPrerecording",
    "fillerMode": "continuousFromPrerecordingToGenerated",
    "commSFX": {
      "openBeforePrerecording": true,
      "sendAfterGenerated": true,
      "sendingLeadInAfterGeneratedSeconds": null
    },
    "fixedLeadInSeconds": null
  },
  "progression": {
    "nextScriptPointID": "prologue.scriptPoint05",
    "automaticAdvance": false,
    "interactionGateAfterCompletion": "microphone"
  }
}
```

If ScriptPoint04 is manually started after Battle01 rather than automatically started after ScriptPoint03, use `trigger.kind = "userPlay"` or introduce a specific story trigger rather than overloading `priorScriptPointCompleted`.

### ScriptPoint05 Descriptor

Short-prompt-compatible fallback:

```json
{
  "schemaVersion": 2,
  "scriptPointID": "prologue.scriptPoint05",
  "trigger": {
    "kind": "priorConversationPlaybackCompleted",
    "delaySeconds": 2
  },
  "transmission": {
    "prerecordingID": "prologue.walkie.bigMike.scriptPoint05.staticLeadIn.001",
    "voicePromptID": "prologue.bigMike.scriptPoint05.followUp.001",
    "characterID": "big_mike",
    "conversationKey": "dialogue.big_mike.rich",
    "outputRoute": "walkieSpatial",
    "computeStart": "beforePrerecording",
    "fillerMode": "continuousFromPrerecordingToGenerated",
    "commSFX": {
      "openBeforePrerecording": false,
      "sendAfterGenerated": false,
      "sendingLeadInAfterGeneratedSeconds": null
    },
    "fixedLeadInSeconds": null
  },
  "progression": {
    "nextScriptPointID": null,
    "automaticAdvance": false,
    "interactionGateAfterCompletion": "microphone"
  }
}
```

Preferred if implementing true Script Voice longform:

- Extend `TuringFlowDescriptor.Transmission` with an explicit generation mode, for example `generationMode: "voicePrompt"` vs `generationMode: "voiceScriptLongform"`.
- Keep current resources defaulting to `voicePrompt` to preserve 01/02/03 behavior.
- For `voiceScriptLongform`, route the prompt/source transcript through `TuringVoiceScriptLongformRunner` / `TuringPhase1AudiobookRunner`, then render those accepted segments through the existing Qwen segment playback path.
- Preserve `TuringStoryWalkiePlaybackCoordinator` ownership for PR, filler, generated segment ordering, dead air, and completion.

## Prerecording Descriptor For ScriptPoint04

```json
{
  "schemaVersion": 1,
  "prerecordingID": "prologue.walkie.rich.scriptPoint04.001",
  "speaker": "rich",
  "voiceID": "rich_base_clone_v1",
  "voiceVariantID": "rich_reference_01",
  "audioFile": "pr-rich-script-point-04.mp3",
  "transcriptMode": "manual",
  "transcript": "Rich you gotta hear this shit.",
  "summary": "Rich urgently gets Big Mike's attention before describing the thing in his room.",
  "voicePromptIntent": "You urgently need Big Mike to listen. You are shaken and about to explain that the thing in your room is no longer a person.",
  "defaultEmotion": "panicked, breathless, horrified"
}
```

## Voice Prompt Descriptors

### ScriptPoint04 Rich

```json
{
  "schemaVersion": 1,
  "voicePromptID": "prologue.rich.scriptPoint04.followUp.001",
  "speakerID": "rich",
  "voiceID": "rich_base_clone_v1",
  "characterProfileID": "rich",
  "outputContext": "walkieOutgoingGlobal",
  "conversationKey": "dialogue.big_mike.rich",
  "intent": "Continue after the authored headline without repeating it. You are Rich, panicked and horrified because the thing in your room is not a person anymore. Say: I can't believe this thing is laying in my room. It's not a person anymore it's a monster. I am still freaking out. We need the police. But police services have been down for weeks. I need to get this thing out of here.",
  "emotion": "panicked, breathless, horrified"
}
```

### ScriptPoint05 Big Mike

For short-prompt fallback:

```json
{
  "schemaVersion": 1,
  "voicePromptID": "prologue.bigMike.scriptPoint05.followUp.001",
  "speakerID": "big_mike",
  "voiceID": "big_mike_base_clone_v1",
  "characterProfileID": "big_mike",
  "outputContext": "walkieSpatial",
  "conversationKey": "dialogue.big_mike.rich",
  "intent": "You are Big Mike. You are trying to support Rich, but you know he may have messed up. Say: I'm trying to support Rich but he may have messed up. You can't just neutralize anything you please. I'll just let him know he did what he had to do. Drag that thing out into the woods. I read this article to change the subject but nobody's buying that.",
  "emotion": "controlled, uneasy, protective, trying to sound casual"
}
```

For true Script Voice audiobook mode, store the same source text in a script-voice source resource instead of forcing it through `intent`, for example:

- `Gravitas Plague/TuringResources/Turing/Scripts/Prologue/prologue.scriptPoint05.bigMike.voiceScript.txt`

```text
I'm trying to support Rich but he may have messed up. You can't just neutralize anything you please. I'll just let him know he did what he had to do. Drag that thing out into the woods. I read this article to change the subject but nobody's buying that.
```

Then pass that text as `TuringLongformVoiceScriptRequest.sourceText` with:

- `requestID = "prologue.scriptPoint05.bigMike.voiceScript.001"`
- `speakerID = "big_mike"`
- `voiceID = "big_mike_base_clone_v1"`
- `defaultEmotion = "controlled, uneasy, protective, trying to sound casual"`
- `playbackTarget = walkieSpatial`

## Static/Filler Requirement For Big Mike Script Voice

ScriptPoint05 can take longer than short prompt voice because Script Voice audiobook segmentation and Qwen rendering are multi-segment. Use static/filler bridging so the player hears radio presence while Big Mike's generated response is prepared.

Implementation requirements:

- Reuse `TuringStoryWalkiePlaybackCoordinator` filler/dead-air behavior where possible.
- Big Mike filler directory candidates already include:
  - `Turing/Audio/big-mike-filler`
  - `Turing/big-mike-filler`
  - `big-mike-filler`
- For ScriptPoint05, Big Mike should use `walkieSpatial` route and Big Mike output processing.
- If there is no PR, the bridge should be static/filler-first, not silence-first.
- If a static lead-in PR is used, it must be intentionally authored static and clearly named.
- Do not generate Big Mike's filler clips dynamically at runtime. Use the existing bundled static/filler clips.

## Flow/Continuation Changes

Extend `TuringPrologueCheckpoint`:

```swift
case script04PromptVoiceCompleted = 50
case script04ConversationVoiceCompleted = 60
case script05PromptVoiceCompleted = 70
```

Update `TuringPrologueCompletionCoordinator`:

- Commit `.script04PromptVoiceCompleted` on `prologue.scriptPoint04` completion.
- Commit `.script05PromptVoiceCompleted` on `prologue.scriptPoint05` completion.
- Commit `.script04ConversationVoiceCompleted` when `TuringConversationPlaybackCompletionEvent.parentScriptPointID == "prologue.scriptPoint04"`.
- Keep the ScriptPoint01 conversation completion behavior intact.
- Do not route Battle01 from ScriptPoint04/05 unless the story decision explicitly moves Battle01.

Update `TuringEpisodeFlowController.startFromContinuation`:

- Allow `.script03PromptVoiceCompleted -> prologue.scriptPoint04` if 04 starts from prior point completion/continuation.
- Allow `.script04ConversationVoiceCompleted -> prologue.scriptPoint05`.
- If 04 is manually gated after Battle01, use a specific destination/play action rather than pretending ScriptPoint03 just completed.

Update `TuringStoryDestinationPlanner`:

- For `.script04PromptVoiceCompleted`, completed IDs include 01, 02, 03, 04, and pending conversation advance points from 04 to 05; walkie action is `.microphone`.
- For `.script04ConversationVoiceCompleted`, completed IDs include 01, 02, 03, 04; walkie action plays `prologue.scriptPoint05` with continuation restore.
- For `.script05PromptVoiceCompleted`, completed IDs include 01 through 05; choose the next story state explicitly.

Update `TuringFlowTriggerSource.kind`:

- Extend `.continuationRestore` mapping for the new checkpoints.
- ScriptPoint05 restore after `.script04ConversationVoiceCompleted` maps to `.priorConversationPlaybackCompleted`.
- ScriptPoint04 restore after `.script03PromptVoiceCompleted`, if used, maps to either `.priorScriptPointCompleted` or a new explicit story trigger.

## Catalog/Validation Changes

Update:

- `Gravitas Plague/TuringResources/Turing/ScriptPoints/catalog.json`

Include:

```json
"prologue.scriptPoint04",
"prologue.scriptPoint05"
```

Ensure `TuringFlowCatalogValidator` still proves:

- descriptor exists
- prerecording descriptor exists or generated-only mode is explicitly supported
- audio URL exists for real PR/static lead-in assets
- voice prompt or voice script source exists
- character identity matches descriptor, prerecording, prompt/source, and output route
- progression edge preserves `conversationKey`
- non-auto edge to `priorConversationPlaybackCompleted` is accepted for 04 -> 05

If adding `generationMode`, validator must reject impossible combinations:

- `voicePrompt` without `voicePromptID`
- `voiceScriptLongform` without a voice script source
- generated-only descriptor with `fillerMode = none` if no PR/static bridge exists and generation is expected to be slow

## Tests To Add Or Update

Update existing tests:

- `TuringFlowResourceParityTests`
- `TuringFlowDescriptorAndRegistryTests`
- `TuringFlowEngineParityTests`
- `TuringEpisodeFlowReplayTests`
- `TuringStoryEpisodeContinuationTests`
- `TuringFlowInteractionGateControllerTests`
- `TuringStoryWalkiePresentationTests`

Required assertions:

- Catalog loads 01 through 05.
- 04 descriptor points to Rich PR, Rich prompt, Rich character, and `walkieOutgoingGlobal`.
- 04 completion opens microphone and creates pending conversation advance to 05.
- 05 starts only after conversation playback completion for `dialogue.big_mike.rich`.
- A conversation completion for the wrong conversation key is ignored.
- Continuation from `.script04PromptVoiceCompleted` restores a microphone gate and pending 04 -> 05 advance.
- Continuation from `.script04ConversationVoiceCompleted` arms 05 from the same play affordance.
- 05 uses Big Mike filler/static bridge while longform segments are pending.
- 05 longform mode renders accepted audiobook segments into the same generated playback ordering contract as current prompt voice segments.
- Existing 01/02/03 behavior is unchanged unless the explicit story decision moves Battle01.

Add a focused longform test if implementing true Script Voice mode:

- Given ScriptPoint05 source text, `TuringVoiceScriptLongformRunner` produces accepted segments.
- Those segments are converted to `TuringSpeechSegment` or the playback segment type used by `TuringFlowEngine`.
- Playback coordinator receives filler before generated segment zero when segment zero is late.
- Completion fires only after all generated segments finish playback, not when Foundation segmentation returns.

## Non-Goals

- Do not rewrite Turing Flow.
- Do not remove existing PR + prompt voice behavior for ScriptPoint01/02/03.
- Do not make ScriptPoint05 depend on accumulated dialogue history. The current prompt design intentionally uses fresh Foundation sessions and authored context.
- Do not silently reuse unrelated prerecording audio for ScriptPoint05.
- Do not bypass catalog validation to get 04/05 running.
- Do not start Battle01 from the new points unless the story gate decision explicitly moves that trigger.

## Acceptance Criteria

The implementation is done when:

- New resources for ScriptPoint04 and ScriptPoint05 are present and catalog-valid.
- ScriptPoint04 plays Rich's authored headline PR, bridges into Rich generated TTS, then opens conversation voice.
- Player conversation completion after ScriptPoint04 triggers ScriptPoint05.
- ScriptPoint05 uses Big Mike voice with the Script Voice audiobook/longform path or a deliberately documented compatibility fallback.
- Big Mike static/filler bridges generation latency.
- Continuation/resume handles checkpoints through ScriptPoint05.
- Tests cover resource validation, flow progression, continuation, and filler/longform playback ordering.
