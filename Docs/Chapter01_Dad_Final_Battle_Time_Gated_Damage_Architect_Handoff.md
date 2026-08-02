# Gravitas Plague - Chapter 01 Dad Final Battle

## Complete Architect Handoff: Portal Intro, Music-Timed Damage, and Five-Hit Player Death

**Repository:** `/Users/richardfallat/Projects/dev/gravitas-plague`  
**Status:** Architecture and implementation handoff  
**Implementation scope:** Chapter 01 final Dad attack after the three post-Robot device branches  
**Do not implement as:** a second Horde mode, a copy of Battle01, a new character runtime, or a Turing Flow

---

# 1. Product contract

The existing post-Robot sequence is ordered:

```text
Dad photo branch completes
-> walkie branch becomes playable
-> walkie branch completes
-> ham receiver branch becomes playable
-> ham terminal ScriptPoint completes
-> chapter01.preDadFinalBattle.ready is durable
-> Chapter01PreDadFinalBattleReadyEvent is emitted
```

The Dad battle starts from that typed event. Because the branches are sequential,
the ham terminal completion and "all three devices completed" are the same
production boundary. Do not add a second Ham-specific notification or poll the
three icon states.

The authored battle is:

```text
pre-Dad final-battle event accepted
-> atomically transfer Turing ownership to battle ownership
-> hide and disable Dad-frame, walkie, and ham interactions
-> load the full door exterior and Dad source/mirror runtime
-> place Dad at zombie_a1 looking away from the room
-> start idle_01
-> start dad-battle-01.mp3 immediately from that actual animation start
-> at soundtrack media time 30.000 seconds, enqueue pr-rich-dad-battle-01.mp3
-> leave the door-open icon available while Dad is in the portal approach
-> idle for 5 seconds
-> turn_right_90 to actual completion
-> turn_right_90 to actual completion
-> unstable_walk_01 along zombie_a1 -> zombie_a2 -> zombie_a3

If the player opened the door:
  -> Dad continues through the opening

If the door is still closed at zombie_a3:
  -> Dad stops in idle_01
  -> the real door opens with its authored animation and SFX
  -> Dad continues through the opening

Portal crossing:
  -> portal mirror copies the source root and joint pose
  -> room-side source becomes visible at the existing reveal threshold
  -> mirror remains until the existing exit threshold
  -> mirror is removed
  -> existing Dad follow/attack/damage/death behavior activates

Dad accepted damage:
  -> when exactly one accepted damage point remains before Dad dies
  -> enqueue pr-rich-dad-battle-02.mp3 exactly once
```

Both Rich cues are authored global/nonspatial playback. They play over the Dad
battle soundtrack and never block combat activation, pathing, attacks, incoming
damage, or death. They do not use Foundation, Qwen, promptVoice,
conversationVoice, filler, walkie effects, or walkie static.

Player damage is controlled by the actual soundtrack timeline:

```text
music elapsed [0.000, 60.000) seconds:
  Dad attacks normally
  attack animations continue
  attack contact feedback and authored enemy audio continue
  player damage is rejected before exposure or hit-budget mutation
  no damage tint
  no player-damage callback
  no confirmed-hit increment
  no latent damage accumulated for later

music elapsed >= 60.000 seconds:
  every distinct confirmed Dad attack contact counts as one player hit
  hits 1 through 4 produce normal player-damage feedback
  hit 5 kills the player
  the existing Chapter "You died" presentation runs once
  the Story episode picker returns after the black fade completes
```

Dad's incoming damage contract matches Story Grandma:

```text
base Horde hits-to-kill: random 3...5 from dad.character.json
Story accepted-hit capacity: base * 2, producing 6...10 accepted damage points
head-punch acceptance: existing storyGrandmaThreeX policy
every valid head punch: layered head-snap feedback
independent accepted damage/interrupt roll: 1/3
```

The only combat-strength difference requested here is outgoing player lethality:

```text
Story Grandma Battle01:
  cannot kill the player

Chapter 01 Dad final battle:
  cannot damage the player during the first soundtrack minute
  kills the player on the fifth confirmed post-minute contact
```

Do not multiply Dad's attack amount, globally edit Dad or Grandma attributes, or
change Horde behavior.

---

# 2. Audited production state

## 2.1 Trigger already exists

The trigger contract is in:

```text
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/
  Chapter01PreDadFinalBattleBoundary.swift
```

Existing types:

```swift
struct Chapter01PreDadFinalBattleReadyEvent: Sendable, Equatable {
    let chapterRunID: UUID
    let checkpointRevision: Int
    let sourceEventID: UUID
    let completedBranches: Set<Chapter01PostRobotBranch>
}

@MainActor
protocol Chapter01PreDadFinalBattleReadySink: AnyObject {
    func preDadFinalBattleBecameReady(
        _ event: Chapter01PreDadFinalBattleReadyEvent
    ) async
}
```

`Chapter01PreDadFinalBattleBoundary.publishIfNeeded` already verifies that all
three branch cases are present and deduplicates a checkpoint revision.

`Chapter01Coordinator.completePostRobotBranch` commits the progress snapshot
before publishing the event. The ham terminal ID is already:

```text
chapter01.hamReceiver.cateye81.script05
```

Do not move the event earlier than actual terminal ScriptPoint completion.

## 2.2 Current wiring drops the event

`PlagueImmersiveCoordinator` currently creates the boundary inline:

```swift
preDadFinalBattleBoundary: Chapter01PreDadFinalBattleBoundary(),
```

The object is retained by `Chapter01Coordinator`, but no sink is assigned. The
implementation must construct and retain the following objects explicitly:

```text
Chapter01PreDadFinalBattleBoundary
Chapter01DadFinalBattleActionRouter
Chapter01DadFinalBattleCoordinator
```

Then install:

```swift
preDadBoundary.sink = dadBattleActionRouter
```

## 2.3 Existing continuation boundary

`Chapter01Checkpoint.preDadFinalBattleReady` is already durable and already a
supported Continue destination. This milestone must not create another Chapter
checkpoint.

Live completion and Continue have different interaction owners:

```text
live ham terminal completion:
  an active Turing lease still exists
  -> transferActiveInteractionToBattle(...)

Continue at preDadFinalBattleReady:
  Chapter resume owns a storyTransition lease
  -> transferStoryTransitionToBattle(...)
```

Do not implement a catch-all "try transfer, then claim" fallback. Give the action
router two explicit entry points so ownership mistakes fail visibly.

For the final live branch, `Chapter01Coordinator.completePostRobotBranch` must
persist the all-branches-complete snapshot and publish/transfer to battle before
calling `postRobotInteractions.applyProgress`. The Ham surface is already busy
until route completion, so do not briefly apply the all-microphone snapshot.

For Continue at `preDadFinalBattleReady`, do not call
`postRobotInteractions.restore`, which would release the transition lease and
briefly expose all three microphones. Transfer the already-current
`storyTransition` lease directly to the Dad battle. Sparse room state is already
established and no conversation context is needed by this non-Turing battle.

## 2.4 Grandma infrastructure to reuse

Reuse the low production layers in:

```text
Battle/Battle01/Battle01EnemyFactory.swift
Battle/Battle01/Battle01StoryCombatAdapter.swift
Battle/Shared/ScriptedPortalEnemyIntroCoordinator.swift
Battle/Shared/ScriptedAnchorPathFollower.swift
Battle/Shared/StoryPortalEnemyRenderMirrorAdapter.swift
Battle/Shared/BattleEnemyRuntimeRegistry.swift
Battle/Shared/BattleRuntimeCleanupCoordinator.swift
Battle/Shared/JockIncomingPunchPolicy.swift
```

`ScriptedPortalEnemyIntroCoordinator` already provides:

```text
idle_01
two completion-owned turn_right_90 clips
unstable_walk_01 over the authored A1/A2/A3 3D path
source/mirror synchronization
portal reveal and exit thresholds
```

The implementation should make its remaining `Battle01...` data types generic
where required. Do not copy the coordinator into Chapter 01.

## 2.5 Dad runtime and assets already exist

Production assets and metadata:

```text
dad_biped.usdz
CharacterLibrary/Characters/dad.character.json
AnimationLibrary/Rigs/SourceRigs/dad_biped_9ddc45fe6105.source_rig.json
```

Dad exposes the required authored clips:

```text
idle_01
turn_right_90
unstable_walk_01
charged-slash-left
charged-slash-right
left_hook_01
right_hook_01
hit_light_left_01
hit_light_right_01
hit_medium_left_01
hit_medium_left_02
hit_medium_right_01
hit_medium_right_02
hit_hard_left_01
hit_hard_right_01
dead_fall_forward_01
dead_fall_backward_01
```

Dad has authored presence, damage, face-hit, and death audio in
`dad.character.json`. Use that descriptor. Do not substitute Grandma audio.

The Dad-window runtime is cinematic-only and configures `hitsToKill: 1`. It is
not the final-battle factory. The final battle must create a fresh Dad runtime
using the same generic Jock controller and the final-battle identity.

## 2.6 Music asset

The authored file currently exists at repository root:

```text
/Users/richardfallat/Projects/dev/gravitas-plague/dad-battle-01.mp3
```

Audited metadata:

```text
duration: 180.035917 seconds
size:     4,337,547 bytes
```

Install it once, byte-for-byte, at:

```text
Gravitas Plague/TuringResources/Turing/Audio/chapter01/dad-battle-01.mp3
```

Remove the root duplicate after the resource is installed. Do not transcode,
normalize, add a gain DSP, or create a second decoded copy.

## 2.7 Authored Rich battle prerecordings

The two authored Rich files currently exist at repository root:

```text
/Users/richardfallat/Projects/dev/gravitas-plague/pr-rich-dad-battle-01.mp3
/Users/richardfallat/Projects/dev/gravitas-plague/pr-rich-dad-battle-02.mp3
```

Audited metadata:

```text
pr-rich-dad-battle-01.mp3
  duration: 29.283250 seconds
  size:     504,098 bytes
  SHA-256:  9a1d1f641b2e405af0984bef8c6b38934f967d9eb020ab29cac115ac5b4eed73

pr-rich-dad-battle-02.mp3
  duration: 33.201625 seconds
  size:     566,792 bytes
  SHA-256:  168edb741acbf161eb6fd0fdf99fc8ed133e2a886c2308749489f8cafe374132
```

Install them byte-for-byte at:

```text
Gravitas Plague/TuringResources/Turing/Audio/prerecordings/
  pr-rich-dad-battle-01.mp3
  pr-rich-dad-battle-02.mp3
```

Add transcript-free prerecording descriptors:

```text
Gravitas Plague/TuringResources/Turing/Prerecordings/
  chapter01.room.rich.dadFinalBattle.musicThirtySeconds.001.json
  chapter01.room.rich.dadFinalBattle.oneDamageRemaining.001.json
```

Use `transcriptMode: "none"` and `transcript: ""`. These authored battle cues
do not seed an LLM, so do not invent transcripts and do not run speech-to-text.
Use `speaker: "rich"`, `voiceID: "rich_base_clone_v1"`, and
`voiceVariantID: null`. Set `voicePromptIntent` to
`"No generated continuation. Authored Chapter 01 Dad battle media only."`.

Exact descriptors:

```json
{
  "schemaVersion": 1,
  "prerecordingID": "chapter01.room.rich.dadFinalBattle.musicThirtySeconds.001",
  "speaker": "rich",
  "voiceID": "rich_base_clone_v1",
  "voiceVariantID": null,
  "audioFile": "pr-rich-dad-battle-01.mp3",
  "transcriptMode": "none",
  "transcript": "",
  "summary": "Authored Rich reaction exactly thirty seconds into the Dad battle soundtrack.",
  "voicePromptIntent": "No generated continuation. Authored Chapter 01 Dad battle media only.",
  "defaultEmotion": "authored in source media"
}
```

```json
{
  "schemaVersion": 1,
  "prerecordingID": "chapter01.room.rich.dadFinalBattle.oneDamageRemaining.001",
  "speaker": "rich",
  "voiceID": "rich_base_clone_v1",
  "voiceVariantID": null,
  "audioFile": "pr-rich-dad-battle-02.mp3",
  "transcriptMode": "none",
  "transcript": "",
  "summary": "Authored Rich reaction when Dad has one accepted damage point remaining.",
  "voicePromptIntent": "No generated continuation. Authored Chapter 01 Dad battle media only.",
  "defaultEmotion": "authored in source media"
}
```

---

# 3. New production ownership

Add:

```text
Story/Chapter/Chapter01/DadFinalBattle/
  Chapter01DadFinalBattleActionRouter.swift
  Chapter01DadFinalBattleCoordinator.swift
  Chapter01DadFinalBattleDefinition.swift
  Chapter01DadFinalBattleDefinitionStore.swift
  Chapter01DadBattleEnemyFactory.swift
  Chapter01DadBattleCombatAdapter.swift
  Chapter01DadBattleMusicController.swift
  Chapter01DadBattleDamageClock.swift
  StoryBattleRichPrerecordingQueue.swift
  Chapter01DadBattleEvents.swift
```

Add the resource:

```text
TuringResources/Turing/Battles/Chapter01DadFinalBattle/
  chapter01_dad_final_battle.json
```

Ownership is:

```text
Chapter01DadFinalBattleActionRouter
  exact-once trigger and lease transfer/claim

Chapter01DadFinalBattleCoordinator
  battle state machine and orchestration

Chapter01DadBattleEnemyFactory
  Dad identity, health policy, source, mirror, and registration

ScriptedPortalEnemyIntroCoordinator
  authored portal animation/path sequence

Chapter01DadBattleCombatAdapter
  target updates, incoming enemy death callbacks, outgoing damage policy

Chapter01DadBattleMusicController
  one-shot playback and authoritative media timeline

StoryBattleRichPrerecordingQueue
  global Rich battle cues, exact-once cue IDs, authored ordering, and actual
  playback-completion ownership

BattleRuntimeCleanupCoordinator
  Dad, mirror, portal, collision, animation, and audio teardown
```

Do not copy `Battle01RichPrerecordingController`. Generalize that existing
controller into `StoryBattleRichPrerecordingQueue`, retaining its global route
and Rich gain of `-5 dB`. The queue owns at most one active `AVAudioPlayer` and
one ordered pending cue. If cue 02 is requested while cue 01 is active, cue 02
waits for cue 01's actual delegate completion. It must never overlap, stop, or
replace cue 01.

