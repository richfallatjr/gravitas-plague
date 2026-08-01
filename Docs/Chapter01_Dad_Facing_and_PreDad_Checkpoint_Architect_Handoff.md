# Chapter 01 Dad Window Facing and Pre-Dad Checkpoint

## Architect implementation handoff

Repository:

```text
/Users/richardfallat/Projects/dev/gravitas-plague
```

Status: repository-audited corrective design. This document does not claim that the Dad-facing defect or Chapter 01 continuation has passed on Vision Pro.

## 1. Required product result

Fix two related Chapter 01 boundaries:

1. Dad must start the window animation facing in the direction of travel on every wall where the player may place the window. He must walk forward from screen right to center, turn left to face the window, idle, turn right, and walk forward out of frame. He must never moonwalk or inherit a stale heading from the window's original placement wall.
2. Persist a stable checkpoint after the second Chapter 01 opening Turing point actually completes and before any Dad runtime is loaded or the Dad cinematic starts.

Terminology is important:

```text
Product wording: Chapter 01 Script01 / Script02
Current repository IDs:
  Chapter Script01 = chapter01.walkie.rich.script06
  Chapter Script02 = chapter01.walkie.bigMike.script07
```

The requested checkpoint is after `chapter01.walkie.bigMike.script07`, not after `prologue.scriptPoint02`.

## 2. Current working-tree warning

At the time of this audit, the worktree contains uncommitted changes in:

```text
Gravitas Plague/Gravitas Plague/JockRetargetTestController.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/Chapter01DadRuntime.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/Chapter01DadWindowCoordinator.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/Chapter01RobotEncounterCoordinator.swift
Gravitas Plague/Gravitas Plague/Story/HUD/StoryItemRewardPresenter.swift
Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift
Scripts/verify_chapter01_robot_encounter.py
```

Do not discard these files wholesale. The current Dad changes include useful work that reacquires the adjusted window's current world transform. The heading correction inside that work is the defective part.

Relevant history:

```text
7afa4a3  WIP Chapter 1; title music
a93a69c  Episode 3 Script points 1-4 WIP
58f97ac  Antigen (current audited HEAD)
```

There is no proven-good historical Dad window orientation to restore. `7afa4a3` introduced Dad by copying identity anchor transforms and did not derive a route-facing orientation. `a93a69c` delayed Dad visibility until locomotion submission but retained the same heading ambiguity. The current dirty patch correctly snapshots the adjusted window in world space, but then adds a second 180-degree correction that cancels the established character correction.

## 3. Exact facing regression

### 3.1 The runtime already contains a 180-degree visual correction

`JockFollowDemoConfiguration.defaultDemo` currently defines:

```swift
followForwardSign: -1.0,
visualHeadingCorrectionDegrees: 180.0,
```

File:

```text
Gravitas Plague/Gravitas Plague/JockFollowDemoConfiguration.swift
```

The controller combines that base correction with a caller-supplied additive correction:

```swift
private var effectiveScriptedVisualHeadingCorrectionDegrees: Float {
    (
        followConfiguration.visualHeadingCorrectionDegrees
            + scriptedVisualHeadingOffsetDegrees
    ).truncatingRemainder(dividingBy: 360)
}
```

File and symbol:

```text
Gravitas Plague/Gravitas Plague/JockRetargetTestController.swift
JockRetargetTestController.effectiveScriptedVisualHeadingCorrectionDegrees
```

### 3.2 Chapter 01 adds another 180 degrees

The current dirty `Chapter01DadRuntimeFactory.prepare` contains:

```swift
controller.setScriptedVisualHeadingOffsetDegrees(180)
```

The resulting effective correction is:

```text
base character correction:    180 degrees
Dad additive correction:      180 degrees
modulo 360 result:               0 degrees
```

The patch comment says Dad needs an opposite correction, but the API is additive. The call therefore removes the existing visual correction. It does not rotate Dad by one additional visible half turn.

This is the direct regression to remove.

### 3.3 Root direction and rendered-body direction are separate layers

The current window code correctly derives a logical path direction:

