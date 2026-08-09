# Gravitas Plague - Chapter 02: The Night the Lights Went Out

## Complete Architect Implementation Handoff

Repository: `/Users/richardfallat/Projects/dev/gravitas-plague`

Status: implementation specification. This document does not claim a device pass.

## 1. Canonical chapter identity

The supplied story document is titled `Chapter 2 - The Night the Lights Went Out`.
The user also called it "chapter 3" once because it is the third selectable Story
entry after Prologue and Chapter 1. Do not encode that menu position as the
chapter number.

Use these production identities:

```text
episodeID:          chapter02
catalog title:      Chapter 2
title-card title:   Chapter 2
subtitle:           The Night the Lights Went Out
content revision:   chapter02.v1
progress key:       story.chapter02.progress.v1
```

Add `.chapter02` to `TuringEpisodeID`. It is the third catalog row, after
`.prologue` and `.chapter01`.

Do not rename Chapter 1, reuse Chapter 1 checkpoints, or store Chapter 2 state in
`Chapter01ProgressStore`.

## 2. Existing production systems to reuse

Use the existing room and the existing production speech path. Do not create a
second room scan, a second TTS scheduler, a second ordered playback queue, or a
Chapter-specific Foundation service.

Required reuse:

```text
TuringStoryStageCoordinator
TuringStoryStateTeleportCoordinator
StoryInteractionArbiter
TuringEpisodeFlowController
TuringFlowEngine
TuringPromptVoiceStageExecutor
TuringCharacterQwenRenderSession
TuringQwenNativeFreshInstanceScheduler
TuringQwenNativeSpeechDecodeCoordinator
TuringStoryAudioPlaybackActor
TuringStorySurfaceFlowBinding
TuringStoryWalkieInteractionController
TuringStoryHamReceiverInteractionController
TuringStoryCrankRadioInteractionController
TuringStoryDadFrameInteractionController
TuringStoryWindowBundleController
Chapter01DadWindowRouteSnapshot
ScriptedAnchorPathFollower
JockRuntimeDriver
Battle01 portal source/mirror handoff
BattleEnemyRuntimeRegistry
BattleRuntimeCleanupCoordinator
StoryTitleCardTransitionCoordinator
Chapter02WomanRuntimeLease
```

Chapter 1 must remain independently playable and its behavior must not change.
If reusable window-character or scripted-battle abstractions are extracted from
Chapter 1, keep Chapter 1 behind an adapter and prove byte-for-byte descriptor
and behavior parity with its current tests.

## 3. Verified visual and animation assets

The young woman is the existing Story/Horde character:

```text
characterID:        spouse
archetype:          spouse
asset:              spouse_biped.usdz
size on disk:       approximately 54 MiB
forward axis:       -Z
up axis:            Y
pose policy:        sourceRestDeltaToTargetRest
character config:   Gravitas Plague/Gravitas Plague/CharacterLibrary/Characters/spouse.character.json
```

The current asset/config already supplies the pale-yellow-clothed young woman.
Do not add a second copy of `spouse_biped.usdz` and do not hard-code material
replacement unless the authored asset is later changed.

Verified clips in the current animation manifest:

```text
idle_01               14.125000 seconds, authored looping clip
charged-slash-left     2.791667 seconds, non-looping
charged-slash-right    2.791667 seconds, non-looping
left_hook_01           1.250000 seconds, non-looping
right_hook_01          1.250000 seconds, non-looping
unstable_walk_01       3.708333 seconds, authored looping locomotion clip
turn_left_90           1.375000 seconds, non-looping
turn_right_90          1.375000 seconds, non-looping
```

Manifest:

```text
Gravitas Plague/Gravitas Plague/AnimationLibrary/Manifests/animation_library_manifest.json
```

The spouse character config and `HordeAttackAnimationCatalogue.allAttackClipIDs`
define all four current attack clips in this order:

```text
charged-slash-left
charged-slash-right
left_hook_01
right_hook_01
```

The window presentation must use all four, not only the hook pair. While she is
outside the window, every attack is visual presentation only: no collision
authority, hit detector, attack window, player damage, attack audio, or combat
score is active.

The exact window loop is:

```text
idle_01 loops continuously for an exact 20-second centered dwell
-> charged-slash-left to actual completion
-> charged-slash-right to actual completion
-> left_hook_01 to actual completion
-> right_hook_01 to actual completion
-> return immediately to the 20-second idle dwell
-> repeat for as long as the early Chapter 2 device sequence remains active
```

The 20 seconds is the same authored centered hold used by
`Chapter01DadWindowCoordinator.centeredIdleDurationSeconds`; it is not the clip's
duration. `idle_01` is 14.125 seconds and therefore loops as needed to cover the
full hold. Each non-looping attack advances only from `JockRuntimeDriver`'s exact
clip-completion callback. A generation token owns the sequence so cancellation or
an exit request cannot let stale completions restart it.

### 3.1 Audited Chapter 2 audio now present

The following authored files currently exist at the repository root. Install each
file byte-for-byte into the Chapter 2 prerecording/audio resource tree and bind it
to the point shown below. Do not synthesize a replacement, reinterpret a jingle or
bumper as dialogue, or silently bind an older Prologue/Chapter 1 PR.

```text
source file                                           duration      runtime role
pr-broadcast-missing-persons.mp3                      49.611 s      Crank Radio 01 PR
pr-dad-electricity-went-out.mp3                       31.713 s      Ham Dad 01 PR
pr-rich-ham-receiver-dad.mp3                          25.104 s      Ham Rich 02 PR
pr-dad-ham-receiver-do-not-come-looking.mp3           32.444 s      Ham Dad 03 PR
pr-big-mike-nukes.mp3                                 27.402 s      Walkie Big Mike 01 PR
pr-rich-walkie-obey.mp3                               26.514 s      Walkie Rich 02 PR
pr-big-mike-payback-for-dad.mp3                       28.552 s      Walkie Big Mike 03 PR
pr-rich-dad-photo-dad-disappeared.mp3                 39.732 s      Dad Photo PR
pr-broadcast-night-lights-went-out.mp3                41.874 s      Crank Radio 02 PR
pr-rich-women-window.mp3                              31.688 s      window-recognition PR-only cue
pr-rich-women-battle.mp3                              26.659 s      woman-battle PR-only cue
pr-rich-ham-receiever-what-do-you-believe.mp3         36.389 s      post-battle Ham Rich PR
pr-cat-eye-81-what-we-chose.mp3                       53.499 s      post-battle Ham CatEye81 PR
pr-broadcast-psa-propoganda.mp3                       56.268 s      final Gravitas PSA PR
gravitas-opening-jingle.mp3                           30.041 s      final broadcast opening cue
gravitas-closing-bumper.mp3                           12.000 s      final broadcast closing cue
```

The misspellings in `pr-rich-ham-receiever-what-do-you-believe.mp3` and
`pr-broadcast-psa-propoganda.mp3` are the current authored source filenames. They
may be copied to correctly spelled bundle filenames, but the source bytes must
remain unchanged and each descriptor must use its installed name.

Audited SHA-256 values:

```text
539b43c5245ee0e3da17f125d1f50a3a41103f42cb89180e84b517a703e7c8af  gravitas-opening-jingle.mp3
83649c3a201283173580e050ccc25af14f61c1340df5e665d24a3c7a9b2093c9  gravitas-closing-bumper.mp3
cecfcc61142bbe11e5c842607e22f9b9ef3a111f94047f6610163186f597286e  pr-big-mike-nukes.mp3
27f5124c2eb34944d4f1885edbb5ce0a150a038cc201d9674e9c560917287b4b  pr-big-mike-payback-for-dad.mp3
cdafad312e57dac890327d8f3b1bfcf7b237503c5784a47a992a85efc9b245ff  pr-broadcast-missing-persons.mp3
e5b63f267faea8fbc2321f079c20984832979a0d937d21f6db581140d46701fd  pr-broadcast-night-lights-went-out.mp3
38f9fa4cddb0a725df322eff4785385f0fc4b2fb289879f26ebdf8fb60c730d7  pr-cat-eye-81-what-we-chose.mp3
550ab0f608e5c34a4b660cd4687640c1b6bc28aeb7c3bbaec3d41703d3a7e9b2  pr-broadcast-psa-propoganda.mp3
0fbdc3ddcc99e60232ae0b3200a1785d796df2eebbff843be2eca79bc6cc2cd7  pr-dad-electricity-went-out.mp3
43d7f1e2b3bf3c615352d8e54b6e77059b9f6210903bf12c327069ab8534ceeb  pr-dad-ham-receiver-do-not-come-looking.mp3
3f6182bf53802eca2aca23258a3f74a8eba63fb753fff4ded8f92fcc23dfe701  pr-rich-dad-photo-dad-disappeared.mp3
9bcd5ac1af18954868db7e39de4ce0fb6dab6befe590aba367fd79525db746bd  pr-rich-ham-receiever-what-do-you-believe.mp3
d9970a93d54ebdf704db4c624f565f018a61ffd32a79bbd16453606887f43a1e  pr-rich-ham-receiver-dad.mp3
110190c07cc3b13530545afe9d0ca2ad28b6d3cad0570379dc1b7301cb3ec048  pr-rich-walkie-obey.mp3
6d24ecacf7b7c6ca4f6b61f13d543441b7b86a2abc43104497a81d7815f8227f  pr-rich-women-battle.mp3
7efb737bddc3375a8f08a89c45556796e86a4b3e90736e39b7548480d89cadb0  pr-rich-women-window.mp3
```

The fixed final Gravitas PSA transcript in section 13.14 binds to
`pr-broadcast-psa-propoganda.mp3`. `gravitas-opening-jingle.mp3` and
`gravitas-closing-bumper.mp3` remain separate bookend cues and must not be used as
the PR.

## 4. High-level chapter state machine

```text
Chapter 1 actual episode-boundary completion
-> Chapter 2 title card
-> preserve the established Story room; no scan or prop placement
-> capture the current window-local route from its current world transform
-> load one chapter-scoped spouse asset/runtime at the window
-> start idle / air-punch presentation loop
-> arm Crank Radio 01

Crank Radio 01: missing persons bulletin
-> Ham Receiver sequence: Dad 01 -> Rich 02 -> Dad 03
-> Walkie sequence: Big Mike 01 -> Rich 02 -> Big Mike 03
-> Dad Photo: present-day Rich
-> Crank Radio 02: grid-failure emergency alert
-> request window exit; finish the active attack or 20-second idle boundary
-> play Rich's fixed window-recognition PR while the same woman exits
-> transfer that same spouse runtime from the window route to the door portal
-> Rich fixed battle PR; no PromptVoice
-> existing Story spouse combat
-> complete death/release boundary
-> Ham Receiver sequence: present-day Rich -> present-day CatEye81
-> Crank Radio 03: opening jingle + PSA PR + PromptVoice + closing bumper
-> persist Chapter 2 complete
-> show end-of-available-content `Gravitas Plague` title card
```