The coordinator must not own Foundation, Qwen, Turing prompts, room scan,
placement, or any of the three completed device conversations.

---

# 4. Exact definition

Use a data-driven definition. The following fields are locked:

```json
{
  "schemaVersion": 1,
  "battleID": "chapter01.dadFinalBattle.001",
  "trigger": {
    "checkpoint": "chapter01.preDadFinalBattle.ready",
    "requiresAllPostRobotBranches": true,
    "terminalScriptPointID": "chapter01.hamReceiver.cateye81.script05"
  },
  "enemy": {
    "storyEnemyID": "chapter01_infected_dad",
    "characterID": "dad",
    "sourceAsset": "dad_biped.usdz",
    "anchorIDs": ["zombie_a1", "zombie_a2", "zombie_a3"],
    "idleClipID": "idle_01",
    "idleDurationSeconds": 5.0,
    "turnClipID": "turn_right_90",
    "turnCount": 2,
    "turnDegreesPerCompletion": 90.0,
    "walkClipID": "unstable_walk_01",
    "externalMotionDriven": true,
    "rootMotionEnabledDuringPath": false,
    "incomingPunchPolicy": "storyGrandmaThreeX",
    "storyAcceptedHitCapacityMultiplier": 2,
    "retainCorpseAfterDeath": false
  },
  "door": {
    "playerMayOpenDuringPortalApproach": true,
    "playerMayCloseDuringBattle": false,
    "autoOpenIfClosedAtLastAnchor": true,
    "waitInIdleAtLastAnchorWhileOpening": true,
    "lockAtLastAnchorAndDuringCrossing": true,
    "requireFullyOpenBeforeCrossing": true
  },
  "portalHandoff": {
    "reuseHordeRenderMirror": true,
    "sourceIsAnimationAuthority": true,
    "sourceIsCombatAuthority": true,
    "mirrorHasCollision": false,
    "mirrorHasAudio": false,
    "mirrorHasDamageAuthority": false,
    "revealThresholdPortalLocalZMeters": -0.3048,
    "exitThresholdPortalLocalZMeters": 0.45
  },
  "music": {
    "resourcePath": "Turing/Audio/chapter01/dad-battle-01.mp3",
    "loop": false,
    "gainDB": -15.0,
    "start": "actualInitialIdleAnimationStart",
    "damageEnableAtMediaTimeSeconds": 60.0,
    "damageRemainsEnabledAfterNaturalCompletion": true
  },
  "playerDamage": {
    "confirmedHitsToKillAfterEnable": 5,
    "preEnableDisposition": "feedbackOnlyNoDamage",
    "clock": "soundtrackMediaTime"
  },
  "richPrerecordedCues": [
    {
      "cueID": "dadBattleSongThirtySeconds",
      "prerecordingID": "chapter01.room.rich.dadFinalBattle.musicThirtySeconds.001",
      "trigger": "soundtrackMediaTime",
      "triggerMediaTimeSeconds": 30.0,
      "outputRoute": "roomGlobal",
      "gainDB": -5.0
    },
    {
      "cueID": "dadOneDamageRemaining",
      "prerecordingID": "chapter01.room.rich.dadFinalBattle.oneDamageRemaining.001",
      "trigger": "acceptedDamageRemainingEqualsOneNonlethal",
      "outputRoute": "roomGlobal",
      "gainDB": -5.0
    }
  ],
  "richPrerecordedCuePolicy": {
    "ordered": true,
    "maximumActivePlayers": 1,
    "blocksCombat": false,
    "usesWalkieEnvelope": false,
    "usesGeneratedSpeech": false
  }
}
```

`-15 dB` matches the existing Chapter combat-music catalog. Keep it explicit in
data so it can be art-directed later without changing combat code.

---

# 5. Trigger and lease transfer

The action router implements the existing sink:

```swift
@MainActor
final class Chapter01DadFinalBattleActionRouter:
    Chapter01PreDadFinalBattleReadySink
{
    private let episodeFlow: TuringEpisodeFlowController
    private let arbiter: StoryInteractionArbiter
    private let battle: Chapter01DadFinalBattleCoordinator

    private var handledCheckpointRevisions = Set<Int>()
    private var battleStarted = false

    func preDadFinalBattleBecameReady(
        _ event: Chapter01PreDadFinalBattleReadyEvent
    ) async {
        guard event.completedBranches == Set(Chapter01PostRobotBranch.allCases),
              handledCheckpointRevisions.insert(event.checkpointRevision).inserted,
              !battleStarted else {
            return
        }

        let battleInstanceID = UUID()
        do {
            let lease = try await episodeFlow.transferActiveInteractionToBattle(
                battleInstanceID: battleInstanceID,
                reason: "chapter01HamTerminalToDadFinalBattle"
            )
            battleStarted = true
            battle.start(
                event: event,
                battleInstanceID: battleInstanceID,
                interactionLease: lease
            )
        } catch {
            handledCheckpointRevisions.remove(event.checkpointRevision)
            battleStarted = false
            battle.reportTriggerFailure(error)
        }
    }

    func startFromContinuation(
        snapshot: Chapter01ProgressSnapshot,
        chapterRunID: UUID,
        transitionLease: StoryInteractionLease
    ) async throws {
        guard snapshot.checkpoint == .preDadFinalBattleReady,
              snapshot.postRobot.allBranchesComplete,
              !battleStarted else {
            return
        }
        let battleInstanceID = UUID()
        let lease = try await arbiter.transferStoryTransitionToBattle(
            storyTransitionLease: transitionLease,
            battleInstanceID: battleInstanceID,
            reason: "chapter01DadFinalBattleContinuation"
        )
        battleStarted = true
        battle.startFromContinuation(
            snapshot: snapshot,
            chapterRunID: chapterRunID,
            battleInstanceID: battleInstanceID,
            interactionLease: lease
        )
    }
}
```

The illustrative code shows the ownership split. Adapt exact error propagation to
the current Chapter coordinator, but preserve these two separate lease paths.

The live event must transfer the Ham Turing lease before the normal flow cleanup
tries to release it. This is the same atomic ownership pattern already used by
`PrologueStoryActionRouter` for ScriptPoint03 -> Battle01.

The Continue path must transfer its current Story transition lease before any
post-Robot interaction presentation is restored.

No Dad-frame, walkie, ham, or door icon may flash between the terminal Ham point
and battle ownership.

---

# 6. Battle state machine

Use a Chapter-specific state enum; do not reuse Grandma-named states such as
`grandmaDown`:

```swift
enum Chapter01DadFinalBattleState: String, Sendable {
    case unloaded
    case preparing
    case portalIdleFacingAway
    case turnOne
    case turnTwo
    case approachingDoor
    case waitingForDoor
    case openingDoor
    case portalCrossing
    case combatGracePeriod
    case combatLethal
    case dadDeathAnimation
    case dadDeathDialogueHold
    case playerDead
    case releasingRuntime
    case postBattleHold
    case failed
    case cancelled
}
```

State transition rules:

```text
unloaded -> preparing
preparing -> portalIdleFacingAway
portalIdleFacingAway -> turnOne -> turnTwo -> approachingDoor
approachingDoor -> portalCrossing                    if door already open
approachingDoor -> waitingForDoor -> openingDoor    if door closed at A3
openingDoor -> portalCrossing                        after actual open completion
portalCrossing -> combatGracePeriod
combatGracePeriod -> combatLethal                    at media time >= 60.0
combatGracePeriod/combatLethal -> dadDeathAnimation  when Dad health reaches zero
combatLethal -> playerDead                           on fifth post-gate hit
dadDeathAnimation -> dadDeathDialogueHold             if cue 01 is reserved or any Rich PR is active/pending
dadDeathAnimation -> releasingRuntime                 if cue 01 fired and Rich PR queue is empty
dadDeathDialogueHold -> releasingRuntime              after reservation and actual final PR completion
playerDead -> releasingRuntime
releasingRuntime -> postBattleHold                   after deterministic cleanup
```

Do not transition to combat based on a duration estimate. Portal crossing and
animation completion remain completion-owned.

---

# 7. Dad source and portal mirror

Generalize `Battle01PreparedEnemy` to a neutral shared type, for example:

```swift
@MainActor
struct ScriptedPortalPreparedEnemy {
    let enemyID: UUID
    let sourceController: JockRetargetTestController
    let sourceRoot: Entity
    let portalMirror: StoryPortalEnemyRenderMirrorAdapter
}
```

`Chapter01DadBattleEnemyFactory` must:

```text
load CharacterAttributeStore attributes for .dad
assert source asset is dad_biped.usdz
sample Dad's 3...5 Horde hit range
multiply accepted-hit capacity by 2
configure story identity with archetype .dad
load Dad once
prepare a fresh Story battle spawn
configure .storyGrandmaThreeX incoming-punch policy
require every intro, attack, damage, and death clip needed by the runtime
install Dad's character audio from dad.character.json
place source at authored zombie_a1 world position
derive the initial heading from the current door anchors
create one portal render mirror
hide room source until the existing reveal threshold
register only the source with BattleEnemyRuntimeRegistry
```

Initial heading must use the current placed door's anchors every run:

```swift
let a1World = doorContext.zombieA1.position(relativeTo: nil)
let a2World = doorContext.zombieA2.position(relativeTo: nil)
let routeToDoor = PhaseOneMath.normalizedOrFallback(
    SIMD3<Float>(
        a2World.x - a1World.x,
        0,
        a2World.z - a1World.z
    ),
    fallback: SIMD3<Float>(0, 0, -1)
)
let initialForward = -routeToDoor
let initialYaw = PhaseOneMath.yawRadiansForNegativeZForward(
    worldForward: initialForward
)
```

Then apply Dad's authored visual heading correction through the Jock runtime. Do
not use the Dad-window route orientation, a fixed world yaw, or the window's
placement transform.

The source remains the sole animation, collision, health, audio, and damage
authority. The mirror has no collision, audio, health, attack callback, or hit
detector. Only the mirror receives portal-world lighting. The room source uses
room/passthrough lighting after reveal.

## 7.1 Portal crossing does not trigger Rich cue 01

Dad's portal position is not part of the cue predicate. `performPortalCrossing()`
continues to own only source/mirror transition and combat handoff. It must not
enqueue `pr-rich-dad-battle-01.mp3` when the source is revealed, when the mirror
exits, or when the crossing method returns.

---

# 8. Door interaction during the timeline

The existing arbiter currently resolves every `.battle` owner to zero
capabilities and a hidden door. That makes the existing
`requestBattleDoorOpen(ownerID:reason:)` unreachable because it requires
`.doorOpen`.

Add an explicit battle-door permission owned by the arbiter:

```swift
enum StoryBattleDoorPermission: Sendable, Equatable {
    case hiddenAndLocked
    case playerMayOpen
}
```

Add an owner-checked update:

```swift
func setBattleDoorPermission(
    _ permission: StoryBattleDoorPermission,
    battleLease: StoryInteractionLease,
    reason: String
) async throws
```

The arbiter must verify the lease is current and owned by the same battle ID.

For a `.battle` owner, resolve presentation as:

```text
permission playerMayOpen + door closedReady:
  capabilities: [doorOpen]
  door presentation: open
  Dad frame/walkie/crank/ham: hidden

permission playerMayOpen + door loading/opening/open:
  capabilities: []
  door presentation: hidden
  all devices: hidden

permission hiddenAndLocked:
  capabilities: []
  all presentations: hidden
```

The coordinator sets `.playerMayOpen` immediately after the full exterior is
ready and Dad's initial idle animation is visible. It changes to
`.hiddenAndLocked` when Dad reaches `zombie_a3`, when door opening begins, or
when portal crossing begins, whichever happens first.

The player may open the door during Dad's idle, turns, or approach. The player
may not close it during this battle. Dad's path progression does not wait for an
early player open; it continues on authored timing.

If the player never opens it, use the existing `openForBattle` at A3 with actual
animation and SFX completion. Dad waits in `idle_01`; never play
`unstable_walk_01` in place.

---

# 9. Music and authoritative battle clock

Do not use `Task.sleep(60)` as the damage authority. The requested timing is tied
to the music, not wall-clock time after an event.

The music controller must expose an immutable playback identity and media time:

```swift
struct Chapter01DadBattleMusicEpoch: Hashable, Sendable {
    let battleInstanceID: UUID
    let playbackID: UUID
}

protocol Chapter01DadBattleMusicClocking: Sendable {
    func prepare(resourcePath: String) async throws
    func playOnce(
        battleInstanceID: UUID
    ) async throws -> Chapter01DadBattleMusicEpoch
    func mediaTimeSeconds(
        for epoch: Chapter01DadBattleMusicEpoch
    ) async -> TimeInterval?
    func stop(
        epoch: Chapter01DadBattleMusicEpoch,
        fadeSeconds: TimeInterval,
        reason: String
    ) async
}
```

Start order is exact:

```text
prepare media
prepare Dad and mirror
submit Dad idle_01 successfully
make Dad visible in the portal
call music.playOnce
AV player confirms playback started
store returned epoch
damage clock becomes valid at media time 0
```

Door state is not part of the music-start predicate.

The track is one-shot. At natural completion, retain a terminal elapsed value of
at least its 180.035917-second duration so damage remains enabled. Do not loop
the clock back to zero.

If audio preparation or actual playback start fails:

```text
do not arm player damage
disable Dad combat
close/unload the battle portal
release Dad and mirror
release the battle lease
leave preDadFinalBattleReady durable for retry
surface a Chapter operation failure
```

If playback is paused or stalled by the system before 60 seconds, media time must
not advance. If playback resumes, the gate continues from the actual media time.

## 9.1 Exact 30-second Rich cue

`pr-rich-dad-battle-01.mp3` is owned by the active soundtrack epoch. It starts
when `dad-battle-01.mp3` reaches media time `30.000` seconds. It is not measured
from battle trigger receipt, Dad animation time, wall-clock time, portal exit, or
combat activation.

Extend the soundtrack controller with an epoch-scoped, one-shot media boundary:

```swift
func installMediaTimeBoundary(
    at seconds: TimeInterval,
    epoch: Chapter01DadBattleMusicEpoch,
    boundaryID: String,
    onReached: @escaping @Sendable (Chapter01DadBattleMusicEpoch) async -> Void
) async throws
```

Install `dad.richPR01` at `30.000` immediately after actual soundtrack playback
starts and the epoch is stored. The boundary implementation must follow the
soundtrack playhead. A system pause, stall, or interruption pauses the countdown.
Do not implement it with `Task.sleep`, `Date`, `ContinuousClock`, an animation
timer, or portal progression.

At the boundary:

```swift
guard epoch == activeMusicEpoch,
      state.isTerminal == false else {
    return
}

richPrerecordings.enqueue(
    cueID: .dadBattleSongThirtySeconds,
    battleInstanceID: battleInstanceID
)
```

The boundary and cue are exact-once per battle instance. Cancel the boundary on
player death, retry, cancellation, immersive teardown, music-start failure, or
replacement of the music epoch before 30 seconds.

Cue 01 has reserved authored precedence. If Dad reaches one accepted damage
point remaining before music time 30.000, retain cue 02 as pending but do not
start it. At 30.000, start cue 01; after its actual completion, start cue 02.
This preserves both the exact cue-01 music position and nonoverlapping authored
Rich dialogue.

---

# 10. Correct pre-damage hook

The current Jock sequence in `applyPlayerDamage` is not sufficient for the
first-minute rule:

```text
playerExposure is incremented
-> onBenchmarkPlayerHit is called
-> false still calls onPlayerDamaged
```

That would create hidden accumulated damage and visible damage feedback during
the protected minute.

Add a narrow, optional pre-damage contact disposition before any exposure or
hit-budget mutation:

```swift
enum StoryPlayerContactDisposition: Sendable, Equatable {
    case feedbackOnly
    case applyDamage
}

struct StoryPlayerAttackContact: Sendable {
    let amount: Int
    let attackerID: UUID?
    let attackClipID: String?
}

var onStoryPlayerAttackContact:
    ((StoryPlayerAttackContact) -> StoryPlayerContactDisposition)?
```

Apply it at the top of `JockRetargetTestController.applyPlayerDamage`, before
`playerExposure += amount`:

```swift
let contact = StoryPlayerAttackContact(
    amount: amount,
    attackerID: hordeID,
    attackClipID: activeAttack?.clipID
)

if onStoryPlayerAttackContact?(contact) == .feedbackOnly {
    emitStoryPlayerContactFeedback(contact)
    print("[Chapter01DadBattle] contact feedback-only; damage rejected")
    return
}
```

`emitStoryPlayerContactFeedback` may preserve the authored contact sound/effect,
but it must not:

```text
increment playerExposure
increment StoryPlayerHitBudget
call onPlayerDamaged
trigger damage tint
trigger player death
cancel Dad's attack animation
```

Default the new closure to `nil`, which preserves all existing Horde, Grandma,
Robot, and other Story behavior byte-for-byte at the decision boundary.

Clear the closure in `releaseBattleRuntime` beside the existing combat callbacks.

---

# 11. Five-hit post-minute budget

Use the existing `StoryPlayerHitBudget(maximumConfirmedHits: 5)`.

The Dad combat adapter owns one music epoch and one budget:

```swift
controller.onStoryPlayerAttackContact = { [weak self] contact in
    guard let self,
          let elapsed = self.damageClock.currentMediaTime else {
        return .feedbackOnly
    }
    return elapsed >= 60.0 ? .applyDamage : .feedbackOnly
}

controller.onBenchmarkPlayerHit = { [weak self] amount, _ in
    guard let self,
          self.damageClock.currentMediaTime >= 60.0 else {
        return false
    }

    let terminal = self.playerHitBudget.registerConfirmedHit()
    if terminal {
        self.onPlayerDamage(amount)
        self.requestPlayerDeathOnce()
    }
    return terminal
}

controller.setStoryPlayerHitCallbackOwnsBudget(true)
controller.onPlayerDamaged = { [weak self] amount in
    self?.onPlayerDamage(amount)
}
```

The exact contact at `59.999...` is feedback-only. The exact contact at
`60.000...` is hit one.

Jock's existing `activeAttack.hasDealtDamage` behavior is the distinct-contact
boundary. Do not count physics frames, hand samples, or multiple overlap events
from one authored attack window.

The first four post-gate hits call the existing player-damage presentation but
do not kill. The fifth invokes death once. Ignore every stale callback after the
terminal state.

## 11.1 One-accepted-damage-remaining Rich cue

The current `onCharacterDamageHit` callback is insufficient: it carries no
accepted count or capacity and can be reached by behavior that must not trigger
this cue. Add one generic accepted-damage snapshot at the Jock health mutation
boundary:

```swift
struct StoryEnemyAcceptedDamageSnapshot: Sendable, Equatable {
    let acceptedHitCount: Int
    let acceptedHitCapacity: Int
    let remainingAcceptedDamagePoints: Int
    let isLethal: Bool
}

var onStoryAcceptedDamageChanged:
    ((StoryEnemyAcceptedDamageSnapshot) -> Void)?
```

In `performDamageHit`, emit it immediately after an accepted hit mutates
`acceptedHitCount`:

```swift
if damageAccepted {
    acceptedHitCount = acceptedDamageHitCount

    let snapshot = StoryEnemyAcceptedDamageSnapshot(
        acceptedHitCount: acceptedHitCount,
        acceptedHitCapacity: hitsToKill,
        remainingAcceptedDamagePoints: max(0, hitsToKill - acceptedHitCount),
        isLethal: shouldDie
    )
    onStoryAcceptedDamageChanged?(snapshot)
}
```

The Dad battle adapter enqueues cue 02 only on:

```swift
controller.onStoryAcceptedDamageChanged = { [weak self] snapshot in
    guard let self else { return }
    guard snapshot.remainingAcceptedDamagePoints == 1,
          snapshot.isLethal == false else {
        return
    }
    self.richPrerecordings.enqueue(
        cueID: .dadOneDamageRemaining,
        battleInstanceID: self.battleInstanceID
    )
}
```

The cue must not trigger from:

```text
every physical punch
every layered head snap
the 2/3 storyGrandmaThreeX overlay-only result
a rejected temporal-cooldown duplicate
onPunchHit
onCharacterDamageHit without an accepted-damage snapshot
the lethal final accepted hit
remaining health inferred outside the enemy runtime
```

The independent 1/3 Story acceptance roll remains unchanged. Therefore the cue
means Dad has exactly one more accepted damage point before death, not one more
physical punch.

Clear `onStoryAcceptedDamageChanged` in `releaseBattleRuntime` with the other
Jock callbacks. This callback is generic and defaults to `nil`, preserving Horde,
Grandma, Robot, and every other enemy path.

## 11.2 Rich cue ordering and lifetime

The Rich queue is combat-adjacent audio, not an animation or health authority:

```text
cue 01 active when cue 02 is requested
  -> retain cue 02 pending
  -> cue 01 reaches actual AVAudioPlayer delegate completion
  -> start cue 02

cue 01 already complete
  -> start cue 02 immediately when one accepted damage point remains
```