```swift
let entryFacing = normalize(centerWorld - entryWorld)

controller.rootEntity.setOrientation(
    simd_quatf(from: SIMD3<Float>(0, 0, -1), to: entryFacing),
    relativeTo: nil
)
```

That aligns the root's logical `-Z` with the route tangent. It does not by itself prove that the visible retargeted body faces the tangent. Walk and idle clips apply this visual override:

```swift
JockRuntimeClipOverride(
    entryHeadingDegrees: -effectiveScriptedVisualHeadingCorrectionDegrees,
    exitHeadingDegrees: -effectiveScriptedVisualHeadingCorrectionDegrees,
    commitRootYawOnCompletion: false
)
```

With the correct effective correction, root heading and rendered-body heading agree. With the accidental `0` effective correction, Dad visually faces backward while his root still advances along the correct path. That is the observed moonwalk.

### 3.4 The current code mixes transform ownership

The current implementation uses all of these layers:

```text
window root transform
portalWorldRoot local transform
world-space route snapshots
rootEntity world orientation
visual-offset local orientation
JockRuntimeDriver local root-yaw commit
```

The latest patch changed path steering to use `rootEntity.orientation(relativeTo: nil)`, which is appropriate for a world-space route. However, `JockRuntimeDriver.commitRuntimeOverrideAtClipCompletion` still commits turn yaw through:

```swift
root.orientation = delta * root.orientation
```

That is a local-space assignment. Dad is parented under `portalWorldRoot`, while his initial heading and path are now world-space. Even if the current portal parent is yaw-only, the code has no explicit contract proving those spaces are interchangeable.

There must be one owner for Dad's trajectory heading and one declared coordinate space.

## 4. Why the established portal ingress behaves correctly

The Horde ingress path already uses the required ownership shape in:

```text
Gravitas Plague/Gravitas Plague/Horde/HordePortalInstancedIngressController.swift
```

Relevant symbols:

```text
HordePortalInstancedIngressController.worldOrientation
HordePortalInstancedIngressController.yawOnlyOrientation(...)
HordePortalInstancedIngressController.applyAuthoritativeWorldPose(...)
HordePortalInstancedIngressController.finishSingleNinetyDegreeTurn()
```

Its contract is:

```text
portal-local route direction
-> convert through the portal's current transform
-> flatten in world space
-> construct one yaw-only world orientation
-> hold the root at the authored entry yaw during the turn clip
-> commit the exact authored exit yaw once
-> use that same authoritative pose for the source and portal mirror
```

The shared Battle01 intro also validates the result after authored turns:

```swift
let tangent = normalize(a2 - a1)
let forward = sourceRoot.orientation(relativeTo: nil).act(
    SIMD3<Float>(0, 0, -1)
)
let angle = acos(clamp(dot(flatForward, flatTangent)))
```

File:

```text
Gravitas Plague/Gravitas Plague/Battle/Shared/ScriptedPortalEnemyIntroCoordinator.swift
```

Dad currently has neither a single authoritative heading owner nor a rendered-forward assertion. Repeated hard-coded rotations have therefore changed one layer while another layer silently counter-rotated it.

## 5. Required Dad orientation architecture

### 5.1 Three owners, no overlap

Use these ownership boundaries:

```text
Chapter01DadWindowRouteSnapshot
  owns immutable positions and exact world headings derived from the current window

Chapter01DadWindowCoordinator
  owns the character root's trajectory heading and exact turn-end commits

Jock character runtime
  owns the one established model/animation visual-axis correction
```

Forbidden:

```text
Chapter call-site additive 180-degree guesses
copying an identity anchor rotation and assuming it faces the route
root yaw being committed once by the driver and again by the coordinator
mixing local root yaw with world-space path steering
using the window's placement-time transform after manual adjustment
showing Dad before the first walk pose and heading are both installed
```

### 5.2 Reuse one portal-local heading resolver

Extract or reuse the math currently proven by `HordePortalInstancedIngressController.yawOnlyOrientation`:

```swift
enum PortalLocalHeadingResolver {
    static func worldYaw(
        portalRoot: Entity,
        localDirection: SIMD3<Float>
    ) throws -> simd_quatf {
        let worldOrigin = portalRoot.convert(position: .zero, to: nil)
        let worldTarget = portalRoot.convert(position: localDirection, to: nil)
        let flat = SIMD3<Float>(
            worldTarget.x - worldOrigin.x,
            0,
            worldTarget.z - worldOrigin.z
        )
        guard simd_length(flat) > 0.001 else {
            throw Chapter01Error.openingResourceUnavailable(
                "Window route has no horizontal direction."
            )
        }
        return simd_quatf(
            from: SIMD3<Float>(0, 0, -1),
            to: simd_normalize(flat)
        )
    }
}
```

Do not change Horde behavior while extracting this helper. Prove byte-equivalent orientation results for the current Horde cardinal cases before switching Horde to the shared symbol.

### 5.3 Capture the route after the final adjusted window transform

Keep the useful part of the current dirty `acquireChapter01DadCinematicContext()` change:

```text
stop the adjustment animation if one is still active
apply committedAdjustmentTransform to the window root
rebuild the procedural route anchors under the current portalWorldRoot
capture positions and headings in world space
freeze that snapshot for one Dad run
```

Replace the position-only context with an explicit route snapshot:

```swift
struct Chapter01DadWindowRouteSnapshot: Sendable {
    let windowWorldTransform: simd_float4x4

    let entryWorldPosition: SIMD3<Float>
    let centerWorldPosition: SIMD3<Float>
    let exitWorldPosition: SIMD3<Float>

    let entryWalkWorldOrientation: simd_quatf
    let centerFacingWindowWorldOrientation: simd_quatf
    let exitWalkWorldOrientation: simd_quatf
}
```

Derive the headings from the current portal transform:

```text
entry walk:       entry -> center
center idle:      portal room-side normal, toward the player/window
exit walk:        center -> exit
```

Do not infer the center-facing direction from a global axis. Resolve the portal plane's room-side normal through the current window transform.

Before accepting the route, validate:

```text
entry and center differ horizontally
center and exit differ horizontally
entry walk and exit walk point in the authored same direction
entry heading -> center-facing heading is the authored left 90-degree turn
center-facing heading -> exit heading is the authored right 90-degree turn
each turn magnitude is 90 degrees within a small tolerance
all positions are finite
all orientations are finite and normalized
```

If these assertions fail, fail before loading or revealing Dad. Do not choose another 180-degree fallback.

### 5.4 Remove the duplicate visual correction

Delete this Chapter-specific call:

```swift
controller.setScriptedVisualHeadingOffsetDegrees(180)
```

Prefer a semantic reset API so a future pooled controller cannot retain a prior additive offset:

```swift
func useAuthoredCharacterHeadingCorrection() {
    scriptedVisualHeadingOffsetDegrees = 0
}
```

The required Dad setup telemetry is:

```text
characterID: dad
runtimeForwardAxis: -z
baseVisualCorrectionDegrees: 180
additiveVisualCorrectionDegrees: 0
effectiveVisualCorrectionDegrees: 180
```

Do not put Dad's correction into Chapter JSON. Dad uses the same character/retargeting convention as the established runtime.

### 5.5 Commit exact turn endpoints in one space

The preferred portal-style turn contract is:

```text
install exact entryWalkWorldOrientation
start unstable_walk_01
show Dad only after the walk clip and visual offset are active
arrive at center

hold root at entryWalkWorldOrientation
play turn_left_90 to actual completion
commit centerFacingWindowWorldOrientation exactly once

play idle_01 for the authored duration

hold root at centerFacingWindowWorldOrientation
play turn_right_90 to actual completion
commit exitWalkWorldOrientation exactly once

start unstable_walk_01
walk center -> exit
```

Add a visual-only scripted-turn entry point, or parameterize the existing turn API, so the driver does not also commit root yaw when the coordinator owns the exact turn endpoint:

```swift
func playScriptedTurn90(
    direction: CharacterTurnDirection,
    rootYawOwnership: ScriptedRootYawOwnership,
    token: UUID,
    completion: @escaping @MainActor (UUID, Result<Void, Error>) -> Void
) throws

enum ScriptedRootYawOwnership {
    case runtimeDelta
    case externalExactWorldPose
}
```