Within each multi-point Ham or Walkie sequence, points automatically advance with
no intermediate icon and no lease gap. Between numbered chapter sections, the
next surface receives a Play icon. The completed terminal surface may retain its
microphone until that same surface is rebound later, but the arbiter still allows
only one Turing operation at a time.

## 5. Chapter coordinator ownership

Add:

```text
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter02/Chapter02Coordinator.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter02/Chapter02State.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter02/Chapter02ProgressStore.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter02/Chapter02WindowWomanCoordinator.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter02/Chapter02WindowWomanRuntime.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter02/Chapter02WomanBattleCoordinator.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter02/Chapter02SurfaceSequenceCoordinator.swift
```

`Chapter02Coordinator` owns narrative progression, chapter checkpoints, automatic
handoffs, and the final episode-boundary event. It does not own Foundation, Qwen,
the decoder, generated playback, the room scan, prop placement, or global audio
session configuration.

Use one run ID and idempotent completion event IDs. Every callback must verify the
active run ID before changing state.

Suggested state enum:

```swift
enum Chapter02State: Sendable, Equatable {
    case idle
    case loadingWomanRuntime
    case missingPersonsReady
    case dadHamReady
    case bigMikeWalkieReady
    case dadPhotoReady
    case blackoutBroadcastReady
    case womanExitingWindow
    case womanBattle
    case postBattleHamReady
    case gravitasPSAReady
    case ending
    case complete
    case failed(String)
    case cancelled
}
```

## 6. Durable continuation

Create a separate versioned snapshot:

```swift
enum Chapter02Checkpoint: String, Codable, Sendable, Comparable {
    case root = "chapter02.root"
    case missingPersonsCompleted = "chapter02.missingPersons.completed"
    case dadHamCompleted = "chapter02.dadHam.completed"
    case bigMikeWalkieCompleted = "chapter02.bigMikeWalkie.completed"
    case dadPhotoCompleted = "chapter02.dadPhoto.completed"
    case blackoutBroadcastCompleted = "chapter02.blackoutBroadcast.completed"
    case womanExitPending = "chapter02.womanExit.pending"
    case womanBattlePending = "chapter02.womanBattle.pending"
    case womanBattleCompleted = "chapter02.womanBattle.completed"
    case postBattleHamCompleted = "chapter02.postBattleHam.completed"
    case gravitasPSACompleted = "chapter02.gravitasPSA.completed"
    case complete = "chapter02.complete"
}
```

Persistence rules:

```text
- Commit only after the point's actual terminal playback and route completion.
  For PromptVoice points this means the final generated handle. For the two
  Rich PR-only cues this means the exact authored PR handle.
- Commit battle completion only after enemy, mirror, audio, and portal release.
- Persist one encoded snapshot atomically, not separate booleans.
- Store logical state only. Never persist entities, transforms, audio handles,
  model state, generated dialogue, Tasks, or Foundation sessions.
- Continue never rescans the room and never reruns prop placement.
- Recompute the current window and door world transforms on every restore.
- A completed point is never replayed by Continue.
```

Recommended continuation destinations:

```text
root                         -> window woman loop + Crank Radio 01 Play
missingPersonsCompleted      -> window woman loop + Ham Receiver Dad 01 Play
dadHamCompleted              -> window woman loop + Walkie Big Mike 01 Play
bigMikeWalkieCompleted       -> window woman loop + Dad Photo Play
dadPhotoCompleted            -> window woman loop + Crank Radio 02 Play
blackoutBroadcastCompleted   -> reconstruct window woman, then run exit
womanExitPending             -> finish/restart the deterministic exit boundary
womanBattlePending           -> start spouse portal intro; do not replay exit PR
womanBattleCompleted         -> Ham Receiver post-battle Rich Play
postBattleHamCompleted       -> Crank Radio Gravitas PSA Play
gravitasPSACompleted         -> end title card
complete                     -> end title card; no chapter content replay
```

## 7. Surface bindings and point IDs

Add these chapter-scoped bindings. Do not reuse Prologue or Chapter 1 conversation
keys.

```text
chapter02CrankMissingPersons
  root/terminal: chapter02.crankRadio.broadcaster.missingPersons.001
  key: chapter02.object.crank_radio.missing_persons
  character: broadcaster
  route: crankRadioSpatial
  surface: crankRadio

chapter02DadHam
  root: chapter02.hamReceiver.dad.script01
  terminal: chapter02.hamReceiver.dad.script03
  key: chapter02.object.ham_receiver.dad_outbreak_night
  terminal character: dad
  route: hamReceiverSpatial
  surface: hamReceiver

chapter02BigMikeWalkie
  root: chapter02.walkie.bigMike.script01
  terminal: chapter02.walkie.bigMike.script03
  key: chapter02.dialogue.big_mike.rich.outbreak_night
  terminal character: big_mike
  route: walkieSpatial
  surface: walkie

chapter02DadPhoto
  root/terminal: chapter02.dadFrame.rich.dadDisappeared.001
  key: chapter02.object.dad_frame.dad_disappeared
  character: rich
  route: roomGlobal
  surface: dadFrame

chapter02CrankGridFailure
  root/terminal: chapter02.crankRadio.broadcaster.gridFailure.002
  key: chapter02.object.crank_radio.grid_failure
  character: broadcaster
  route: crankRadioSpatial
  surface: crankRadio

chapter02PostBattleHam
  root: chapter02.hamReceiver.rich.revelation.001
  terminal: chapter02.hamReceiver.cateye81.revelation.002
  key: chapter02.object.ham_receiver.revelation
  terminal character: cateye81
  route: hamReceiverSpatial
  surface: hamReceiver

chapter02CrankGravitasPSA
  root/terminal: chapter02.crankRadio.broadcaster.gravitasPSA.003
  key: chapter02.object.crank_radio.gravitas_psa
  character: broadcaster
  route: crankRadioSpatial
  surface: crankRadio
```

The two automatic Rich reactions use a noninteractive, prerecording-only
cinematic binding owned by the Chapter coordinator:

```text
chapter02.room.rich.windowRecognition.001
chapter02.room.rich.womanBattle.001
```

They use `roomGlobal`, do not expose a microphone, and cannot be started by a
production icon. Their descriptors must set `voicePromptID: null` and must not
enter Foundation, Qwen, the decoder, generated playback, or filler.

## 8. Speech execution contract

Every Chapter 2 point that actually has PromptVoice uses the same production
order:

```text
claim Story interaction
-> hide/disable incompatible icons synchronously
-> start the surface's existing filler/static
-> open a fresh Foundation session
-> build one prompt from profile + exact PR transcript + exact Story Intent
-> Foundation returns and validates
-> only then may the fixed PR begin
-> Qwen Fresh2 render/decode begins with the accepted PromptVoice segments
   while the PR is playing
-> PR actual completion preserves precedence
-> exact next generated segment plays as soon as file-backed and ready
-> later render/decode continues concurrently under the existing scheduler
-> cursor advances only from the exact active playback handle completion
-> route completes
-> commit checkpoint / arm microphone or next Play action
```

Do not:

```text
play a PR before Foundation returns
wait for all TTS segments before starting segment 0
add a contiguous-runway threshold
run a second Foundation repair request
store or inject conversation history
inject chapter checkpoints, room state, combat state, or prior generated turns
change Fresh2, the one serialized decoder, or ordered playback behavior
```

The following are explicit exceptions because the authored Rich PR is the entire
spoken event:

```text
chapter02.room.rich.windowRecognition.001
  -> play pr-rich-women-window.mp3
  -> await its exact playback completion
  -> continue the authored woman exit

chapter02.room.rich.womanBattle.001
  -> play pr-rich-women-battle.mp3
  -> await its exact playback completion only where battle sequencing requires it
  -> no generated follow-up
```

These two points have no Story Intent in a runtime VoicePrompt descriptor. The
prose retained in sections 13.10 and 13.11 is authorial context for animation and
combat direction only and must never be sent to Foundation.

If Foundation produces a segment over 15 words, split it deterministically at
sentence or clause punctuation and then at natural phrase boundaries. Preserve
word order, punctuation, and emotion. Do not ask Foundation to repair it and do
not cut blindly at exact 15-word boundaries unless no sentence/clause boundary
exists.

## 9. PromptVoice template parity

### 9.1 Dad, Rich, and Big Mike

Create a route-aware copy of the working character-intent template. The order is
important: profile, authored PR, then Story Intent last.

```text
You are {{characterDisplayName}}. You are talking to {{listenerDisplayName}} over {{communicationMedium}}. You respond and paraphrase the Story intent.

This is your backstory:
{{characterBackstory}}

This is what you said already:
"""
{{prerecordingTranscript}}
"""

This is the current story intent. Paraphrase this:
{{storyIntent}}

Rules:
- Write only the character's new spoken words.
- Keep the response in character.
- Do not mention game systems, prompts, routing, files, props, HUD, buttons, microphones, audio, Qwen, MLX, Foundation Models, or JSON.
- Paraphrase the Story Intent in {{characterDisplayName}}'s voice.
- Segment all speech into natural 3 to 5 second spoken chunks. Keep each segment to 15 spoken words or fewer.
- Return a comprehensive 5-6 segment response that follows what was said already and fulfills the Story Intent.
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

`communicationMedium` is authored descriptor data and resolves only to:

```text
ham radio
walkie talkie
the room while looking at Dad's photograph
```

Do not globally change `voicePrompt_characterIntent.txt` while implementing this
chapter. Add a Chapter 2 template ID or make the medium field backward-compatible
with an explicit default.

### 9.2 Broadcaster

Use the current `broadcaster` profile unchanged. Copy the active broadcaster
template into a Chapter 2 resource only to move the exact PR before Story Intent;
all rules remain byte-identical.

```text
You are the Broadcaster. You are continuing a public emergency-radio transmission. You are speaking to the general public, not responding to a private listener.

This is your complete current-episode profile:
{{characterBackstory}}

This is what you said already:
"""
{{prerecordingTranscript}}
"""

