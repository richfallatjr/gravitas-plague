# Chapter 2 Codex Completion Report

## Status

- Canonical episode ID: `chapter02`
- Catalog position: third production episode
- Picker title: `Chapter 2`
- Picker/title-card subtitle: `The Night the Lights Went Out`
- Production app build: passed for arm64 visionOS Simulator
- Vision Pro acceptance: not run
- Dad clone authoring: complete; device voice audition remains

## Runtime Flow

The implemented order is:

```text
Chapter 1 boundary
-> Chapter 2 title card
-> preload one hidden spouse runtime using the current adjusted window
-> entry walk, left turn, 20-second idle, four authored attacks, repeat
-> Crank Missing Persons
-> Dad / Rich / Dad ham sequence
-> Big Mike / Rich / Big Mike walkie sequence
-> Dad photo
-> Crank grid-failure broadcast
-> same spouse runtime exits the window and transfers to the door
-> Rich window PR-only cue
-> Battle01-style spouse intro and combat
-> Rich battle PR-only cue
-> complete spouse, mirror, audio, door, and portal release
-> Rich / CatEye81 post-battle ham sequence
-> Gravitas opening jingle
-> final PSA PR and PromptVoice
-> closing bumper actual completion
-> persist Chapter 2 complete
-> Gravitas Plague end-of-content card
```

Chapter 2 start, Continue, and the Chapter 1 natural boundary reuse the established room and do not rescan or replace placed props.

## ScriptPoint, PR, PromptVoice, and Audio Mapping