For Dad use `.externalExactWorldPose`. At actual clip completion, the coordinator calls:

```swift
rootEntity.setOrientation(expectedWorldOrientation, relativeTo: nil)
```

exactly once. Existing Horde and Battle behavior remains on its current path until separately proven compatible.

### 5.6 Assert the rendered character, not only the root

Expose read-only diagnostics from `JockRetargetTestController`:

```swift
struct ScriptedCharacterHeadingSnapshot: Sendable {
    let logicalRootForwardWorld: SIMD3<Float>
    let renderedVisualForwardWorld: SIMD3<Float>
    let baseVisualCorrectionDegrees: Float
    let additiveVisualCorrectionDegrees: Float
    let effectiveVisualCorrectionDegrees: Float
}
```

Immediately after the entry walk is submitted and before `controller.show()`:

```text
dot(renderedVisualForwardWorld, entryRouteTangent) >= cos(5 degrees)
```

After each turn completes:

```text
left turn:  rendered visual forward aligns with center-facing window normal
right turn: rendered visual forward aligns with center -> exit tangent
```

An assertion against root `-Z` alone is insufficient because the defect is in the visual-offset layer.

## 6. Required pre-Dad checkpoint

### 6.1 Exact checkpoint boundary

The checkpoint ID should be explicit:

```swift
case preDadWindowReady = "chapter01.preDadWindow.ready"
```

Commit it only in response to `TuringScriptPointCompletionEvent` for:

```text
chapter01.walkie.bigMike.script07
```

`TuringEpisodeFlowController.publishCompletion` emits this event only after the successful ScriptPoint result has an identity and the full authored Turing route has completed. Do not checkpoint on:

```text
Foundation return
Qwen render completion
first generated segment publication
generated playback start
estimated duration
Script07 PR completion alone
```

### 6.2 Fix the current duplicate commit

Current `Chapter01Coordinator.scriptPointCompleted` performs:

```swift
commit(.script07Completed, sourceEventID: event.eventID)
commit(.dadWindowPending, sourceEventID: UUID())
```

This creates two revisions for one semantic boundary and defeats event idempotency by inventing a second source event ID.

Replace both commits with one durable commit:

```swift
let checkpoint = try await progress.commit(
    .preDadWindowReady,
    sourceEventID: event.eventID
)
```

The checkpoint write must finish successfully before:

```text
Turing -> Story transition lease transfer
Dad cinematic-context acquisition
Dad USDZ load
Dad animation preparation
Dad music start
Dad visibility
```

If persistence fails, Dad must not start.

### 6.3 Normal uninterrupted progression

Preserve the authored automatic sequence during a normal run:

```text
Script07 actual completion
-> commit preDadWindowReady durably
-> atomically transfer Turing lease to Story transition
-> acquire a fresh current-window route snapshot
-> load Dad
-> start Dad cinematic
```

The checkpoint is a crash/resume boundary. It does not add an unrequested pause or play icon to the uninterrupted Chapter sequence.

### 6.4 Continue behavior

When Continue restores `preDadWindowReady`:

```text
require the existing Story stage
-> do not rescan
-> do not rerun Foundation placement
-> do not reload or move placed props
-> quiesce transient Chapter/Turing/Battle activity
-> restore Script06 and Script07 as completed
-> create a new Chapter run identity
-> claim Story-transition ownership atomically from the stable state
-> acquire a fresh route snapshot from the window's current adjusted transform
-> start Dad at the beginning of the Dad cinematic
```

Do not replay Script06, Script07, their PR files, promptVoice, filler, or generated audio.

Do not persist or restore the old route coordinates. The room layout remains live and authoritative. A fresh route snapshot must be calculated from the current window transform immediately before Dad loads.

If the app exits after the checkpoint but during the Dad sequence, Continue restarts Dad from the beginning. No mid-animation checkpoint is required.

## 7. Continuation-system integration defect

`Chapter01ProgressStore` currently persists Chapter checkpoints under:

```text
story.chapter01.progress.v1
```

but the production Continue button does not read it.