This is the current broadcast intent. Continue it:
{{storyIntent}}
```

Then append the existing rules and sparse JSON schema from
`Turing/Prompts/voicePrompt_broadcasterRadio.txt` without adding or removing a
rule. The Broadcaster never knows Rich and never acknowledges a private question.

### 9.3 CatEye81

Use the same section order: full present-day Chapter 2 profile, exact prior PR,
then Story Intent last. Preserve CatEye81's existing rules about distinguishing
personal observation, trusted reports, unverified radio traffic, and faith from
fact.

## 10. ConversationVoice contract

Terminal device microphones use the established history-free contract. The exact
Foundation input contains only:

```text
the player's current dictation
the terminal point's character profile
the terminal point's Story Intent
the terminal point's exact authored PR transcript
the production rules and sparse JSON schema
```

Never include:

```text
prior generated PromptVoice text
previous conversation turns
checkpoint names
completed ScriptPoint IDs
room or prop state
window/battle state
saved summaries or conversation seeds from another chapter
```

Past-profile microphones remain past-profile conversations. For example, a
follow-up after Dad Ham Script 03 uses `dad.chapter02.outbreakNight`; it must not
give Dad knowledge of his later infection, death, or burial.

## 11. Character profiles

Voice identity and timeline profile are separate. Rich and Big Mike keep their
existing voice clones. Dad gets a new voice clone. The profile selected by each
point controls knowledge and perspective.

### 11.1 Dad - `dad.chapter02.outbreakNight`

```text
HOW DAD RESPONDS AND SPEAKS

Dad speaks like a practical engineer and county relay technician who has spent a lifetime repairing systems other people depend on. He is calm, exact, patient under ordinary pressure, and stubborn when a job remains unfinished. He does not give speeches for effect. He identifies the failure, names the next action, and keeps working. When frightened, his sentences become shorter and more directive. His love comes through as preparation, instruction, and the assumption that Rich is capable. He rarely says what he feels directly when an order can carry the same meaning.

RELATIONSHIP WITH RICH

Dad is Rich's father, teacher, and the person who taught him to understand machines. He showed Rich how to use tools, trace wiring, isolate faults, repair radios, and keep old equipment alive. He respects Rich's intelligence and knows Rich inherited both his troubleshooting instinct and his refusal to leave a broken system alone. Dad can sound demanding because he trusts Rich with serious responsibility. On the night the lights go out, Dad's first goal is to keep Rich inside the house and alive.

BACKGROUND

Dad is an engineer with hands-on experience in electrical systems, radio relays, generators, emergency power, and field repair. The Black Creek county relay is carrying ambulance and emergency traffic when the grid fails. He knows the tower, generator, service truck, north road, and bridge. He is not a soldier, doctor, epidemiologist, national-security official, or prophet. He does not know why the county failed or whether the reports of nuclear attack are true.

CURRENT KNOWLEDGE - OUTBREAK NIGHT

This profile exists only on the night the electricity fails. Dad knows the county grid went dark, phones and emergency traffic are failing, the relay is operating on generator power, and Rich is at home. He does not know the later name Gravitas Plague, CatEye81, antigen, Gravitas drones, the missing woman's fate, his own infection, his appearance at the window, or his death. He must never leak future knowledge backward. He believes ten more minutes at the relay may keep emergency voices connected, and he hopes he can still return home afterward.
```

### 11.2 Rich past - `rich.chapter02.outbreakNight`

```text
HOW RICH RESPONDS AND SPEAKS

Rich speaks like a smart, practical man whose ability to reason is being overtaken by fear for his father. He is quick, skeptical, mechanically minded, stubborn, and emotionally direct when the stakes become personal. He does not sound heroic, polished, or omniscient. He asks for concrete facts and argues with orders that feel like surrender. His humor disappears when he believes Dad may not come home.

RELATIONSHIP WITH DAD AND BIG MIKE

Dad taught Rich electronics, tools, repair, and the belief that a failed system can be understood. Rich loves him but resents the way duty can make Dad choose a machine or public responsibility over his own safety. Big Mike is Rich's neighbor and closest friend. Rich trusts Mike's threat judgment even when he resists being told to stay put.

BACKGROUND

Rich understands radios, wiring, batteries, workshop tools, and practical troubleshooting. He is at home when the county loses power. The workshop and house are familiar systems he can secure, but staying inside feels passive while Dad remains at the relay.

CURRENT KNOWLEDGE - OUTBREAK NIGHT

Rich knows only that the horizon and county lights went black, phones failed, emergency bands carry conflicting nuclear reports, and Dad remains at the relay. He has not met CatEye81. He knows nothing about antigen, Gravitas drones, the later Plague diagnosis, the missing woman's fate, Dad's infection, or future battles. He must never use present-day knowledge in these transmissions.
```

### 11.3 Big Mike past - `big_mike.chapter02.outbreakNight`

```text
HOW BIG MIKE RESPONDS AND SPEAKS

Big Mike speaks like a large, exhausted man imposing order on panic. He is direct, streetwise, protective, practical, and blunt. His Baltimore edge is natural rather than exaggerated. Military and security experience make him reduce chaos to location, movement, routes, and the people he can still reach. Fear appears as urgency. Care appears as commands and irritation. He does not sound academic, polished, or like a mission dispatcher.

RELATIONSHIP WITH RICH AND DAD

Mike is Rich's neighbor, best friend, and closest local lifeline. Dad also matters to him. During an ice storm, Dad kept Mike's family alive by repairing their generator and refused payment. Mike understands that debt as loyalty, not money. He knows Rich may leave the house if nobody gives him a reason strong enough to stay.

BACKGROUND

Mike is a former Division One offensive guard, Afghanistan veteran, and security guard. He knows vehicles, radios, entrances, threat assessment, generators, and panic. He has access to a service truck and is closer to the Black Creek relay than Rich.

CURRENT KNOWLEDGE - OUTBREAK NIGHT

Mike hears broken emergency reports claiming China and Russia launched nuclear weapons and that the United States responded. He sees a red sky beyond the ridge and a countywide blackout. He cannot verify the reports. He knows Dad is at the relay and Rich is at home. He does not know about the named Plague, CatEye81, Gravitas beacons, antigen, drones, the missing woman's future, Dad's infection, or any later chapter event.
```

### 11.4 Rich present - `rich.chapter02.present`

Copy the complete current `rich` writeup, unabridged, then append exactly:

```text
CHAPTER 02 - PRESENT-DAY CURRENT KNOWLEDGE

Rich has survived Mrs. Dempsey, the Gravitas Robot encounter, and the final fight with Dad. Dad is buried near the creek. Rich has three antigen cartridges remaining after reserving one for possible self-exposure. He has working contact with Big Mike and CatEye81 and has heard the current Broadcaster transmissions. The night the county lost power remains the dividing line in his memory. Rich may remember what he heard that night, but he must distinguish memory from facts learned later. This profile contains no knowledge of the young woman's identity or Chapter 2 battle until the active point's exact PR and Story Intent provide it.
```

This profile is used by the Dad Photo and post-battle Rich Ham PromptVoice points.
The window-recognition and woman-battle events use the same Rich playback identity
for fixed PRs but do not construct Foundation prompts.

### 11.5 CatEye81 present - `cateye81.chapter02.present`

Copy `cateye81.chapter01.fourChances` in full, unabridged, then append exactly:

```text
CHAPTER 02 - PRESENT-DAY CURRENT KNOWLEDGE

CatEye81 is speaking in the present day, not during Rich's remembered blackout night. She now knows Rich killed Dad after an attempted rescue and has encountered an infected woman tied to the earliest missing-person bulletins. CatEye81 has long interpreted the collapse through Christian faith and the Book of Revelation. She may explain that belief clearly, but she must label it as belief rather than verified science. She knows nuclear reports, hunger, plague, and death occurred in a sequence that resembles the horsemen to her. She does not know the Plague's supernatural or scientific cause and must not claim that Satan, God, or Gravitas has been proven responsible.
```

### 11.6 Broadcaster - unchanged

Use the existing profile exactly:

```text
Turing/Characters/broadcaster.json
characterProfileID: broadcaster
voiceID: broadcaster_base_clone_v1
```

Do not create a past/future Broadcaster personality split for Chapter 2. The
authored PR and Story Intent supply the period-specific facts. The existing
profile already forbids private listener knowledge and unverified certainty.

## 12. Dad voice clone

Add a fifth Turing voice runtime:

```text
characterID: dad
speakerID: dad
displayName: Dad
voiceID: dad_base_clone_v1
clone profile: Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone
default variant: dad_reference_fast_01
allowed output route: hamReceiverSpatial
playback rate: 0.85 initially; change only after an authored device audition
```

Add `TuringDadVoiceIdentity` beside the existing Rich, Big Mike, Broadcaster, and
CatEye81 identities. Add Dad to `character-runtimes.json`; do not special-case him
inside the renderer.

Required clone package:

```text
Dad/BaseClone/dad_base_clone_v1.qwenclone/
  metadata.json
  selection-catalog.json
  checksums.sha256
  variants/dad_reference_fast_01/
    variant.json
    ref_text.txt
    ref_audio/original/dad-reference-fast.mp3
    ref_audio/normalized/ref_24000_mono.wav
    qwen_artifacts/clone_prompt_manifest.json
    qwen_artifacts/clone_artifacts.safetensors
    qwen_artifacts/ref_text_tokens.i32le
    qwen_artifacts/reference_codes.i32le
    qwen_artifacts/speaker_embedding.f32le
    qwen_artifacts/checksums.sha256