| ScriptPoint | PR descriptor | PromptVoice | Installed audio | Duration | SHA-256 |
| --- | --- | --- | --- | ---: | --- |
| `chapter02.crankRadio.broadcaster.missingPersons.001` | same ID | `chapter02.broadcaster.missingPersons.promptVoice.001` | `pr-broadcast-missing-persons.mp3` | 49.611 s | `cdafad312e57dac890327d8f3b1bfcf7b237503c5784a47a992a85efc9b245ff` |
| `chapter02.hamReceiver.dad.script01` | `chapter02.hamReceiver.dad.script01.001` | `chapter02.dad.hamReceiver.script01.promptVoice.001` | `pr-dad-electricity-went-out.mp3` | 31.713 s | `0fbdc3ddcc99e60232ae0b3200a1785d796df2eebbff843be2eca79bc6cc2cd7` |
| `chapter02.hamReceiver.rich.script02` | `chapter02.hamReceiver.rich.script02.001` | `chapter02.rich.hamReceiver.script02.promptVoice.001` | `pr-rich-ham-receiver-dad.mp3` | 25.104 s | `d9970a93d54ebdf704db4c624f565f018a61ffd32a79bbd16453606887f43a1e` |
| `chapter02.hamReceiver.dad.script03` | `chapter02.hamReceiver.dad.script03.001` | `chapter02.dad.hamReceiver.script03.promptVoice.001` | `pr-dad-ham-receiver-do-not-come-looking.mp3` | 32.444 s | `43d7f1e2b3bf3c615352d8e54b6e77059b9f6210903bf12c327069ab8534ceeb` |
| `chapter02.walkie.bigMike.script01` | `chapter02.walkie.bigMike.script01.001` | `chapter02.bigMike.walkie.script01.promptVoice.001` | `pr-big-mike-nukes.mp3` | 27.402 s | `cecfcc61142bbe11e5c842607e22f9b9ef3a111f94047f6610163186f597286e` |
| `chapter02.walkie.rich.script02` | `chapter02.walkie.rich.script02.001` | `chapter02.rich.walkie.script02.promptVoice.001` | `pr-rich-walkie-obey.mp3` | 26.514 s | `110190c07cc3b13530545afe9d0ca2ad28b6d3cad0570379dc1b7301cb3ec048` |
| `chapter02.walkie.bigMike.script03` | `chapter02.walkie.bigMike.script03.001` | `chapter02.bigMike.walkie.script03.promptVoice.001` | `pr-big-mike-payback-for-dad.mp3` | 28.552 s | `27f5124c2eb34944d4f1885edbb5ce0a150a038cc201d9674e9c560917287b4b` |
| `chapter02.dadFrame.rich.dadDisappeared.001` | same ID | `chapter02.rich.dadFrame.dadDisappeared.promptVoice.001` | `pr-rich-dad-photo-dad-disappeared.mp3` | 39.732 s | `3f6182bf53802eca2aca23258a3f74a8eba63fb753fff4ded8f92fcc23dfe701` |
| `chapter02.crankRadio.broadcaster.gridFailure.002` | same ID | `chapter02.broadcaster.gridFailure.promptVoice.002` | `pr-broadcast-night-lights-went-out.mp3` | 41.874 s | `e5b63f267faea8fbc2321f079c20984832979a0d937d21f6db581140d46701fd` |
| `chapter02.room.rich.windowRecognition.001` | same ID | none, PR only | `pr-rich-women-window.mp3` | 31.688 s | `7efb737bddc3375a8f08a89c45556796e86a4b3e90736e39b7548480d89cadb0` |
| `chapter02.room.rich.womanBattle.001` | same ID | none, PR only | `pr-rich-women-battle.mp3` | 26.659 s | `6d24ecacf7b7c6ca4f6b61f13d543441b7b86a2abc43104497a81d7815f8227f` |
| `chapter02.hamReceiver.rich.revelation.001` | same ID | `chapter02.rich.hamReceiver.revelation.promptVoice.001` | `pr-rich-ham-receiever-what-do-you-believe.mp3` | 36.389 s | `9bcd5ac1af18954868db7e39de4ce0fb6dab6befe590aba367fd79525db746bd` |
| `chapter02.hamReceiver.cateye81.revelation.002` | same ID | `chapter02.cateye81.hamReceiver.revelation.promptVoice.002` | `pr-cat-eye-81-what-we-chose.mp3` | 53.499 s | `38f9fa4cddb0a725df322eff4785385f0fc4b2fb289879f26ebdf8fb60c730d7` |
| `chapter02.crankRadio.broadcaster.gravitasPSA.003` | same ID | `chapter02.broadcaster.gravitasPSA.promptVoice.003` | `pr-broadcast-psa-propoganda.mp3` | 56.268 s | `550ab0f608e5c34a4b660cd4687640c1b6bc28aeb7c3bbaec3d41703d3a7e9b2` |

Final broadcast cues:

| Role | Resource | Duration | SHA-256 |
| --- | --- | ---: | --- |
| opening jingle | `Turing/Audio/CrankRadio/gravitas-opening-jingle.mp3` | 30.041 s | `539b43c5245ee0e3da17f125d1f50a3a41103f42cb89180e84b517a703e7c8af` |
| closing bumper | `Turing/Audio/CrankRadio/gravitas-closing-bumper.mp3` | 12.000 s | `83649c3a201283173580e050ccc25af14f61c1340df5e665d24a3c7a9b2093c9` |

All installed files match the audited source checksums byte-for-byte.

## Prompt and Profile Contract

Installed prompt templates:

```text
voicePrompt_chapter02CharacterIntent.txt
voicePrompt_chapter02Broadcaster.txt
voicePrompt_chapter02CatEye81.txt
```

All three order the complete character profile, authored PR transcript, then Story Intent. They add no conversation history, checkpoint state, prior generated dialogue, or Foundation repair call. Oversized generated segments use the existing deterministic sentence/clause splitter before Qwen.

Installed timeline-specific profiles:

```text
dad.chapter02.outbreakNight
rich.chapter02.outbreakNight
big_mike.chapter02.outbreakNight
rich.chapter02.present
cateye81.chapter02.present
```

The existing Broadcaster profile remains unchanged.

## Woman Runtime and Battle