The production continuation path is currently Prologue-only:

```text
TuringEpisodeContinuationSnapshot.checkpoint is TuringPrologueCheckpoint
TuringStoryProgressStore.isCompatible requires episodeID == .prologue
TuringStoryDestinationPlanner rejects non-Prologue episodes
TuringStoryStateTeleportCoordinator accepts only TuringStoryDestination
PlagueImmersiveCoordinator.startStoryEpisode(.chapter01) always calls beginAtRoot()
Chapter01Coordinator.beginAtRoot() resets Chapter progress
```

Therefore the existing Chapter checkpoint log is not a usable Continue checkpoint.

### 7.1 Generalize the production snapshot by episode

Use an episode-scoped checkpoint payload instead of inserting Chapter values into `TuringPrologueCheckpoint`:

```swift
enum TuringEpisodeCheckpoint: Codable, Sendable, Equatable {
    case prologue(TuringPrologueCheckpoint)
    case chapter01(Chapter01Checkpoint)
}

struct TuringEpisodeContinuationSnapshot: Codable, Sendable, Equatable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let episodeID: TuringEpisodeID
    let checkpoint: TuringEpisodeCheckpoint
    let revision: Int
    let committedAt: Date
    let sourceEventID: UUID
    let contentRevision: String
}
```

Migration requirements:

```text
schema v1 Prologue snapshot -> schema v2 .prologue(existingCheckpoint)
Chapter01ProgressStore .dadWindowPending -> .chapter01(.preDadWindowReady)
invalid episode/payload combinations -> reject, do not guess
```

There should be one production latest-Story snapshot used by the Continue strip. `Chapter01ProgressStore` may remain as a Chapter-local facade, but its successful commit must atomically update the production continuation snapshot. It must not become an unrelated second save truth.

### 7.2 Use episode-specific resume plans

Do not add Chapter fields such as Dad, Robot, or antigen state to the Prologue-specific `TuringStoryDestination`.

Use an episode resume plan:

```swift
enum TuringEpisodeResumePlan: Sendable, Equatable {
    case prologue(TuringStoryDestination)
    case chapter01(Chapter01ResumeDestination)
}

struct Chapter01ResumeDestination: Sendable, Equatable {
    let checkpoint: Chapter01Checkpoint
    let completedScriptPointIDs: Set<String>
    let action: Chapter01ResumeAction
}

enum Chapter01ResumeAction: Sendable, Equatable {
    case startAtRoot
    case startDadWindow
    case startRobotEncounter
}
```

For this milestone only these plans must be accepted:

```text
chapter01.root -> start at Chapter root
chapter01.preDadWindow.ready -> start Dad window
```

Later Chapter checkpoints may remain unsupported until their complete physical state restoration is authored.

### 7.3 Add a direct Story-transition claim for resume

Normal progression uses:

```text
StoryInteractionArbiter.transferTuringToStoryTransition(...)
```

On Continue there is no active Turing lease to transfer. Do not create a fake Turing run merely to manufacture a lease.

Add a guarded direct claim:

```swift
func claimStoryTransition(
    transitionID: UUID,
    source: String
) async throws -> StoryInteractionLease {
    guard exclusiveLease == nil else { ... }
    guard doorState == .closedUnloaded else { ... }
    guard turingGates.values.contains(.busy) == false else { ... }
    return await accept(
        owner: .storyTransition(transitionID: transitionID),
        source: source
    )
}
```

This claim must publish one arbiter snapshot before Dad loading begins. No walkie, door, crank-radio, ham-radio, or Dad-photo capability may remain interactive while the Dad-to-Robot transition owns the Chapter.

### 7.4 No-rescan invariant

Use the existing `TuringStoryStageCoordinator` and layout-fingerprint boundary:

```text
TuringStoryStageCoordinator.shared.isEstablished == true
layout fingerprint before Chapter restore
quiesce transient runtime only
apply Chapter resume action
layout fingerprint after Chapter restore
fingerprints must match
```

Preserve:

```text
room scan
wall/floor reconstruction
door placement
window placement
walkie shelf placement
rolling bench placement
poster placement
occupancy
manual placement transforms
cached placement candidates
```