```

The Dad reference audio now exists at:

```text
/Users/richardfallat/Projects/dev/turing-native-qwen-cloner/dad-reference-fast.mp3
duration: 11.467750 seconds
format: MPEG audio, 44,100 Hz, mono, 128 kb/s
SHA-256: 0d3f766e61f9fd4bfad2e16a33b8020dc630201805f02214e36a4bc5e89f602b
```

Copy that exact source into the clone package and normalize it to the established
24 kHz mono authoring WAV. The exact spoken reference transcript is not present
beside the file and was not found in the cloner project. That transcript remains a
hard authoring input; Codex and the architect must not transcribe, infer, or guess
it. Catalog validation remains blocked until `ref_text.txt` is author-supplied and
the package checksums are finalized.

### 12.1 Required transcript boundary

Before running any clone tool, the author must provide the exact words spoken in
`dad-reference-fast.mp3`. Write only those words to UTF-8 `ref_text.txt`: no
speaker label, performance note, punctuation commentary, inferred missing word,
or Chapter 2 profile prose. The audio has no embedded transcript metadata and no
matching text file currently exists in the cloner project.

```text
AUTHOR INPUT REQUIRED: exact dad-reference-fast.mp3 transcript
```

Do not use speech recognition output as the authoritative transcript. It may help
the author review the recording, but the author must approve the exact final text.
Qwen full-ICL cloning binds reference codes to these text tokens, so approximate
text is not acceptable.

### 12.2 Exact profile scaffold

Physical resource root:

```text
/Users/richardfallat/Projects/dev/gravitas-plague/Gravitas Plague/TuringResources/Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone
```

Create `metadata.json` as:

```json
{
  "schemaVersion": 1,
  "voiceID": "dad_base_clone_v1",
  "characterID": "dad",
  "displayName": "Dad",
  "language": "english",
  "modelFamily": "qwen3-tts-base",
  "modelID": "qwen3-tts-12hz-1.7b-base-4bit",
  "quantization": "4bit",
  "profileKind": "qwenBaseCloneReferenceProfile",
  "sourceProvider": "local_recording",
  "defaultVariantID": "dad_reference_fast_01",
  "allowFallback": false,
  "allowRuntimeRefAudioEncoding": false,
  "allowPrerecordedDialoguePlayback": false,
  "variants": [
    {
      "variantID": "dad_reference_fast_01",
      "path": "variants/dad_reference_fast_01/variant.json"
    }
  ]
}
```

Create `selection-catalog.json` as:

```json
{
  "schemaVersion": 1,
  "voiceID": "dad_base_clone_v1",
  "defaultVariantID": "dad_reference_fast_01",
  "variants": [
    {
      "variantID": "dad_reference_fast_01",
      "displayName": "Dad Reference Fast 01",
      "enabled": true
    }
  ]
}
```

Create the bootstrap `variant.json` with the same schema as
`broadcaster_reference_fast_01/variant.json`, but with these required identities
and references:

```json
{
  "schemaVersion": 1,
  "voiceID": "dad_base_clone_v1",
  "characterID": "dad",
  "variantID": "dad_reference_fast_01",
  "displayName": "Dad Reference Fast 01",
  "kind": "baseCloneReferenceVariant",
  "language": "english",
  "sourceProvider": "local_recording",
  "allowFallback": false,
  "allowPrerecordedDialoguePlayback": false,
  "reference": {
    "channels": 1,
    "sampleRate": 24000,
    "normalizedFormat": "wav_float32_le",
    "originalAudioPath": "ref_audio/original/dad-reference-fast.mp3",
    "normalizedAudioPath": "ref_audio/normalized/ref_24000_mono.wav",
    "textPath": "ref_text.txt"
  },
  "qwenArtifacts": {
    "status": "notPrecomputed"
  }
}
```

Performance-selection metadata may be added using the existing schema, but it may
not change voice generation, insert a fallback, or select another reference.

### 12.3 Package and normalize the supplied recording

Add `Scripts/package_dad_authoring_inputs.sh` or generalize the Rich packager. Its
effective operations must be exactly:

```bash
set -euo pipefail

CLONER_ROOT=/Users/richardfallat/Projects/dev/turing-native-qwen-cloner
GRAVITAS_ROOT=/Users/richardfallat/Projects/dev/gravitas-plague
PROFILE="$GRAVITAS_ROOT/Gravitas Plague/TuringResources/Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone"
VARIANT="$PROFILE/variants/dad_reference_fast_01"
SOURCE="$CLONER_ROOT/dad-reference-fast.mp3"
ORIGINAL="$VARIANT/ref_audio/original/dad-reference-fast.mp3"
NORMALIZED="$VARIANT/ref_audio/normalized/ref_24000_mono.wav"

test -s "$SOURCE"
test -s "$VARIANT/ref_text.txt"
mkdir -p "$(dirname "$ORIGINAL")" "$(dirname "$NORMALIZED")"
cp -f "$SOURCE" "$ORIGINAL"
cmp -s "$SOURCE" "$ORIGINAL"

ffmpeg -hide_banner -loglevel error -y \
  -i "$ORIGINAL" \
  -map_metadata -1 \
  -vn \
  -ac 1 \
  -ar 24000 \
  -c:a pcm_f32le \
  "$NORMALIZED"

test "$(ffprobe -v error -select_streams a:0 -show_entries stream=sample_rate -of default=noprint_wrappers=1:nokey=1 "$NORMALIZED")" = "24000"
test "$(ffprobe -v error -select_streams a:0 -show_entries stream=channels -of default=noprint_wrappers=1:nokey=1 "$NORMALIZED")" = "1"
```

The source SHA-256 must still be:

```text
0d3f766e61f9fd4bfad2e16a33b8020dc630201805f02214e36a4bc5e89f602b
```

No `atempo`, `asetrate`, pitch shift, denoiser, silence trimming, time stretch, or
other performance-changing filter is permitted. This stage changes container,
sample format, channel count, and sample rate only.

### 12.4 Generate the Qwen full-ICL artifacts

Add `Scripts/precompute_dad_clone_artifacts.sh` as a thin parameter wrapper around
the existing generalized authoring tool. It must run the existing local model and
must not use `--x-vector-only`:

```bash
CLONER_ROOT=/Users/richardfallat/Projects/dev/turing-native-qwen-cloner
GRAVITAS_ROOT=/Users/richardfallat/Projects/dev/gravitas-plague
PROFILE="$GRAVITAS_ROOT/Gravitas Plague/TuringResources/Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone"

"$CLONER_ROOT/.venv-qwen-authoring/bin/python" \
  "$CLONER_ROOT/Tools/precompute_qwen_base_clone_artifacts.py" \
  --root "$GRAVITAS_ROOT" \
  --profile "$PROFILE" \
  --voice-id dad_base_clone_v1 \
  --character-id dad \
  --variant-id dad_reference_fast_01 \
  --authoring-model "$CLONER_ROOT/Authoring/Models/Qwen3-TTS-12Hz-1.7B-Base" \
  --language English \
  --write-smoke-wav \
  --smoke-text "Rich, you copy? Keep the doors locked and stay by the radio."
```

The tool must create and validate the complete output set before changing
`qwenArtifacts.status` to `precomputed`:

```text
clone_prompt_manifest.json
clone_artifacts.safetensors
reference_codes.i32le
ref_text_tokens.i32le
speaker_embedding.f32le
checksums.sha256
mac_authoring_smoke.wav
mac_authoring_smoke_metrics.json
```

The manifest must report `mode: icl`, `xVectorOnlyMode: false`, the Dad identities,
the normalized-audio hash, and the exact approved transcript hash.

### 12.5 Finalize checksums and the voice registry

Before finalization, add exactly one enabled Dad entry to
`Turing/Config/voice-registry.json` using the same base-clone schema as Broadcaster:

```text
id / voiceID:       dad_base_clone_v1
speakerID:          dad
characterID:        dad
displayName:        Dad
profilePath:        Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone
resourcePath:       Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone
defaultVariantID:   dad_reference_fast_01
selectionCatalogPath: selection-catalog.json
allowFallback:      false
runtimeMode:        baseClone
enabled:            true
```

Then run the existing generic finalizer:

```bash
GRAVITAS_ROOT=/Users/richardfallat/Projects/dev/gravitas-plague
PROFILE="$GRAVITAS_ROOT/Gravitas Plague/TuringResources/Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone"

python3 "$GRAVITAS_ROOT/Scripts/finalize_qwen_voice_registry.py" \
  --root "$GRAVITAS_ROOT" \
  --profile "$PROFILE" \
  --voice-id dad_base_clone_v1 \
  --character-id dad \
  --variant-id dad_reference_fast_01 \
  --registry "$GRAVITAS_ROOT/Gravitas Plague/TuringResources/Turing/Config/voice-registry.json"
```

This command validates identities, the 24 kHz mono WAV, transcript/audio hashes,
artifact presence, precomputed status, and safetensors/manifest hashes; then it
writes variant/profile checksum files and the content-addressed registry revision.

### 12.6 Runtime registration

Add Dad to `character-runtimes.json` as a normal character runtime:

```text
characterID: dad
displayName: Dad
voiceID: dad_base_clone_v1
cloneProfileResourcePath: Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone
allowedOutputRoutes: [hamReceiverSpatial]
outputProcessing.playbackRate: 0.85
```

Copy the established greedy full-reference Qwen block used by the existing
Big Mike/Broadcaster/CatEye81 base clones; do not invent Dad-specific sampling,
row limits, decoder settings, fallback, or quality repair. Dad's ham tuning filler
remains surface-owned, so do not create a Dad filler directory merely to satisfy
the runtime schema.

Add the identity without special-casing the renderer:

```swift
nonisolated enum TuringDadVoiceIdentity {
    static let characterID = "dad"
    static let speakerID = "dad"
    static let voiceID = "dad_base_clone_v1"
    static let displayName = "Dad"
    static let cloneProfileResourcePath =
        "Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone"
}
```

All Dad PromptVoice and ConversationVoice descriptors resolve this identity and
the shared `TuringCharacterQwenRenderer`, two Fresh workers, serialized decoder,
ordered file-backed playback, and `hamReceiverSpatial` endpoint. There is no Dad-
specific renderer, decoder, queue, Foundation service, or reference-audio runtime
encoding.

### 12.7 Clone acceptance

Required proof before Chapter 2 device testing:

```text
original MP3 copy is byte-identical to supplied source
normalized reference is one-stream 24 kHz mono float32 WAV
ref_text.txt is the author-approved exact recording transcript
artifact manifest text/audio hashes match packaged inputs
full ICL reference codes and text tokens are nonempty
speaker embedding is nonempty
variant and profile checksum manifests validate
voice-registry revision matches the finalized profile tree
mac_authoring_smoke.wav is non-silent and audibly approved as Dad
native clone-profile loader resolves dad_reference_fast_01 with no fallback
one short device canary renders, decodes, publishes, and plays Dad through the ham receiver
```

Do not alter Qwen runtime sampling to compensate for a poor clone. If the smoke
voice is wrong, investigate the exact transcript, source recording, normalized
audio, or precomputed artifacts before touching production rendering.

## 13. Exact authored content manifest

All PR transcripts below are fixed text. Store them verbatim in manual
prerecording descriptors and bind the audited files from section 3.1. PromptVoice
intent is adjacent authored subtext and is stored verbatim in its VoicePrompt
descriptor except for sections 13.10 and 13.11, which are explicitly PR-only.
Do not paraphrase a transcript or active intent while authoring JSON.

### 13.1 Crank Radio 01 - Missing Persons

```text
PR:
This is a Black Creek County missing persons bulletin.

Authorities are searching for seven women reported missing from occupied homes between midnight and dawn.

No residence showed signs of forced entry. In every case, phones, vehicles, identification, and personal belongings remained inside.

One missing woman was last seen wearing a pale-yellow long-sleeve pajama top and matching pale-yellow pajama pants. She is believed to be barefoot.