Both cues play over `dad-battle-01.mp3`. Never duck or stop the battle track,
and never attach Rich audio to Dad, the portal, or the door. Rich uses the same
global/nonspatial `-5 dB` route as the existing Battle01 Rich prerecording.

Dad death must not cut off or discard either cue, and Dad's body must not
disappear or unload while cue 01's 30-second boundary is still reserved or
either Rich battle cue is active/pending. After Dad's death animation actually
completes, freeze the completed death pose, disable every combat and
hit-detection system, and enter `dadDeathDialogueHold`. The full Dad render
runtime remains visible until the 30-second reservation has fired and the queue
reports actual completion of its final authored MP3. Only that completion may
authorize Dad entity removal and `releaseBattleRuntime`.

The hold is visual/runtime ownership, not continuing combat. The queue must not
retain the battle through an accidental closure cycle; the coordinator owns the
hold and awaits a battle-instance-scoped queue-drained event. Door close and
full-exterior unload may proceed during the hold if they do not remove, disable,
reparent, relight, or otherwise disturb Dad's visible death pose.

Player death, explicit retry, battle cancellation, immersive teardown, or app
shutdown still stops and clears the queue immediately and may release Dad
without waiting for dialogue. Those are destructive termination paths, not Dad's
authored death sequence.

---

# 12. Player-death presentation

Do not create a Dad-specific death HUD.

Generalize the current hard-coded
`PlagueImmersiveCoordinator.handleChapter01RobotPlayerDeath()` to accept a
Chapter death source, while preserving its presentation sequence:

```text
disable Dad combat immediately
stop accepting additional hit callbacks
play random player-death audio
capture tracked device pose
show instruction HUD "You died."
run DeathPresentationController blackout
show YouDiedWorldCardPresenter at the captured pose
finish battle runtime cleanup
wait existing death-audio duration + presentation hold
fade black back up
remove world card
call onPlayerDeathStarted
PlagueDemoSession.handlePlayerDeathUI opens the Story episode picker
```

Use source-specific logging:

```swift
enum ChapterPlayerDeathSource: String, Sendable {
    case robot
    case dadFinalBattle
}
```

Do not leave log text or predicates hard-coded to "Robot" or
`confirmedRobotHits: 5` when Dad owns the death.

On Continue, the existing `preDadFinalBattleReady` checkpoint restarts this
battle without rescanning or replaying the three device branches.

---

# 13. Dad death and current milestone boundary

Dad is damageable and killable with the same Story incoming-hit contract as
Grandma. On accepted Dad death:

```text
disable attacks
play actual authored Dad death animation and Dad death audio
wait for actual death animation completion
freeze Dad in the completed death pose
remove portal mirror
close the door with actual animation and SFX if open
unload the full exterior after actual door-close completion
if music has not reached 30.000 seconds:
  keep the soundtrack epoch active until the reserved cue-01 boundary fires
if a Rich battle PR is reserved, active, or pending:
  keep Dad's body visible and retain the Dad render runtime
  wait for the final Rich dialogue MP3's actual playback completion
fade/stop dad-battle-01.mp3 only after the Rich queue and reservation are drained
remove Dad's body only after that dialogue-completion boundary
release Dad's complete heavy runtime only after body removal
release the battle lease
enter an in-session postBattleHold
```

Door/portal teardown may overlap the dialogue hold because it does not own Dad's
room-side body. The soundtrack remains available beneath the Rich dialogue.
Dad removal, soundtrack stop, and Dad runtime release happen only after the
30-second reservation and Rich queue are drained.

No post-Dad narrative, antigen treatment, final Dad-frame point, Chapter-complete
checkpoint, or credits behavior was specified in this request. Do not invent it.
Do not add a new durable checkpoint. Until the next authored milestone exists,
relaunch/Continue from `preDadFinalBattleReady` may replay the Dad battle.

---

# 14. Cleanup and memory boundary

Use the same deterministic release infrastructure as Battle01:

```text
BattleEnemyRuntimeRegistry
BattleEnemyRuntimeLease
BattleRuntimeCleanupCoordinator
JockRetargetTestController.releaseBattleRuntime
TuringStoryDoorBundleController.closeForBattleAndUnloadPortal
```

Final release must clear:

```text
Dad source entity
portal mirror
skinned model and materials
skeleton and retargeting adapter
prepared clips and animation callbacks
hit detector and collision entities
combat callbacks, including onStoryPlayerAttackContact and
onStoryAcceptedDamageChanged
character audio emitter and playback controllers
path follower and turn continuations
music player, item, callbacks, and epoch
door battle permission
door full-exterior lease and HDRI/IBL exterior
battle Tasks and closures
```

The Rich cue queue follows section 11.2. On authored Dad death, the Dad render
runtime and visible completed death pose outlive the death animation until the
active/pending Rich queue is drained. The queue owns only descriptor/file
identity, ordering state, and its audio player; the coordinator owns the explicit
Dad-body hold. This avoids an audio-player closure accidentally becoming the
owner of the enemy runtime.

On player death, retry, battle cancellation, and immersive teardown, cancel the
queue immediately and release Dad through the destructive cleanup path.

On player death, battle cleanup must finish before the episode picker allows a
retry. On Dad death, cleanup must finish before entering `postBattleHold`.

Do not keep the full skinned Dad as a persistent corpse after dialogue. The only
allowed retention is the bounded `dadDeathDialogueHold` between actual death
animation completion and actual final Rich MP3 completion.

---

# 15. Interaction and presentation matrix

| Dad battle phase | Device icons | Door icon | Door action |
| --- | --- | --- | --- |
| Preparing exterior/Dad | Hidden | Hidden | None |
| Dad idle/turn/approach, door closed-ready | Hidden | Open | Player may open |
| Player opening door | Hidden | Hidden | None |
| Door already open | Hidden | Hidden | No close action |
| Dad at A3, auto-opening | Hidden | Hidden | None |
| Portal crossing | Hidden | Hidden | None |
| Room combat | Hidden | Hidden | None |
| Player death cleanup | Hidden | Hidden | None |
| Dad death cleanup | Hidden | Hidden | None |
| Post-battle hold | Authored later | Closed/unloaded normal state | No battle owner |

The three device stable microphone states remain in progress data, but are not
visible or interactive while the battle lease exists.

---

# 16. Files to modify

Modify:

```text
PlagueImmersiveCoordinator.swift
  retain/wire boundary, action router, Dad battle, player-death source

Story/Chapter/Chapter01/Chapter01Coordinator.swift
  explicit live versus continuation Dad-battle entry routing

Story/Chapter/Chapter01/Chapter01PreDadFinalBattleBoundary.swift
  retain typed event; remove finalBattleImplemented:false diagnostic

Story/Interaction/StoryInteractionTypes.swift
  StoryBattleDoorPermission or equivalent typed policy

Story/Interaction/StoryInteractionArbiter.swift
  owner-checked battle door-open capability

Turing/Props/TuringStoryDoorBundleController.swift
  consume generic battle door-open capability; remove Battle01-only log wording

Battle/Shared/ScriptedPortalEnemyIntroCoordinator.swift
  replace Battle01-specific prepared/definition/state dependencies with shared contracts

Battle/Shared/ScriptedPortalEnemyIntroProtocols.swift
  generic prepared enemy/intro state contracts and neutral Rich cue queue
  contract as needed

JockRetargetTestController.swift
  pre-damage StoryPlayerContactDisposition hook, generic accepted-damage
  snapshot callback, and release cleanup

Battle/Battle01/Battle01RichPrerecordingController.swift
  generalize to shared StoryBattleRichPrerecordingQueue without changing
  Battle01 route, gain, or authored behavior

Story/Chapter/Chapter01/Chapter01MusicController.swift
  either add dadFinalBattle with a media-time epoch or leave it unchanged and use
  the dedicated Dad battle music controller; do not maintain two active owners
```