The Dad route is derived from the preserved window. It is not part of the persisted layout.

## 8. Required coordinator structure

Refactor `Chapter01Coordinator` around one shared Dad-start method:

```swift
private func startDadWindow(
    chapterRunID: UUID,
    lease: StoryInteractionLease,
    source: Chapter01DadStartSource
) async throws
```

Both paths call it:

```text
normal Script07 completion:
  transfer active Turing lease -> startDadWindow

Continue at preDadWindowReady:
  claim Story transition -> startDadWindow
```

Required order inside the method:

```text
verify lease current
verify state is preDadWindowReady
acquire current window route snapshot
validate route headings
prepare Dad runtime hidden
install exact entry world pose
start entry walk
assert rendered forward alignment
show Dad
```

Add these Chapter states:

```swift
case preDadWindowReady
case preparingDadWindow
case dadWindow
```

Do not use `.dadWindow` while persistence or route validation is still pending.

## 9. Files to change

Dad facing:

```text
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/Chapter01DadRuntime.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/Chapter01DadWindowCoordinator.swift
Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryWindowBundleController.swift
Gravitas Plague/Gravitas Plague/JockRetargetTestController.swift
Gravitas Plague/Gravitas Plague/JockRuntimeDriver.swift, only if needed for explicit external root-yaw ownership
Gravitas Plague/Gravitas Plague/Horde/HordePortalInstancedIngressController.swift, only to adopt a proven shared heading resolver without changing behavior
```

Suggested additions:

```text
Gravitas Plague/Gravitas Plague/Story/Portal/PortalLocalHeadingResolver.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/Chapter01DadWindowRouteSnapshot.swift
```

Checkpoint and Continue:

```text
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/Chapter01Coordinator.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/Chapter01State.swift
Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/Chapter01ProgressStore.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringEpisodeContinuationSnapshot.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringStoryProgressStore.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringStoryDestinationPlanner.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringStoryStateTeleportCoordinator.swift
Gravitas Plague/Gravitas Plague/Turing/Story/TuringStoryEpisodePickerView.swift
Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift
Gravitas Plague/Gravitas Plague/Story/Interaction/StoryInteractionArbiter.swift
```

Tests:

```text
Gravitas Plague/Gravitas PlagueTests/Story/Chapter01DadWindowTests.swift
Gravitas Plague/Gravitas PlagueTests/Story/Chapter01ContinuationTests.swift
Gravitas Plague/Gravitas PlagueTests/TuringStoryEpisodeContinuationTests.swift
```

## 10. Mandatory automated tests

Dad heading:

```text
testDadUsesBaseVisualCorrectionWithoutAdditiveHalfTurn
testDadEntryHeadingUsesCurrentAdjustedWindowTransform
testDadFacesEntryRouteOnNorthWall
testDadFacesEntryRouteOnEastWall
testDadFacesEntryRouteOnSouthWall
testDadFacesEntryRouteOnWestWall
testDadRenderedForwardNotOnlyRootForwardMatchesEntryTangent
testDadEntryProgressNeverMovesOppositeRouteTangent
testDadLeftTurnCommitsExactCenterFacingWorldHeadingOnce
testDadRightTurnCommitsExactExitWorldHeadingOnce
testDadRemainsHiddenUntilWalkAndVisualHeadingAreInstalled
testWindowMovedAfterPlacementProducesFreshDadRouteSnapshot
testHordePortalHeadingResolverResultsRemainUnchanged
```

Use event barriers and deterministic update ticks. Do not use arbitrary sleeps for heading tests.

Checkpoint:

```text
testScript07ActualCompletionCommitsPreDadCheckpointOnce
testCheckpointUsesScriptCompletionEventID
testDadDoesNotLoadBeforeCheckpointPersistenceSucceeds
testCheckpointPersistenceFailurePreventsDadStart
testNormalRunAutomaticallyStartsDadAfterDurableCommit
testContinueAtPreDadDoesNotReplayScript06OrScript07
testContinueAtPreDadStartsDadFromBeginningExactlyOnce
testContinueAtPreDadDoesNotRunRoomScanOrPlacement
testContinueAtPreDadPreservesAdjustedWindowTransform
testContinueAtPreDadClaimsStoryTransitionWithoutFakeTuringRun
testCrashDuringDadRestartsAtDadBeginning
testSchemaV1PrologueSaveMigratesWithoutLoss
testLegacyDadWindowPendingMigratesToPreDadWindowReady
testStartChapterFromBeginningStillResetsChapterProgress
```