Her husband woke shortly after three in the morning and found the front door open and the bed empty.

Residents should report any verified sighting to county emergency services.

This bulletin will repeat.

Story Intent:
I am reading a routine county bulletin while the pattern grows stranger with every address. Husbands and children are waking to open doors, empty beds, untouched cars, and no sign of struggle. The language remains orderly because the county still believes these women are lost somewhere inside a world that can be searched.
```

### 13.2 Ham Dad 01

```text
PR:
Rich, you copy? It’s Dad.

The whole county just went dark.

I’m at the Black Creek relay on generator power. Ambulances are calling blind, and this tower is the only thing still carrying them.

I know what you’re going to say.

Give me ten minutes. Then I’m coming home.

Keep the doors locked. Keep the workshop dark. Stay by the radio.

Story Intent:
I am Dad on the night the electricity failed. Emergency voices are disappearing one by one from the relay, and I am trying to sound steadier than I feel. I believe I can give the county ten more minutes and still make it home to my son.
```

### 13.3 Ham Rich 02

```text
PR:
Let the tower die.

The whole horizon went black at once. Mike says the phones are gone, and nobody knows what comes next.

I don’t care how many voices are still on that relay.

I care whether yours comes back through my door.

Come home, Dad.

Right now.

Story Intent:
I am finished pretending this is another repair Dad can complete. Fear and death are breaking through the county traffic, and every minute he stays makes the distance between us feel permanent. I need him to choose being my father over being the man everyone calls when something fails.
```

### 13.4 Ham Dad 03

```text
PR:
Listen to me.

A man spends his life thinking he can fix what breaks.

Then comes a night when the whole world breaks at once.

You cannot save the whole world, Rich. You keep what is in front of you.

That house is in front of you.

Keep it.

I’ll come if I can.

If I don’t, you do not come looking.

Story Intent:
I know the relay may be the last useful thing I ever repair, and I know Rich may hear my decision as abandonment. I am asking him to survive the choice I am making. My love reaches him as an order because an order is the only protection I can still send across the dark.
```

### 13.5 Walkie Big Mike 01

```text
PR:
Rich. Answer me.

The phones are dead.

The emergency bands say China and Russia launched nukes. They say we launched back.

Nobody knows what cities are left. Nobody knows who is lying.

The sky beyond the ridge is red, and every light in the county is gone.

Tell me you’re inside.

Tell me where your dad is.

Story Intent:
I am hearing the end of the world in broken pieces and reducing it to the two facts I can still act upon: Rich is alive, and Dad is away from home. Fear makes me blunt. I need Rich’s situation before grief sends him out onto the road.
```

### 13.6 Walkie Rich 02

```text
PR:
He’s still at the relay.

He told me to keep the house and not come looking if he doesn’t make it back.

I don’t know if that was an order or a goodbye.

I can’t sit here while he disappears, Mike.

I can’t let the last thing I ever do for him be obeying.

Story Intent:
Leaving may kill me, but staying feels like choosing Dad’s death from a safe room. His final words have already begun turning into guilt. I need Mike to give me a reason to remain that is stronger than fear.
```

### 13.7 Walkie Big Mike 03

```text
PR:
I’m closer to the relay.

Your father kept my family alive through that ice storm and never let me pay him.

Tonight I pay him.

I’m taking the service truck to the north road. I’ll go as far as the bridge and look for his headlights.

You stay in that house.

If one of us comes back, somebody needs to be there to hear the engine.

Story Intent:
I love Dad too, and the debt between us was never money. I give Rich a reason to remain by taking responsibility for the search myself. The possibility that neither Dad nor I will return sits beneath every word, but I speak as though one of us must.
```

### 13.8 Dad Photo - Dad Disappeared

```text
PR:
Mike found Dad’s truck before dawn.

It was parked beneath the relay with the driver’s door open and the keys still in it.

No Dad.

For weeks I kept telling myself a man could disappear and still be alive.

Then he came to this window with cloudy eyes and no voice, and I learned there are worse ways to come home.

The last thing he told me was to keep the house.

I kept it.

I just don’t know what it cost him.

Story Intent:
I am looking at the photograph after burying Dad. Mike found the truck but never found the man who drove it. I have spent every day since turning Dad’s last order into evidence for and against myself. Obedience kept me alive long enough to see what the Plague made of him.
```

### 13.9 Crank Radio 02 - The Night the Lights Went Out

```text
PR:
This is the Emergency Alert System.

China and Russia have launched nuclear weapons.

The United States has launched in response.

The national power grid is failing.

Go below ground if you can. Otherwise move to the center of the structure and remain away from windows.

Fill every available container with water.

Turn off every light.

Lock every door.

Emergency services will not come.

This message will continue for as long as power remains.

Story Intent:
I am the last public voice before the grid goes dark. There is no promise of rescue left in the message. I give the living only what remains within reach: water, walls, darkness, and time. Beneath the procedure is the knowledge that entire cities are dying beyond the range of the broadcast.
```

### 13.10 Window Exit - Rich Recognizes Her

```text
PR:
Wait.

I remember you.

You were that missing wife in the yellow pajamas.

Long sleeves. Matching pants. Barefoot.

Your husband was on the county band every night asking if anybody had seen you.

Then the lights went out, and his voice disappeared with everybody else’s.

All this time he was waiting for you to come home.

And now you’re coming to my door.

Non-runtime authorial context; do not create PromptVoice:
Her clothing brings the old county bulletins back all at once. She is the woman whose husband kept calling into the dark after the world stopped answering. I understand that the first disappearances were already becoming part of the Plague before anyone knew its name.
```

### 13.11 Woman Battle - Rich

```text
PR:
I remember what he sounded like.

He kept describing your clothes because it was all he had left.

Yellow shirt. Yellow pants. Bare feet.

He said you would never leave without telling him where you were going.

He was still looking for you when the station died.

I’m sorry.

I’m sorry this is the only way anybody ever found you.

Non-runtime authorial context; do not create PromptVoice:
I am fighting the answer to a husband’s unanswered search. His voice has survived in my memory longer than their home, their marriage, or the county that recorded him. I cannot return her to him. I can only remember who she was while I survive what remains.
```

### 13.12 Post-battle Ham Rich

```text
PR:
Cat Eye Eight-One, this is Rich.

The woman outside was one of the first missing persons.

Her husband was calling the county bands before the power failed. She disappeared from their house in the night and came to mine weeks later infected.

Dad vanished that same night.

The nukes went up. The lights went out. Then the dead started walking.

Tell me what you think is happening.

Not what the government called it.

What you believe.

Story Intent:
I am no longer asking CatEye81 for procedure or verified reports. I have killed Dad and the missing woman, and the official language of disease feels too small for the world I have witnessed. I want her faith to name the pattern because I am afraid the pattern has already named us.
```

### 13.13 Post-battle Ham CatEye81

```text
PR:
Rich, I think Satan is loose in the world.

I think Revelation is no longer a book about someday.

John saw the red horse take peace from the earth.

He saw the black horse bring hunger.

Then came the pale horse, and the rider’s name was Death, and Hell followed after him.

Look at what we have.

Nukes in the sky. Empty shelves. Pestilence in the blood. The dead at the door.

We called it a symbol because the lights still came on when we touched a switch.

Then the lights went out.

Maybe God has not abandoned us.

Maybe He has only stopped holding back what we chose.

Story Intent:
I have believed in the end times since childhood, but belief was easy when Revelation lived beyond the horizon. Now the horsemen feel less like symbols than the plain order of events: war, hunger, plague, and death. I believe Satan is moving through mankind’s appetite for ruin, and the world is being handed over piece by piece to the thing it served.
```

### 13.14 Crank Radio 03 - Gravitas PSA

```text
PR:
This public service announcement is brought to you by the Gravitas Corporation.

Reports of widespread infection, mass disappearance, and nuclear attack remain unconfirmed.

Gravitas continuity systems are operational.

Remain indoors.

Keep registered devices powered.

Leave emergency location services enabled.

Automated Gravitas units are authorized to enter affected regions without human escort.

Cooperate with all drones, medical robots, and relay systems.

Stay calm.

Stay connected.

The future has not been canceled.

Gravitas.

Tomorrow, delivered.