- `spouse_biped.usdz` import calls per run: one.
- The window and battle share one `JockRetargetTestController`, skeleton, animation set, and authoritative source.
- Window presentation uses the current adjusted window transform and the Chapter 1 Dad route.
- Window combat, collision, damage, and character audio authority are disabled.
- The centered loop is exactly 20 seconds of `idle_01`, then `charged-slash-left`, `charged-slash-right`, `left_hook_01`, and `right_hook_01` in order.
- Exit waits for the active idle boundary or active attack completion, turns right, follows the Dad exit route, hides at the exact exit anchor, and stages the same runtime.
- Door battle reacquires the full exterior only after staging and uses the Battle01 idle/turn/turn/path/reveal/exit thresholds.
- The player may open the door after the spouse runtime is loaded into the battle.
- The portal mirror has no collision, audio, health, or damage authority.
- Combat uses the existing Story Battle01 spouse policy; no Chapter-specific hit or music tuning was added.
- Death completion waits for the Rich battle PR, drains the enemy registry, closes/unloads the door portal, releases the heavy runtime, then arms post-battle TTS.

## Continuation and Title Cards

Durable checkpoints are stored atomically in `story.chapter02.progress.v1` with content revision `chapter02.v1`. Continue selects the newest compatible Prologue, Chapter 1, or Chapter 2 snapshot and restores only logical Story state. It does not rescan or move the established room.

Chapter 2 uses 0.75-second fade-to-black, 7.5-second hold, and 0.75-second fade-from-black. Woman presentation remains hidden until fade-from-black completes. Completing Chapter 2 presents the end-of-content `Gravitas Plague` card exactly once.

## Dad Clone Boundary

Verified source:

```text
/Users/richardfallat/Projects/dev/turing-native-qwen-cloner/dad-reference-fast.mp3
SHA-256: 0d3f766e61f9fd4bfad2e16a33b8020dc630201805f02214e36a4bc5e89f602b
```

The original MP3 is installed byte-for-byte in the Dad variant. The normalized reference is verified `pcm_f32le`, 24,000 Hz, mono. The profile scaffold, runtime identity, packaging script, and precompute script are installed.

Approved reference transcript:

```text
Rich, check the breaker, then listen to the motor. Cold air off the lake makes old wiring complain. Take your time, think it through, and call me back.
```

Full-ICL authoring completed with:

```text
mode: icl
xVectorOnlyMode: false
reference codes: [144, 16]
reference text tokens: [1, 40]
speaker embedding: [2048]
smoke peakAbs: 0.7194653153
smoke RMS: 0.1296415776
registry revision: sha256:7973e54973b811dcd0f6b665d45f7aec2cc4d1fef573d660d94cfd158dc9c27d
```

The profile, variant, and artifact checksum manifests validate. The Dad registry entry is enabled with no fallback. The remaining Dad-specific acceptance item is a Vision Pro render/decode/playback canary and authored listening approval of the generated voice.

## Verification

Passed:

```text
arm64 visionOS Simulator production build
git diff --check
all Chapter 2 JSON decoding through jq
all descriptor/PR/PromptVoice/audio cross-references
all 16 authored audio checksum checks
all 14 authored PR durations
Chapter 2 strip dimensions: 2953 x 303
Chapter 2 strip SHA-256: 9fa81acbb97b2da438b2907691e7831403b2df49124cbfc98a25258007bf80fd
static rejection scan
single spouse import source scan
```

Added focused coverage in `Chapter02ContractTests.swift` and extended the title-card catalog tests. The complete test target cannot currently compile under Xcode 27 because older unrelated test doubles use actor conformances against globally isolated protocols, including `ToolCallFoundationRunner`, `ControlledVoicePromptService`, `StubCharacterRenderer`, `HamReceiverPromptCapturingRunner`, and `StubStagedRenderSession`. Production compilation is unaffected.

No Vision Pro run was performed, so window orientation, animation appearance, audio balance, memory behavior, TTS playback, and battle acceptance remain device-verification items.