Add the Dad battle files listed in section 3 and tests listed below.

Do not modify:

```text
Foundation prompts
Qwen/Fresh2 renderer or decoder
Turing Flow promptVoice/conversationVoice
room scan or placement
portal dome placement/material contract
Horde wave, score, spawn, or music systems
Grandma attributes or Battle01 authored definition
Dad photo, walkie, or ham content descriptors
```

Add:

```text
TuringResources/Turing/Prerecordings/
  chapter01.room.rich.dadFinalBattle.musicThirtySeconds.001.json
  chapter01.room.rich.dadFinalBattle.oneDamageRemaining.001.json

TuringResources/Turing/Audio/prerecordings/
  pr-rich-dad-battle-01.mp3
  pr-rich-dad-battle-02.mp3
```

---

# 17. Required telemetry

Emit one structured prefix, for example `[Chapter01DadBattle]`, with:

```text
trigger accepted: chapterRunID, checkpointRevision, sourceEventID
lease transferred/claimed: leaseID, origin live/continuation
portal acquired: battleInstanceID, fullExteriorResident
Dad prepared: characterID, asset, enemyID, hitsToKill, punch policy
anchors: current world A1/A2/A3
initial heading: route vector, logical forward, authored correction
idle actual start
music actual start: playbackID, duration, gain
turn one actual completion
turn two actual completion
door permission changed
player door-open accepted/failed
Dad reached A3
auto-open actual completion if used
portal source reveal and mirror exit
Rich 30-second boundary installed/reached: boundaryID, battleInstanceID,
  playbackID, authoredMediaTime, observedMediaTime
Rich 30-second cue enqueued/started/completed: cueID, battleInstanceID,
  prerecordingID, soundtrackPlaybackID, actual route, gain
combat activated
accepted Dad damage: accepted count, capacity, remaining, isLethal
Rich one-damage-remaining cue enqueued/started/completed: cueID,
  battleInstanceID, prerecordingID
Rich cue queued behind active cue: activeCueID, pendingCueID
each player contact: playbackID, mediaTime, disposition
post-minute hit count: count/5
player death accepted once
Dad death start and actual completion
Dad death dialogue hold entered: activeCueID, pendingCueCount
Dad death pose retained while Rich dialogue active
Rich battle PR queue drained from actual playback completion
Dad body removed after dialogue: finalCueID, completionHandleID
enemy runtime released
door close actual completion
full exterior released
battle lease released
```

Never label an audio preparation call as music started. Log actual start only
after the player confirms playback.

---

# 18. Unit and integration tests

Add deterministic tests with injected clocks, rollers, and latches:

```text
testDadBattleDoesNotTriggerAfterDadBranchOnly
testDadBattleDoesNotTriggerAfterWalkieBranchOnly
testHamTerminalCompletionPersistsCheckpointBeforeBattleTransfer
testLiveHamCompletionTransfersTuringLeaseToBattleAtomically
testContinuationTransfersStoryTransitionLeaseToBattleWithoutRescan
testDuplicateCheckpointRevisionStartsOneBattle

testDadUsesDadAssetAndDadCharacterAudio
testDadStoryHitsToKillMatchesGrandmaFormula
testDadUsesStoryGrandmaThreeXIncomingPunchPolicy
testHordeDadAndGrandmaRemainLegacyHorde

testDadStartsAtCurrentDoorA1LookingAway
testDadIdleBeginsBeforeMusicStartRequest
testMusicStartsWithoutWaitingForDoorOpen
testTwoAuthoredRightTurnsAwaitActualCompletion
testDadFollowsA1A2A3Full3DPath
testDadWaitsInIdleNotWalkingInPlaceForDoor
testRichCue01DoesNotTriggerFromPortalRevealOrCrossing
testRichCue01TriggersAtSoundtrackMediaTimeThirty
testRichCue01DoesNotUseWallClockWhileMusicIsPaused
testRichCue01BoundaryIsExactOncePerMusicEpoch
testRichCue01IsGlobalAtMinusFiveDB
testCue02BeforeThirtyWaitsBehindReservedCue01

testBattleOwnerCanExposeDoorOpenOnly
testDoorCanOpenDuringDadIdle
testDoorCanOpenDuringDadTurn
testDoorCanOpenDuringDadApproach
testPlayerCannotCloseDoorDuringBattle
testDadAutoOpensDoorAtA3WhenStillClosed
testDoorPermissionLocksBeforeCrossing

testContactAt59Point999IsFeedbackOnly
testContactAt60Point000IsFirstConfirmedHit
testProtectedContactDoesNotMutateExposure
testProtectedContactDoesNotCallPlayerDamage
testProtectedContactDoesNotMutateHitBudget
testProtectedContactPreservesAttackAndContactFeedback
testPlaybackPauseDoesNotAdvanceDamageClock
testNaturalTrackCompletionLeavesDamageEnabled
testMissingMusicEpochDefaultsToNoDamage

testRejectedStoryPunchDoesNotEmitAcceptedDamageSnapshot
testAcceptedDamageSnapshotReportsCountCapacityAndRemaining
testOneDamageRemainingCueTriggersOnAcceptedNonlethalDamage
testOneDamageRemainingCueDoesNotTriggerFromHeadSnapOnly
testOneDamageRemainingCueDoesNotTriggerFromCooldownDuplicate
testOneDamageRemainingCueDoesNotTriggerOnLethalFinalHit
testOneDamageRemainingCueStartsOnlyOncePerBattleInstance
testSecondRichCueWaitsForFirstCuesActualCompletion
testRichCuesNeverBlockCombatOrDamage
testDadDeathHoldsCompletedBodyUntilAuthoredRichCueFinishes
testDadDeathBeforeThirtyKeepsMusicEpochAndReservedCueAlive
testDadDeathBeforeThirtyStartsCue01AtMusicTimeThirty
testDadRuntimeReleaseWaitsForActualRichCueCompletion
testDoorAndPortalMayReleaseWhileDadDialogueHoldRemainsVisible
testDadBodyRemovesImmediatelyWhenDeathCompletesAndRichQueueIsEmpty
testDadDeathDialogueHoldTransitionsOnlyFromMatchingBattleQueueDrain
testPlayerDeathCancelsRichCueQueue
testTranscriptFreeBattleCuesNeverEnterFoundationOrQwen

testFourPostMinuteHitsDoNotKillPlayer
testFifthPostMinuteHitKillsPlayerExactlyOnce
testOneAttackWindowCannotRegisterMultipleHits
testPlayerDeathUsesExistingYouDiedPresentation
testEpisodePickerAppearsAfterBlackFade

testPortalMirrorHasNoCollisionAudioOrDamageAuthority
testRoomSourceDoesNotInheritPortalIBL
testDadDeathActualCompletionPrecedesRuntimeRelease
testPlayerDeathCleanupPrecedesRetryUI
testDoorClosesBeforeFullExteriorUnload
testAllDadCallbacksAndHeavyResourcesRelease
```