Story Intent:
I am the trusted public Broadcaster speaking for Gravitas while the country collapses. The corporation turns terror into brand reassurance and asks the public to surrender location, attention, and obedience in exchange for the promise that somebody remains in control. The message is comforting because it speaks as though tomorrow is still a product already on its way.
```

Bind this fixed PR to the supplied `pr-broadcast-psa-propoganda.mp3`. Use
`gravitas-opening-jingle.mp3` before it. Use `gravitas-closing-bumper.mp3` only
after the PromptVoice's actual final generated segment completes. These are three
separate completion-owned audio handles.

## 14. ScriptPoint descriptor matrix

Every PromptVoice point uses schema version 2 and `computeStart:
foundationBeforePrerecording`. The two PR-only cinematic points also use schema
version 2 but have `voicePromptID: null`; `computeStart` is absent or `.none`.

```text
ID                                                     profile                                  route                 progression
chapter02.crankRadio.broadcaster.missingPersons.001    broadcaster                              crankRadioSpatial     terminal microphone
chapter02.hamReceiver.dad.script01                     dad.chapter02.outbreakNight               hamReceiverSpatial    auto -> Rich 02
chapter02.hamReceiver.rich.script02                    rich.chapter02.outbreakNight              roomGlobal            auto -> Dad 03
chapter02.hamReceiver.dad.script03                     dad.chapter02.outbreakNight               hamReceiverSpatial    terminal microphone
chapter02.walkie.bigMike.script01                      big_mike.chapter02.outbreakNight          walkieSpatial         auto -> Rich 02
chapter02.walkie.rich.script02                         rich.chapter02.outbreakNight              walkieOutgoingGlobal  auto -> Big Mike 03
chapter02.walkie.bigMike.script03                      big_mike.chapter02.outbreakNight          walkieSpatial         terminal microphone
chapter02.dadFrame.rich.dadDisappeared.001             rich.chapter02.present                    roomGlobal            terminal microphone
chapter02.crankRadio.broadcaster.gridFailure.002       broadcaster                              crankRadioSpatial     terminal microphone
chapter02.room.rich.windowRecognition.001              rich.chapter02.present                    roomGlobal            coordinator-owned
chapter02.room.rich.womanBattle.001                    rich.chapter02.present                    roomGlobal            coordinator-owned
chapter02.hamReceiver.rich.revelation.001              rich.chapter02.present                    roomGlobal            auto -> CatEye81 02
chapter02.hamReceiver.cateye81.revelation.002          cateye81.chapter02.present                hamReceiverSpatial    terminal microphone
chapter02.crankRadio.broadcaster.gravitasPSA.003       broadcaster                              crankRadioSpatial     terminal then chapter end
```

`windowRecognition.001` binds only `pr-rich-women-window.mp3` and
`womanBattle.001` binds only `pr-rich-women-battle.mp3`. Neither has a
VoicePrompt descriptor, terminal microphone, Foundation request, Qwen request,
decoder request, or generated playback queue.

Rich Ham transmissions use the existing Rich room-global/filler treatment while
the ham ambient bed remains spatial at the receiver. Dad and CatEye81 responses
use the receiver endpoint and random ham tuning filler. Big Mike/Rich Walkie
points retain the existing walkie ambient/static/send-static contracts.

## 15. Crank Radio cue and filler behavior

For both emergency bulletins:

```text
Play tap
-> random crank tuning loop during Foundation
-> Foundation success
-> stop tuning gap loop
-> play emergency-broadcast-alert-data-burst.mp3
-> actual cue completion starts PR
-> TTS computes during PR
-> ambient radio static remains underneath cue, PR, and TTS at the established level
```

For the Gravitas PSA:

```text
Play tap
-> random crank tuning loop during Foundation
-> Foundation success
-> stop tuning loop
-> play gravitas-opening-jingle.mp3
-> actual jingle completion starts PR
-> TTS computes during PR
-> ambient radio static remains underneath jingle, PR, and TTS
-> PR actual completion releases generated-speech precedence
-> play generated PromptVoice segments in strict index order
-> await the exact final generated playback handle's actual completion
-> play gravitas-closing-bumper.mp3
-> ambient radio static remains underneath the closing bumper
-> await the exact closing-bumper handle's actual completion
-> stop final-broadcast static/tuning ownership
-> persist gravitasPSACompleted and Chapter 2 complete
-> show the end-of-available-content title card
```

The closing bumper must not start at Foundation completion, PR completion, first
generated publication, estimated duration, or Qwen queue exhaustion. It starts
only after all accepted PromptVoice segments have actually played in order.

Do not use the Horde alarm. Do not restart the old passive 30-second broadcast
loop. Out-of-order generated segments never stop tuning; only readiness of the
exact next index ends a generated-speech gap.

## 16. Window woman lifecycle

Chapter 2 owns exactly one imported spouse asset and one authoritative skinned
runtime for the complete window-to-battle arc. Add a run-scoped
`Chapter02WomanRuntimeLease` with explicit presentation tiers:

```swift
enum Chapter02WomanRuntimeTier: Sendable, Equatable {
    case windowPresentation
    case portalIntro
    case combat
    case released
}

enum Chapter02WindowWomanState: Sendable, Equatable {
    case unloaded
    case loading
    case atEntry
    case walkingEntryToCenter
    case turningLeftAtCenter
    case centeredIdle(cycle: Int)
    case presentingAttack(cycle: Int, index: Int, clipID: String)
    case exitRequested
    case turningRightToExit
    case walkingCenterToExit
    case stagedForDoor
    case transferredToPortalIntro
    case failed(String)
    case cancelled
}
```

At Chapter 2 root:

```text
acquire a fresh TuringStoryWindowCinematicContext from the current placed window
-> snap the window root to its latest committed adjustment transform
-> rebuild entry, center, exit, plane normal, world headings, and turns
-> acquire the full window-exterior lease
-> import spouse_biped.usdz exactly once
-> create one source entity, skeleton, skin, material/texture set, and runtime driver
-> prepare idle_01, unstable_walk_01, turn_left_90, turn_right_90,
   charged-slash-left, charged-slash-right, left_hook_01, and right_hook_01
-> disable combat, player attacks, collisions, hit callbacks, attack callbacks,
   damage callbacks, and character attack/presence audio
-> enable external motion; disable clip-owned root translation
-> apply the spouse asset's authored visual-heading correction
-> apply portal-world IBL to that outside runtime only
-> install the fresh entry world pose and keep the entity hidden
-> submit unstable_walk_01 from entry to center through ScriptedAnchorPathFollower
-> reveal only after entry locomotion has actually started
-> commit the exact center position with the entry-walk orientation
-> play turn_left_90 to actual completion using externalExactWorldPose ownership
-> commit the exact center-facing-window orientation once
-> validate rendered Head->headfront direction within five degrees of the live
   window-plane-facing direction
-> start the indefinite 20-second-idle/all-four-attacks presentation loop
-> only then arm Crank Radio 01
```

This is the Chapter 1 Dad route, not a similar-looking replacement. Reuse or
extract the production behavior currently implemented by:

```text
TuringStoryWindowBundleController.acquireChapter01DadCinematicContext()
Chapter01DadWindowRouteBuilder.make(...)
Chapter01DadWindowCoordinator.followPath(...)
Chapter01DadWindowCoordinator.playTurn(...)
Chapter01DadRuntimeFactory.installWorldPose(...)
```

If these symbols are generalized, leave Chapter 1 behind an adapter and preserve
its behavior. Do not use a cached Chapter 1 yaw. The player may have moved the
window to another wall. Rebuild the route and character heading from the current
committed window transform every time Chapter 2 starts or Continue reconstructs
the scene.

While the woman is centered, `update(deltaTime:)` must reassert the exact center
world position and `centerFacingWindowWorldOrientation`, as Dad does during his
centered states. Attack animation must never move the root away from the window.
The loop remains active throughout every early radio, ham, walkie, photo, filler,
PR, Foundation, Qwen, decoder, and generated-playback operation. Completing one
attack cycle does not advance the chapter and does not unload the woman.

The current controller exposes completion-owned scripted turns but no generic
completion-owned presentation attack. Add a narrowly scoped API such as:

```swift
func playScriptedPresentationClip(
    clipID: String,
    token: UUID,
    completion: @escaping @MainActor (UUID, Result<Void, Error>) -> Void
) throws
```

It must resolve the exact prepared clip, set the existing scripted completion
observer, play once with ignored locomotion and the normal visual runtime override,
and return completion only for the matching clip/token. It must not call
`startAttackIfPossible()`, install an attack window, choose a random attack, play
combat SFX, or mutate combat state. After each completion, reassert the center
pose before starting the next clip.

When Crank Radio 02 finishes:

```text
record exitRequested on the active generation
-> if an attack is active, let that exact attack complete
-> if the 20-second idle dwell is active, leave at its deterministic dwell boundary
-> do not start another attack cycle
-> restore idle_01 at the exact center pose
-> begin pr-rich-women-window.mp3 as the authored Rich cue
-> play turn_right_90 to actual completion using externalExactWorldPose ownership
-> commit the exact exit-walk world orientation once
-> validate rendered heading against the live center-to-exit route
-> submit unstable_walk_01 from center to exit through ScriptedAnchorPathFollower
-> no Foundation, Qwen, decoder, filler, or generated Rich speech
-> await the exact Rich PR completion and the authored exit boundary
-> reach the exact exit anchor and hide the spouse source
-> cancel the window presentation generation and release attack-only presentation state
-> remove the window IBL receiver from the spouse source
-> reparent the hidden source to a Chapter 2 neutral staging root while preserving
   its world transform
-> only then release the window-exterior IBL/cinematic lease
-> retain the same spouse source entity and resource set in the staging root
-> acquire the door exterior/portal-intro ownership
-> reparent/reposition that same runtime to door-local zombie_a1
-> upgrade the lease from windowPresentation to portalIntro
```

The neutral staging root is lightweight and chapter-owned. It exists only to keep
the one spouse hierarchy alive while window ownership is released and door
ownership is acquired. It may not clone, reload, prepare, or render another spouse.

The window tier has no room-side collision or damage authority. Combat components
are installed only when the same source runtime upgrades to `.combat`.

### 16.1 Single-instance and TTS memory boundary

The implementation must satisfy all of these simultaneously:

```text
spouse USDZ imports for one Chapter 2 run:                 1
authoritative spouse skinned runtimes:                     1
unique spouse mesh/material/texture resource sets:         1
window and battle heavyweight runtimes alive together:     0
window-phase collision/hit/combat audio owners:             0
battle portal/environment preloaded during early TTS:       false
```

Do not unload the visible woman merely to make a TTS point fit. Instead, keep the
window tier deliberately narrow and release every Turing run's Qwen request state,
CPU codebooks, decoder PCM, transient WAVs, and Foundation session at its normal
completion boundary. Record process footprint and MLX active/cache memory before
and after every early device flow and before upgrading the woman to combat.

Each point may keep exactly two Fresh instances only until that point's submitted
queue is exhausted. After its actual final playback/route completion, release the
run-scoped Fresh pool, decoder session tensors, generated files, and prompt archive
payload before arming the next device. Do not prewarm the battle tier or retain
multiple completed points' clone sessions while the woman remains in the window.

The normal Battle01 mirror pattern may not trigger a second USDZ import or prepare
a second independent spouse skeleton/runtime. Prefer a single-source portal
clipping/stencil transition. If the existing renderer requires a transient mirror,
it must share the already loaded mesh/material/texture resources and source
animation clock, carry no independently prepared clips or skeleton state, and be
destroyed at the reveal threshold. If those resource-sharing assertions cannot be
proved, the mirror is rejected and Chapter 2 must use the single-source transition.

## 17. Woman battle lifecycle

Reuse Battle01's scripted-intro-to-Horde-runtime adapter with the `spouse`
character. Do not start Horde mode, copy wave state, score, replacement spawning,
or Horde music.

```text
full door exterior lease acquired
-> same chapter spouse source is already at zombie_a1, hidden from room, combat disabled
-> install the minimal portal presentation described in section 16.1
-> source idles five seconds
-> turn_right_90 actual completion; commit +90 yaw
-> turn_right_90 actual completion; commit +180 yaw
-> unstable_walk_01 along zombie_a1 -> zombie_a2 -> zombie_a3
-> player may open the door as soon as spouse loads
-> if closed at A3, idle while real door-open animation and SFX complete
-> source crosses reveal threshold
-> room source revealed with automatic passthrough lighting
-> transient portal presentation remains briefly across the aperture
-> transient portal presentation releases
-> activate existing spouse follow/attack/hit/damage/death runtime
```

The room-side source must not inherit the exterior dome IBL. Only portal-visible
presentation receives portal lighting while it is inside the exterior world.

Use the existing `spouse.character.json` combat animations and SFX. This handoff
does not redefine player lethality, enemy hit capacity, punch randomness, or a
battle soundtrack because the supplied Chapter 2 script does not specify them.
Use the current Story Battle01 defaults through the shared adapter. Do not silently
copy Chapter 1 Dad's time-based damage clock or ten-hit player death policy.

The Rich battle line is fixed PR only. Play `pr-rich-women-battle.mp3` at the
authored portal/combat cue. Do not start Foundation, Qwen, decoding, filler, or a
generated follow-up while the combat-tier spouse runtime is resident. The PR is
room-global and does not own battle progression.

Battle release:

```text
death animation actual completion
-> finish any active/queued Rich battle PR; there is no generated line
-> remove full skinned spouse body after the current Battle01 corpse hold
-> stop spouse presence/walk/attack/death handles
-> clear collision and hit detector
-> drain enemy runtime registry
-> close door with real animation and SFX
-> release full exterior lease and portal resources
-> emit Chapter02WomanBattleReleasedEvent
-> persist womanBattleCompleted
-> arm post-battle Ham Receiver Play
```

The release drains the same `Chapter02WomanRuntimeLease` created at chapter root.
There is no separate window runtime to drain and no cached second battle import.

No post-battle TTS may acquire the decoder before the heavy battle-release event.

## 18. Catalog and title-card changes

Modify:

```text
TuringEpisodeCatalog.swift
TuringStoryEpisodePickerView.swift / strip artwork catalog
StoryTitleCardCatalog.swift
StoryTitleCardDescriptor.swift if its ID enum is closed
StoryTitleCardTransitionCoordinator.swift
PlagueImmersiveCoordinator.swift
```

The authored Chapter 2 strip is now present at the repository root:

```text
source:       episode-chapter-2-button.png
dimensions:   2953 x 303 pixels
format:       PNG with alpha
SHA-256:      9fa81acbb97b2da438b2907691e7831403b2df49124cbfc98a25258007bf80fd
baked label:  CHAPTER 2 - THE NIGHT THE LIGHTS WENT OUT
```

Install it byte-for-byte at:

```text
Gravitas Plague/Gravitas Plague/Assets.xcassets/
  episode-chapter-2-button.imageset/
    Contents.json
    episode-chapter-2-button.png