## 11. Required telemetry

Before Dad becomes visible:

```text
[Chapter01DadHeading] route captured
  chapterRunID
  windowWorldTransform
  entryWorldPosition
  centerWorldPosition
  exitWorldPosition
  entryRouteTangentWorld
  centerFacingWindowWorld
  exitRouteTangentWorld
  entryWorldYawDegrees
  centerWorldYawDegrees
  exitWorldYawDegrees

[Chapter01DadHeading] runtime correction
  characterID: dad
  runtimeForwardAxis: -z
  baseVisualCorrectionDegrees: 180
  additiveVisualCorrectionDegrees: 0
  effectiveVisualCorrectionDegrees: 180

[Chapter01DadHeading] alignment verified
  phase
  logicalRootForwardWorld
  renderedVisualForwardWorld
  expectedForwardWorld
  renderedAlignmentDegrees
  visible: false
```

Checkpoint:

```text
[Chapter01Continuation] checkpoint committed
  episodeID: chapter01
  checkpoint: chapter01.preDadWindow.ready
  sourceScriptPointID: chapter01.walkie.bigMike.script07
  sourceEventID
  revision
  dadRuntimeLoaded: false

[Chapter01Continuation] Dad start accepted
  source: uninterrupted | continue
  roomRescan: false
  placementRebuild: false
  layoutFingerprintPreserved: true
```

## 12. Vision Pro acceptance sequence

Run the Dad sequence with the window on at least four differently oriented walls.

For every placement:

```text
1. Manually move the window after initial placement.
2. Complete Chapter Script01 and Script02.
3. Verify the checkpoint commits before any Dad model-load log.
4. Verify Dad is not visible in an unposed frame.
5. Verify Dad enters from screen right walking forward.
6. Verify Dad does not show his back while moving toward center.
7. Verify the left turn is the authored turn_left_90 clip.
8. Verify Dad faces the room/window during the 20-second idle.
9. Verify the right turn is the authored turn_right_90 clip.
10. Verify Dad walks forward out of frame rather than moonwalking.
11. Verify Robot progression still begins from the Dad exit-walk event.
```

Then terminate immediately after the pre-Dad checkpoint and relaunch:

```text
1. Press Continue.
2. Verify no room scan or placement runs.
3. Verify the adjusted window remains on the same wall at the same transform.
4. Verify Script06 and Script07 audio do not replay.
5. Verify Dad restarts from the beginning of the window sequence.
6. Verify Dad uses the recalculated heading for the current window wall.
7. Verify exactly one Dad runtime exists.
```

## 13. Frozen systems

This repair must not modify:

```text
Foundation prompt templates or sessions
Qwen render/decode scheduling
Fresh2 concurrency
Turing generated playback ordering
Script06 or Script07 authored content
room scanning
LLM prop placement
manual prop placement behavior
door portal dome placement or materials
window portal dome placement or materials
Grandma combat or Battle01
Robot combat tuning
antigen reward presentation
Horde enemy behavior
```

## 14. Completion report required from Codex

Return all of the following:

```text
files changed
the removed duplicate 180-degree correction
the one authoritative Dad heading owner
the coordinate space used for every Dad root pose
proof rendered visual forward aligns with route tangent on four wall headings
proof both authored turn clips commit their exact expected world endpoints once
proof no moonwalk occurred
checkpoint schema and migration
proof checkpoint persisted before Dad load
proof Continue did not rescan or move the adjusted window
proof Script06 and Script07 did not replay on Continue
Vision Pro result
remaining failure boundary, if any
```

Do not report this complete from compilation alone. The facing defect is visual and wall-transform dependent, so completion requires the four-wall Vision Pro run and rendered-forward telemetry.