The key time-gate test should drive exact media times, not sleep:

```swift
clock.setMediaTime(59.999)
contact()
XCTAssertEqual(budget.confirmedHits, 0)
XCTAssertEqual(playerDamageCallCount, 0)

clock.setMediaTime(60.000)
contact()
XCTAssertEqual(budget.confirmedHits, 1)
```

---

# 19. Static rejection checks

Reject the implementation if any of the following are present:

```text
Task.sleep used to arm Dad damage after 60 seconds
Date() or ContinuousClock used instead of soundtrack media time
Dad final battle uses Chapter01DadWindowRuntimeFactory hitsToKill: 1
Dad final battle copies ScriptedPortalEnemyIntroCoordinator
fixed world yaw for Dad at A1
window transform used for Dad battle orientation
mirror collision, audio, health, or damage callback
Rich cue 01 triggered from portal, animation, combat, or wall-clock timing
Task.sleep, Date, or ContinuousClock used for Rich cue 01's 30-second boundary
Rich cue 01 starts before or after the soundtrack reaches media time 30.000
one-damage-remaining cue inferred from punch count outside Jock health authority
one-damage-remaining cue triggered from overlay-only or rejected damage
Rich battle cue invokes Foundation, Qwen, filler, or walkie audio
Rich cues overlap, stomp one another, or block combat activation
Dad body removed or Dad runtime released before reserved/active/pending Rich dialogue completes
Dad death before 30 seconds cancels or advances the soundtrack-owned cue-01 boundary
Rich audio player directly retains Dad or the battle coordinator through a closure cycle
full portal retained only to keep the room-side Dad death pose visible
playerExposure mutates during protected contacts
false onBenchmarkPlayerHit used as the only protected-minute gate
door close capability exposed during the Dad battle
all .battle owners permanently hide doorOpen
music waits for the door to open
new Foundation/Qwen/Turing code in Dad battle files
new Chapter checkpoint added for this milestone
full skinned Dad corpse retained after final Rich dialogue completion
```

---

# 20. Vision Pro acceptance

Run from both live progression and Continue.

1. Complete Dad photo, walkie, and ham in the production order.
2. Confirm the final CatEye81 generated playback actually completes.
3. Confirm no device microphone/play icon flashes after terminal completion.
4. Confirm Dad battle ownership begins once.
5. Confirm full exterior loads while the door remains closed.
6. Confirm Dad is visible at A1 looking away from the room.
7. Confirm `idle_01` is active.
8. Confirm `dad-battle-01.mp3` starts with the initial animation, not the door.
9. Leave the door closed and observe both actual right-turn clips.
10. Confirm Dad walks A1 -> A2 -> A3 without sliding or walking in place.
11. Confirm Dad idles at A3 while the real door opens.
12. Confirm door animation and SFX complete before Dad crosses.
13. Repeat and open the door during Dad's initial idle.
14. Confirm the open button works under battle ownership.
15. Confirm Dad continues his timed portal approach without restarting.
16. Confirm no close button appears.
17. Confirm source/mirror transition is visually continuous.
18. Confirm only the portal mirror has portal-world lighting.
19. Confirm portal reveal and actual crossing completion do not start `pr-rich-dad-battle-01.mp3`.
20. Confirm `pr-rich-dad-battle-01.mp3` starts at soundtrack media time `30.000` seconds.
21. Pause or interrupt the soundtrack before 30 seconds and confirm cue 01 does not use elapsed wall time.
22. Confirm Rich is global/nonspatial at `-5 dB` and combat does not wait for it.
23. Confirm Dad follows and attacks using the existing combat runtime.
24. During soundtrack minute zero, allow multiple attacks to contact.
25. Confirm attack/contact effects continue.
26. Confirm no damage tint, damage count, death, or latent exposure occurs.
27. Cross actual soundtrack media time 60.0 seconds.
28. Confirm hit one now produces normal player-damage feedback.
29. Punch Dad and verify rejected 2/3 head-snap-only outcomes do not start cue 02.
30. Bring Dad to exactly one accepted damage point remaining.
31. Confirm `pr-rich-dad-battle-02.mp3` starts exactly once.
32. Confirm cue 02 waits if cue 01 is still playing and begins after actual cue 01 completion.
33. Confirm the final accepted Dad hit may kill Dad without cutting off cue 02.
34. Confirm Dad finishes the death animation and remains visible in its completed pose.
35. Confirm Dad's body does not disappear while cue 02 is still playing.
36. Confirm the door and full exterior may close/unload without disturbing Dad's room-side pose.
37. Confirm Dad disappears and its heavy runtime unloads only after cue 02's actual completion.
38. Confirm hits two through four against the player do not kill.
39. Confirm player hit five triggers player death once.
40. Confirm Dad combat disables immediately.
41. Confirm player-death audio, blackout, and world "You died" card run.
42. Confirm Dad, mirror, character audio, portal runtime, and Rich cue queue release.
43. Confirm the Story episode picker appears only after black fades back out.
44. Select Continue and confirm no room rescan occurs.
45. Confirm the Dad battle restarts from A1 and the three device branches do not replay.
46. In another run, kill Dad using the Story Grandma incoming-hit policy.
47. Confirm the actual Dad death animation and Dad death audio finish.
48. Confirm battle music stops, door closes, full exterior unloads, and no heavy Dad runtime remains.

---

# 21. Completion report required from Codex

The implementation report must include:

```text
files added and modified
exact installed music resource path and checksum
exact installed Rich cue resource paths and checksums
proof both Rich descriptors use transcriptMode none and never enter an LLM path
proof live Ham completion transferred Turing -> battle ownership
proof Continue claimed battle ownership without rescanning
proof Dad used current A1/A2/A3 world transforms
proof Dad used idle_01, two turn_right_90 completions, and unstable_walk_01
proof the door opened from the player during the portal timeline
proof music started from initial animation start while the door was closed
proof media time, not a sleep, armed damage at 60.000 seconds
proof pre-minute contacts did not mutate exposure or hit budget
proof fifth post-minute contact triggered the existing Chapter death presentation
proof Dad incoming health/punch policy matched Story Grandma
proof Grandma and Horde behavior did not change
proof source/mirror authority remained singular
proof Rich cue 01 started at soundtrack media time 30.000, not a portal event
proof pause/interruption did not let wall time advance cue 01
proof Rich cue 01 did not block combat activation
proof one-damage-remaining cue used accepted Jock health state, not punch count
proof rejected/head-snap-only contacts did not trigger the cue
proof Rich cue ordering used actual playback completion and never overlapped
proof Rich cues used global/nonspatial routing at -5 dB
proof Dad's completed death pose remained visible through final Rich MP3 completion
proof Dad entity removal and runtime release occurred only after actual dialogue completion
proof Dad and full exterior runtime released on both Dad death and player death
Vision Pro results for live progression and Continue
remaining authored product boundary after Dad death
```

Do not report this milestone complete from compilation alone.