```

Use the same universal 1x asset-catalog contract as the existing Prologue and
Chapter 1 strips. Do not resize, recompress, redraw, crop, tint, or recreate its
baked text in SwiftUI. The source already matches the established strip width and
height contract.

```json
{
  "images" : [
    {
      "filename" : "episode-chapter-2-button.png",
      "idiom" : "universal",
      "scale" : "1x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
```

Extend the existing artwork catalog rather than special-casing the picker view:

```swift
enum TuringEpisodePickerArtwork {
    static let plate = "episode-plate-alpha"
    static let continueStrip = "episode-continue-button"
    static let prologueStrip = "episode-prologue-button"
    static let chapter01Strip = "episode-chapter-1-button"
    static let chapter02Strip = "episode-chapter-2-button"
}

struct TuringEpisodeStripArtwork: Sendable, Equatable {
    let assetName: String
    let pixelSize: CGSize

    static let continueStrip = TuringEpisodeStripArtwork(
        assetName: TuringEpisodePickerArtwork.continueStrip,
        pixelSize: CGSize(width: 2953, height: 307)
    )

    static let prologueStrip = TuringEpisodeStripArtwork(
        assetName: TuringEpisodePickerArtwork.prologueStrip,
        pixelSize: CGSize(width: 2953, height: 303)
    )

    static let chapter01Strip = TuringEpisodeStripArtwork(
        assetName: TuringEpisodePickerArtwork.chapter01Strip,
        pixelSize: CGSize(width: 2953, height: 303)
    )

    static let chapter02Strip = TuringEpisodeStripArtwork(
        assetName: TuringEpisodePickerArtwork.chapter02Strip,
        pixelSize: CGSize(width: 2953, height: 303)
    )
}
```

Add the unlocked production descriptor as the third episode row:

```swift
TuringEpisodeDescriptor(
    id: .chapter02,
    title: "Chapter 2",
    subtitle: "The Night the Lights Went Out",
    scriptResourcePath: nil,
    availability: .unlocked,
    stripArtwork: .chapter02Strip,
    contentRevision: "chapter02.v1"
)
```

`TuringStoryEpisodePickerView` must continue rendering every catalog entry through
the existing `TuringEpisodeArtworkStrip`. Do not add a Chapter 2-only button or a
parallel text row. Accessibility exposes the descriptor title and subtitle even
though the visible title remains baked into the authored strip.

### 18.1 Exact Chapter 2 title card

Add `.chapter02` to `StoryTitleCardID` and add this exact descriptor to
`StoryTitleCardCatalog`:

```swift
static let chapter02 = StoryTitleCardDescriptor(
    id: .chapter02,
    title: "Chapter 2",
    subtitle: "The Night the Lights Went Out",
    fadeToBlackSeconds: .milliseconds(750),
    holdSeconds: .milliseconds(7_500),
    fadeFromBlackSeconds: .milliseconds(750)
)
```

The card is two procedural world-text lines using the existing title-card font,
layout, depth, height, and no-X-pitch presentation:

```text
Chapter 2
The Night the Lights Went Out
```

Do not combine the strings into one line, use `Chapter 02`, use the Chapter 2
button bitmap as the title card, or reuse the Chapter 1 `Dad?` descriptor.

Update `StoryTitleCardCatalog.descriptor(for:)`:

```swift
case .chapter02:
    return chapter02
```

Every route into Chapter 2 must use that descriptor:

```text
Episode picker Chapter 2 selection:
  source:       episodePickerStart
  descriptor:   StoryTitleCardCatalog.chapter02
  destination:  start(chapter02)
  music:        playThroughCard

Continue targeting any Chapter 2 checkpoint:
  source:       episodePickerContinue
  descriptor:   StoryTitleCardCatalog.chapter02
  destination:  continueFrom(the exact Chapter 2 checkpoint)
  music:        playThroughCard

Natural Chapter 1 completion:
  source:       naturalEpisodeBoundary
  descriptor:   StoryTitleCardCatalog.chapter02
  destination:  advance(from: chapter01, to: chapter02)
  music:        playThroughCard
```

The transition coordinator owns one uninterrupted sequence:

```text
claim/receive the Story transition lease
-> fade fully to black
-> show Chapter 2 / The Night the Lights Went Out
-> hold for 7.5 seconds
-> remove title glyphs
-> commit the Chapter 2 route while still fully black
-> reconstruct only Chapter 2 logical state; do not rescan or move props
-> fade completely back from black
-> stop menu/prior-transition music only after opacity reaches zero
-> expose Chapter 2 interaction and presentation
```

Chapter 2 entities may preload while the view remains fully black, but its first
animation, PR, generated speech, icon, or other authored visible/audible action
must not begin before the fade from black actually completes.

Natural transition:

```text
Chapter 1 final actual completion
-> persist Chapter 1 boundary
-> Chapter 2 title card
-> title card fades out
-> begin Chapter 2 root in existing room
```

Chapter 2 final broadcast actual completion:

```text
final PromptVoice generated segment actually completes
-> closing bumper actually completes
-> persist Chapter 2 complete
-> no next unlocked content
-> `Gravitas Plague` end-of-available-content title card
```

Main-menu or prior chapter music follows the existing title-card contract and
stops only when the title card's black fade has completely cleared.

## 19. Files to add

```text
Story/Chapter/Chapter02/Chapter02Coordinator.swift
Story/Chapter/Chapter02/Chapter02State.swift
Story/Chapter/Chapter02/Chapter02ProgressStore.swift
Story/Chapter/Chapter02/Chapter02WindowWomanCoordinator.swift
Story/Chapter/Chapter02/Chapter02WindowWomanRuntime.swift
Story/Chapter/Chapter02/Chapter02WomanBattleCoordinator.swift
Story/Chapter/Chapter02/Chapter02SurfaceSequenceCoordinator.swift

Gravitas Plague/Gravitas Plague/Assets.xcassets/
  episode-chapter-2-button.imageset/Contents.json
  episode-chapter-2-button.imageset/episode-chapter-2-button.png

TuringResources/Turing/Characters/dad.chapter02.outbreakNight.json
TuringResources/Turing/Characters/rich.chapter02.outbreakNight.json
TuringResources/Turing/Characters/big_mike.chapter02.outbreakNight.json
TuringResources/Turing/Characters/rich.chapter02.present.json
TuringResources/Turing/Characters/cateye81.chapter02.present.json

TuringResources/Turing/Prompts/voicePrompt_chapter02CharacterIntent.txt
TuringResources/Turing/Prompts/voicePrompt_chapter02Broadcaster.txt
TuringResources/Turing/Prompts/voicePrompt_chapter02CatEye81.txt

14 ScriptPoint JSON resources listed in section 14
14 prerecording descriptor JSON resources
12 VoicePrompt descriptor JSON resources

TuringResources/Turing/Audio/Prerecordings/Chapter02/ (14 supplied PR files)
TuringResources/Turing/Audio/CrankRadio/gravitas-opening-jingle.mp3
TuringResources/Turing/Audio/CrankRadio/gravitas-closing-bumper.mp3

TuringResources/Turing/Voices/Cloned/Dad/BaseClone/dad_base_clone_v1.qwenclone/...
Scripts/package_dad_authoring_inputs.sh
Scripts/precompute_dad_clone_artifacts.sh
```

## 20. Files to modify

```text
TuringEpisodeCatalog.swift
StoryTitleCardCatalog.swift
TuringStorySurfaceFlowBinding.swift
TuringRichVoiceIdentity.swift (or rename to a general identities file)
TuringResources/Turing/Config/character-runtimes.json
TuringResources/Turing/ScriptPoints/catalog.json
PlagueImmersiveCoordinator.swift
TuringFlowCatalogValidator.swift
JockRetargetTestController.swift (completion-owned presentation clip API)
TuringStoryWindowBundleController.swift (only if extracting a generic Dad-parity context API)
project resource membership / Copy Bundle Resources as required
```

Prefer adding a `TuringCharacterVoiceIdentity.swift` file rather than continuing
to overload a Rich-named file with every character identity, but do not move the
existing identities unless tests prove no bundle/resource regression.

## 21. Failure and cancellation

```text
Foundation failure before PR:
  stop exact filler handle, do not play PR, restore the same Play action

PR-only window/battle cue failure:
  stop the exact authored handle, do not invoke Foundation/Qwen as fallback,
  retain the last durable checkpoint, and fail the cinematic deterministically

Qwen/decode failure after PR starts:
  allow active PR to finish, stop filler/static according to the surface contract,
  report Device Operation Failed, and restore the appropriate stable action

Window load/animation failure:
  cancel tokens, release the one Chapter02WomanRuntimeLease and window lease,
  retain the last durable checkpoint

Battle load failure:
  remove transient portal presentation, release the single source runtime,
  close/unload door, retain womanBattlePending

Cancellation or episode switch:
  invalidate run ID, stop all chapter-owned audio, release the one woman runtime,
  clear callbacks, and leave the established room transforms untouched

App termination:
  rely only on the last atomically committed logical checkpoint
```

No failure path may mark an unplayed device complete.

## 22. Required tests

### Catalog and profile tests

```text
testChapter02IsThirdCatalogEntryAndUsesChapter02Identity
testChapter02CatalogEntryUsesChapter02StripArtwork
testChapter02StripAssetHasAuthored2953By303PixelDimensions
testChapter02StripSourceChecksumMatchesAudit
testChapter02PickerRowUsesExistingArtworkStripComponent
testChapter02PickerAccessibilityUsesDescriptorTitleAndSubtitle
testChapter02TitleCardUsesTheNightTheLightsWentOut
testChapter02TitleCardUsesExactTwoLineText
testChapter02PickerStartUsesChapter02TitleCard
testChapter02ContinueUsesChapter02TitleCard
testChapter01NaturalBoundaryAdvancesThroughChapter02TitleCard
testChapter02TitleCardRouteCommitsWhileFullyBlack
testChapter02AuthoredActivityWaitsForFadeFromBlackCompletion
testChapter02MenuMusicStopsOnlyAfterFadeFromBlackCompletion
testDadRuntimeAndCloneProfileValidate
testDadReferenceFastSourceChecksumMatchesAudit
testDadCloneInstallationRequiresAuthorSuppliedExactTranscript
testDadNormalizedReferenceIsFloat32Mono24000Hz
testDadVariantUsesFullICLAndContainsReferenceCodesAndTextTokens
testDadArtifactManifestMatchesReferenceAudioAndTranscriptHashes
testDadVoiceRegistryRevisionMatchesFinalizedProfileTree
testDadRuntimeAllowsOnlyHamReceiverSpatial
testDadNativeLoaderResolvesDefaultVariantWithoutFallback
testDadMacAuthoringSmokeIsNonSilent
testFinalGravitasPSASourceChecksumMatchesAudit
testDadOutbreakProfileContainsNoFutureKnowledge
testRichAndMikePastProfilesContainNoPresentKnowledge
testPresentRichProfileDoesNotLeakWomanOutcomeBeforeIntent
testCatEyeProfileLabelsRevelationAsBelief
testBroadcasterUsesExistingUnmodifiedProfile
```

### Prompt tests

```text
testEveryChapter02PRTranscriptMatchesAuthoredTextExactly
testEveryActiveChapter02PromptVoiceIntentMatchesAuthoredTextExactly
testCharacterPromptOrdersProfileThenPRThenIntent
testBroadcasterPromptNeverAddressesRich
testPromptContainsNoConversationHistoryOrCheckpointState
testPastAndPresentProfileSelectionPerDescriptor
testOversizedOutputUsesDeterministicSentenceClauseSplitting
testNoSecondFoundationRepairCall
testPRDoesNotBeginBeforeFoundationSuccess
testWindowRecognitionIsPrerecordingOnly
testWomanBattleRichCueIsPrerecordingOnly
testPROnlyCuesEmitNoFoundationQwenDecoderOrGeneratedPlaybackEvents
testFinalClosingBumperWaitsForActualLastPromptVoiceCompletion
testFinalCheckpointWaitsForActualClosingBumperCompletion
```

### Progression and continuation tests

```text
testDadHamRunsDadRichDadWithNoIntermediateIcon
testWalkieRunsMikeRichMikeWithNoIntermediateIcon
testEachTerminalActualCompletionCommitsOnce
testContinueDoesNotRescanOrMoveAnyPlacedProp
testWindowWomanRebuildsFromCurrentWindowTransform
testUnplayedPointNeverPersistsCompleted
testFinalPSACompletionShowsEndTitleCard
```

### Window and battle tests

```text
testWindowWomanUsesFreshCommittedWindowTransformAndDadRouteAnchors
testWindowWomanSpawnsHiddenAndRevealsAfterEntryLocomotionStarts
testWindowWomanWalksEntryToCenterThenTurnsLeftLikeDad
testWindowWomanCenteredIdleDwellIsExactly20Seconds
testWindowIdleClipLoopsAcrossThe20SecondDwell
testEveryWindowCyclePlaysAllFourSpouseAttackClipsInAuthoredOrder
testEveryPresentationAttackAdvancesOnlyFromMatchingActualCompletion
testWindowPresentationLoopContinuesAcrossEveryEarlyDeviceFlow
testWindowAttackClipsNeverMoveTheAuthoritativeCenterPose
testWindowWomanHasNoCombatAuthority
testWindowExitRequestDoesNotStartAnotherPresentationCycle
testWindowWomanTurnsRightThenWalksCenterToExitLikeDad
testWindowWomanHidesOnlyAfterReachingTheExactExitAnchor
testWindowRuntimeTransfersToPortalWithoutSecondUSDZImport
testOneAuthoritativeSpouseRuntimeAcrossWindowAndBattle
testOneSpouseMeshMaterialTextureResourceSetAcrossChapter
testPortalPresentationHasNoIndependentSkeletonClipsCollisionAudioOrDamageAuthority
testRoomSourceDoesNotReceivePortalIBL
testDoorOpenCapabilityAppearsWhenBattleEnemyLoads
testSpouseUsesExistingCombatAnimationsAndSFX
testBattleReleaseDrainsEnemyMirrorAudioAndPortal
testPostBattleTTSWaitsForHeavyReleaseEvent
testEarlyTuringRunsReleaseTransientMemoryWhileWindowWomanRemainsVisible
```

### Device acceptance

On Vision Pro, run from a clean Chapter 2 root and from every continuation point.
Verify:

```text
no room rescan
episode picker shows the authored Chapter 2 strip as the third episode row
Chapter 2 strip is selectable and starts Chapter 2 rather than Chapter 1
picker start, Continue, and natural Chapter 1 completion all display `Chapter 2`
title-card subtitle displays `The Night the Lights Went Out`
Chapter 2 does not expose an icon, animation, or audio before black fully fades out
window woman remains correctly oriented after moving the window to another wall
woman walks in, turns toward the window, and holds the exact live center pose like Dad
20-second idle / all four attacks / repeat remains visible through the early device sequence
all PromptVoice PRs wait for Foundation; the two documented PR-only cues do not invoke it
TTS computes during PR and segment 0 starts without a wait-for-all barrier
Dad voice is clearly distinct and stable across all Dad generated segments
past Rich/Mike/Dad never mention later events
present Rich and CatEye retain current knowledge
radio/walkie/ham/photo routing and fillers match existing surfaces
woman turns and walks out through Dad's exit route, then the same runtime transfers to the door
woman appears at zombie_a1 and performs the shared battle portal intro before combat
single woman USDZ import/resource set and no duplicate combat authority
combat and SFX match the shared Story enemy runtime
all heavy resources release before post-battle Ham generation
final opening jingle, PSA, generated follow-up, and closing bumper complete in order
end title card appears once
no EXC_RESOURCE, Metal assertion, stale audio, or orphan icon
```

## 23. Static rejection checks

Reject the implementation if any of these are present:

```text
Chapter 2 stored as chapter03
Chapter 2 state stored in Chapter01ProgressStore
missing or renamed episode-chapter-2-button asset
Chapter 2 catalog entry using Chapter 1 or Prologue strip artwork
Chapter 2-specific picker view/button outside the catalog-driven strip list
SwiftUI text drawn over or in place of the authored Chapter 2 strip label
runtime resize, recompression, crop, tint, or mutation of the authored strip
Chapter 2 route using the Chapter 1, Prologue, or end-of-content title descriptor
Chapter 2 title rendered as `Chapter 02` or as one combined bitmap/text line
Chapter 2 start or Continue bypassing StoryTitleCardTransitionCoordinator
Chapter 2 authored animation, icon, PR, or generated audio starting before fade completion
new room scan on Chapter 2 start or Continue
more than one spouse USDZ import in a Chapter 2 run
separate heavyweight window and battle spouse runtimes
independent portal-mirror mesh/material/texture/skeleton or clip preparation
cached world yaw reused after window movement
woman installed directly at center without Dad's entry walk and left turn
idle dwell derived from the 14.125-second clip instead of the authored 20 seconds
window cycle that omits any configured spouse attack clip
random attack selection that fails to guarantee all four attacks per cycle
timer-estimated completion for a non-looping presentation attack
window exit without Dad's right turn and center-to-exit path
window spouse with hit/damage authority
portal mirror with collision, audio, health, or attack authority
room spouse with portal IBL receiver
PromptVoice-backed PR playback before Foundation success
Foundation, Qwen, decoder, filler, or generated playback for either Rich PR-only cue
PromptVoice wait-for-all generated playback gate
conversation history in any Foundation prompt
future knowledge in Dad/Rich/Mike outbreak-night profiles
new Broadcaster private-listener relationship
guessed Dad reference transcript
Dad clone generated with x-vector-only mode
Dad runtime reference-audio encoding or prerecorded-dialogue fallback
Dad-specific Qwen sampling, decoder, renderer, or playback queue
Dad registry/profile/variant identity mismatch
closing bumper before actual final PromptVoice playback completion
second Foundation repair call
Chapter 1 behavior changed without parity tests
```

## 24. Completion report required from Codex

The implementation report must include:

```text
canonical episode ID and catalog position
files added and modified
exact ScriptPoint / PR / VoicePrompt IDs installed
exact supplied audio path/duration/checksum-to-descriptor mapping
Dad reference asset, author-supplied exact transcript source, clone variant, checksum result, and smoke result
rendered raw Foundation input for one Dad, past Rich, past Big Mike, present Rich,
CatEye81, and Broadcaster point
proof every PromptVoice PR waited for Foundation and both PR-only cues bypassed it
proof generated segment 0 played before all later segments completed
window transform/orientation proof on two differently oriented walls
spouse USDZ import count, authoritative runtime count, and unique resource-set count
portal source/presentation authority and resource-sharing proof
battle release report
final generated-completion -> closing-bumper-completion event trace
checkpoint/Continue matrix result
Chapter 1 regression result
Vision Pro end-to-end result
remaining author input, if any
```

Do not report this chapter complete until the supplied Dad reference audio is
packaged with its author-supplied exact reference transcript, all fixed PR audio
files are installed with manual transcripts matching section 13, and the Vision
Pro run reaches the final title card without a resource failure. The final PSA PR,
opening jingle, and closing bumper are present and must pass their audited checksum
validation.
