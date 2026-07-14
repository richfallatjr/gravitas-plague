# Battle01 Repository Investigation

Repository: `/Users/richardfallat/Projects/dev/gravitas-plague`

Investigation date: 2026-07-13

Scope: repository reconnaissance only. This document does not authorize or include a Battle01 runtime implementation.

## 1. Executive findings

### Direct answers

| Question | Finding |
|---|---|
| Can Battle01 reuse the Horde portal transition? | **ADAPTER REQUIRED.** Reuse `HordePortalSkinnedRenderMirror` and its single-animation-clock mirror strategy. Do not reuse the entire randomized `HordePortalInstancedIngressController` sequence unchanged because Battle01 has authored A1/A2/A3 motion, two turns, a door wait, and a Story lifecycle. |
| Can it reuse Horde combat without starting Horde mode? | **ADAPTER REQUIRED.** `JockRetargetTestController` contains the reusable follow, attack, damage, and death runtime. `PlagueImmersiveCoordinator`'s wave, score, replacement-spawn, Horde UI, and Horde music ownership must not be activated. Story needs its own combat context and completion callbacks. |
| Are the three anchors sufficient? | **Sufficient for the authored pre-crossing polyline**, including the slope, if motion interpolates full 3D anchor positions. They are not sufficient to prove the exact portal crossing and room-side handoff points, and they do not provide foot IK. A separate crossing threshold derived from `TuringStoryDoorPortalPlane` is still required. A post-crossing room marker may be needed after device validation. |
| Are the requested turn animations present? | **Yes.** `turn_right_90` exists as a 1.375-second, non-looping clip. It can be played twice. Battle01 must observe actual `JockRuntimeDriver.onClipCompleted`, then commit the root yaw after each turn. |
| What grounding method should be used? | For the MVP, interpolate the complete 3D A1 -> A2 -> A3 polyline, keep the character upright, orient to the path tangent, and apply the existing visual-bounds root-to-floor offset. This follows the authored slope and reuses the current animation stack. Exact independent foot contact would require a new foot IK/raycast layer because none exists. |
| Where should the portal/world handoff happen? | At the existing portal-plane threshold, not merely at A3. A3 is the authored door-threshold approach marker. Reuse the Horde mirror mapping and reveal the real entity as its portal-local root crosses the configured plane threshold. |
| How should the closed-door sequence work? | At A3, enter idle, lock the player's door interaction, invoke a new awaitable scripted-open adapter on the existing door, wait for actual open-animation completion, start music when the selected door-and-Grandma predicate becomes true, then resume crossing. Do not call `toggleDoor` from the battle. |
| What event should trigger music? | Proposed technical event: `doorState == .open && grandmaState == .waitingAtDoor`, emitted once per battle instance. Whether the trigger is full-open completion, opening start, or crossing remains an author decision. |
| What exact event should start Battle01 after ScriptPoint03? | The successful result returned by `TuringFlowEngine.run(...)` to `TuringEpisodeFlowController` after ScriptPoint03's actual promptVoice playback and route finish have completed. Emit a typed script-point-completed event from `TuringEpisodeFlowController`; do not hook Foundation, Qwen, or the playback coordinator. |
| What is the minimum new production architecture? | A Story-owned `Battle01Coordinator` using small adapters for script-point completion, door control, scripted enemy animation/path motion, the existing Horde render mirror, Story combat takeover, gaze, music, and an injectable clock. It owns one battle instance and hands the same enemy runtime from scripted intro into existing combat behavior. |

### Recommended architecture choice

Choose **C: a reusable scripted-enemy-intro coordinator with a Battle01 state definition**, then hand control to the existing enemy runtime. This supports future episodic battles without copying Horde combat or forcing Story events into the Horde wave state machine.

Do not extend `HordePortalInstancedIngressController` with Story-specific door and ScriptPoint logic. Do not create a second combat implementation. Do not place Battle01 routing inside Turing speech generation or playback.

## 2. Current working-tree baseline

### Git state

```text
HEAD: c8d167ab17b0d22fbd3b54cdd24a9b84d207056f
branch: main
origin/main: c8d167ab17b0d22fbd3b54cdd24a9b84d207056f
HEAD subject: Rich IIS WIP
recommended checkpoint: battle01-rich-working-baseline-2026-07-13
checkpoint created: yes
checkpoint target: c8d167ab17b0d22fbd3b54cdd24a9b84d207056f
```

The checkpoint is an annotated tag created before any Battle01 source edits.

The working tree was clean when the checkpoint was created. Two untracked audio files appeared afterward:

```text
mrs-dempsey-prologue-battle.mp3
pr-rich-battle-mrs-dempsey.mp3
```

Neither file is part of the frozen commit or tag. They were not moved, edited, staged, or deleted during this investigation.

### Existing stashes

Relevant stashes include failed or incomplete Story wall-layout work, including:

```text
stash@{0}: score-based wall layout rebuild failed device placement
stash@{1}: score-based wall selection WIP
```

These are not Battle01 baselines and should not be applied during Battle01 work.

### Frozen dependencies

The current committed Rich implementation is the dependency boundary. Battle01 can be developed without changing Qwen or TTS source.

Files and systems that must remain untouched are listed in section 16. This includes the Fresh2 scheduler, Rich and Big Mike clone artifacts, Turing prompt execution, dialogue segmentation, generated-speech playback, fillers, walkie interaction, room scanning, and wall placement.

Classification: **production baseline**. Reuse unchanged.

## 3. Horde spawn/combat call chain

### Spawn ownership

| Path and symbol | Classification | Current behavior | Battle01 use |
|---|---|---|---|
| `Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift` `startHordeBenchmark()` | Horde-only production owner | Starts Horde benchmark state, music, waves, enemy updates, and UI-related Horde lifecycle. | Cannot use as Battle01 owner. |
| Same file, `spawnNextHordeWave()` | Horde-only production | Creates the current wave and schedules enemies. | Must not use. |
| Same file, `createLoadedHordeEnemyController(...)` | Horde-only production helper, private | Loads/configures one `JockRetargetTestController`; assumes Horde portal readiness and coordinator state. | Logic is reusable through an extracted Story factory; private API cannot be called unchanged. |
| Same file, `registerHordeEnemyForInstancedPortalIngress(...)` | Horde-only production helper | Registers an enemy with the portal ingress controller. | Adapter required. Battle01 needs authored anchors and no wave registration. |
| Same file, `updatePortalIngressControllers(...)` | Horde-only production frame update | Advances active Horde ingress controllers. | Battle01 needs its own coordinator update call. |
| Same file, `syncAllPortalMirrorsAfterEnemyAnimations()` | Horde-only production | Copies the world enemy's current root and joint transforms into portal mirrors after animation updates. | Reuse the mirror synchronization sequence through a shared adapter. |
| Same file, `handleBenchmarkEnemyKilled(...)` | Horde-only production | Applies Horde score/wave/death side effects. | Must not use. Story needs a battle-resolution callback. |
| Same file, `clearHordeEnemyControllers()` and `cleanupAllPortalMirrors()` | Horde-only production | Removes Horde enemies and mirror entities. | Teardown mechanics may be adapted, but Battle01 owns its own identities. |
| `Gravitas Plague/Gravitas Plague/Prewarm/HordePrewarmCoordinator.swift` | Horde production infrastructure | Prepares character prototypes. | Adapter required for Story-scoped preload without starting Horde. |
| `Gravitas Plague/Gravitas Plague/Prewarm/HordeCharacterPrototypeCache.swift` | Production infrastructure | Retains reusable character prototypes. | Reuse through a Story preload/factory boundary. |

### Current call chain

```text
startHordeBenchmark
-> spawnNextHordeWave
-> createLoadedHordeEnemyController
-> JockRetargetTestController.prepareFreshHordeSpawn
-> registerHordeEnemyForInstancedPortalIngress
-> HordePortalInstancedIngressController
-> HordePortalSkinnedRenderMirror
-> frame updates and portal threshold handoff
-> JockRetargetTestController.finishHordePortalIngressAndStartFollow
-> follow / target / attack / damage / death runtime
-> PlagueImmersiveCoordinator.handleBenchmarkEnemyKilled
-> Horde score, wave, replacement spawn, and cleanup
```

Spawning and RealityKit mutation are MainActor-owned. Horde brain decisions can be computed off MainActor, but commands are applied to the MainActor enemy controllers. There is no public, mode-neutral `spawnOneEnemy` API. The current one-enemy creation helper is private and coupled to Horde readiness.

### Enemy runtime

Primary type:

```text
Path: Gravitas Plague/Gravitas Plague/JockRetargetTestController.swift
Type: @MainActor JockRetargetTestController
Classification: production character/enemy runtime with diagnostic history
```

Relevant symbols:

| Symbol | Current behavior | Battle01 use |
|---|---|---|
| `configureHordeIdentity(...)` | Configures Horde identity and enables command-driven Horde brain behavior. | Needs a Story combat adapter. Calling this unchanged would pull in Horde assumptions. |
| `prepareFreshHordeSpawn(...)` | Resets and prepares an enemy. | Reusable through factory adapter. |
| `setCombatEnabled(_:)` | Enables or disables combat. | Reuse unchanged. |
| `setExternalMotionDriven(_:)` | Lets an external coordinator move the entity while animation continues. | Reuse unchanged for A1/A2/A3. |
| `setRootMotionEnabled(_:)` | Controls animation root motion application. | Reuse unchanged; disable for authored path. |
| `rootYForFloorY(_:)` / `lockRootToFloorY(_:)` | Uses visual bounds to align the runtime root with a floor height. | Adapt to the path's sampled Y value. |
| `prepareForHordePortalIngress(...)` | Configures source entity for mirrored ingress. | Adapter required. |
| `playHordePortalWalkLoop()` | Plays the character's configured walk while code drives motion. | Reuse through a neutral scripted-motion API. |
| `playHordePortalTurnFromAttributes(...)` | Plays configured turn animation. | Adapt to actual completion and explicit yaw commitment. |
| `finishHordePortalIngressAndStartFollow(...)` | Ends ingress and activates follow/combat behavior. | Reuse through Story combat context. |
| `update(...)` | Advances animation, follow, attack, hit reaction, and death behavior. | Reuse. Battle01 must own and call it outside Horde mode. |

The runtime already supports visible animation with combat disabled, external path motion, and later combat activation. This makes a scripted pre-combat coordinator viable without forking the combat implementation.

The current Horde configuration enables `enemyBrainCommandDriven`. Battle01 must either provide a Story-owned brain command source or add a neutral combat configuration that uses the controller's existing local follow/attack path. It must not register a fake Horde wave.

### Runtime component conclusion

The source world entity owns the skeleton, animation runtime, collision/combat configuration, health, and audio. The portal mirror is render-only: collision, input, audio, and grounding behavior are stripped by `HordePortalSkinnedRenderMirror`. Therefore only the source entity can attack or damage the player. This single-authority design should be preserved.

Exact RealityKit component inventory is partly assembled dynamically inside the controller and prototype preparation. A single static source list is not exposed. The established behavior is:

```text
portal mirror:
  rendering and copied joint/root transforms only
  no collision
  no input target
  no audio
  no damage authority

world/source enemy before handoff:
  loaded and animated
  hidden from passthrough initially
  combat disabled
  external motion enabled

world/source enemy after handoff:
  visible
  collision/combat enabled
  follow/attack runtime active
```

## 4. Horde portal clone transition

### Production types

```text
Path: Gravitas Plague/Gravitas Plague/Horde/HordePortalInstancedIngressController.swift
Types:
  HordePortalSkinnedRenderMirror
  HordePortalInstancedIngressController
Classification: Horde-only production portal ingress
```

`HordePortalSkinnedRenderMirror` clones the already-loaded source root recursively. It does not load a second character or run a second animation clock. The source controller advances the skeleton once, then the mirror receives copied root and joint transforms. Collision, input, audio, and grounding are removed from the mirror.

The mirror is parented under the portal world root. The source is parented in the room/world hierarchy and begins hidden while its animation remains active.

### Coordinate conversion

The current portal mirror mapping is:

```swift
let sourceWorldMatrix = source.rootEntity.transformMatrix(relativeTo: nil)
let portalWorldMatrix = portalWorldRoot.transformMatrix(relativeTo: nil)
let mirrorLocalMatrix = simd_inverse(portalWorldMatrix) * sourceWorldMatrix
mirrorRoot.setTransformMatrix(mirrorLocalMatrix, relativeTo: portalWorldRoot)
```

This supports arbitrary wall orientation because the conversion is matrix-based rather than a hard-coded world axis. The enemy's runtime forward convention comes from character attributes; Grandma uses `-Z` forward and `Y` up after RealityKit import.

### Handoff behavior

Current ingress phases are:

```text
walkingParallelInsidePortal
-> turningTowardExit
-> crossingAperture
-> realWorldFollowing

any phase -> failed
```

The current system uses portal-local Z thresholds:

```text
real source reveal: local Z >= -0.3048 m
exit complete: local Z >= 0.45 m
```

There is no fade. The real source is revealed while the mirror remains available long enough to cover the aperture. The mirror is later removed using body-radius hysteresis. The source remains the sole animation and combat authority, preventing duplicate attacks during overlap.

The current Horde ingress uses randomized depth/speed and a built-in single turn. It also assumes flat `floorY`. Therefore:

```text
Can Battle01 use the current Horde clone transition unchanged? ADAPTER REQUIRED
```

Minimum adapter:

1. Keep `HordePortalSkinnedRenderMirror` unchanged or extract it without behavior changes.
2. Let Battle01 drive the source along A1/A2/A3 while syncing the mirror after animation.
3. Wait at A3 for the door policy.
4. Resume forward motion toward/through `TuringStoryDoorPortalPlane`.
5. Use the same local-plane reveal and exit thresholds, calibrated against the Story door portal.
6. Activate Story combat only after the exit-complete event.

### Frame-by-frame authority proposal

```text
Before crossing:
  portal mirror: visible inside portal, render-only
  world source: hidden, animated, externally moved, combat disabled

At reveal threshold:
  portal mirror: remains visible through aperture
  world source: visible, combat still disabled

During overlap:
  portal mirror: copied pose, no collision/audio/damage
  world source: authoritative pose and audio, no attack yet

At exit-complete threshold:
  portal mirror: removed
  world source: external motion disabled, combat enabled, Story combat takeover begins
```

## 5. Zombie Grandma asset and animations

### Asset identity

```text
Asset: grandma_biped.usdz
Repository path: grandma_biped.usdz
USD default prim: /root
USD metersPerUnit: 1
USD up axis: Z
Skeleton: /root/Armature/Armature
Mesh: /root/Armature/char1/char1
SkelRoot: /root/Armature
Embedded SkelAnimation: none
```

The runtime sidecar is:

```text
Path: Gravitas Plague/Gravitas Plague/CharacterLibrary/Characters/grandma.character.json
Classification: production character definition
```

Key sidecar facts:

```text
asset: grandma_biped.usdz
runtime forward: -z
runtime up: y
pose mapping: sourceRestDeltaToTargetRest
idle: idle_01
walk: unstable_walk_01
right turn: turn_right_90
left turn: turn_left_90
audio anchor joint: Head
Horde hits to kill: 3...5
```

The USDZ is safely cloneable by the existing Horde prototype/mirror path. Its authored root includes a 0.01 Armature scale; production loading already accounts for the asset through the character runtime. Battle01 must not apply a new guessed character scale.

The exact current attack-origin anchor is **UNKNOWN** because the character sidecar identifies attack clips and audio anchor but does not declare a dedicated hand/mouth attack-origin entity. Existing attack range logic is controller-based.

### Skeleton foot joints

The skeleton exposes:

```text
LeftFoot
LeftToeBase
RightFoot
RightToeBase
```

No production foot-lock or foot IK system was found. Current grounding uses root placement relative to visual bounds and a floor height. Therefore exact independent foot contacts on a slope are not currently solved.

### Required animation inventory

| Clip | Resource | Duration | Loop | Motion | Current use | Battle01 use |
|---|---|---:|---|---|---|---|
| `idle_01` | `Gravitas Plague/Gravitas Plague/AnimationLibrary/Clips/Idle/idle_01.jockanim.json` | 14.125 s | Yes | Stationary | Character idle | Reuse unchanged. |
| `turn_right_90` | `Gravitas Plague/Gravitas Plague/AnimationLibrary/Clips/Turn/turn_right_90.jockanim.json` | 1.375 s | No | In-place; locomotion disabled | Horde portal turn support | Reuse through completion-aware scripted adapter. |
| `turn_left_90` | `Gravitas Plague/Gravitas Plague/AnimationLibrary/Clips/Turn/turn_left_90.jockanim.json` | 1.375 s | No | Mirrored from right | Character turn support | Not required for requested sequence. |
| `unstable_walk_01` | `Gravitas Plague/Gravitas Plague/AnimationLibrary/Clips/Walk/unstable_walk_01.jockanim.json` | 3.708333 s | Yes | Manual root curve of about -2 m; production ingress disables root motion | Horde walk | Reuse as in-place visual walk while Battle01 drives root. |
| `charged-slash-left` | attack clip JSON under `AnimationLibrary/Clips` | 2.791667 s | No | Attack | Horde combat | Reuse through existing combat runtime. |
| `charged-slash-right` | attack clip JSON under `AnimationLibrary/Clips` | 2.791667 s | No | Attack | Horde combat | Reuse through existing combat runtime. |
| `left_hook_01` | attack clip JSON under `AnimationLibrary/Clips` | 1.25 s | No | Attack | Horde combat | Reuse through existing combat runtime. |
| `right_hook_01` | attack clip JSON under `AnimationLibrary/Clips` | 1.25 s | No | Attack | Horde combat | Reuse through existing combat runtime. |

The character definition also references damage reactions and forward/backward death clips. Their exact clip selection is owned by `JockRetargetTestController` during combat.

All inspected idle/turn/walk clip metadata is `approved_for_runtime: true` and `approved_for_episode: false`. Technical playback exists, but using these clips in a production episode requires an explicit authoring approval or metadata update. Battle01 should fail preparation with a precise asset-contract error if approval remains mandatory; it must not substitute a random clip.

### Animation completion

```text
Path: Gravitas Plague/Gravitas Plague/JockRuntimeDriver.swift
Symbol: onClipCompleted: ((JockAnimClip) -> Void)?
Classification: production animation runtime
```

For non-looping clips, completion is emitted by the animation frame update when playback reaches the end. This is actual animation-clock completion, not a duration estimate. `JockRetargetTestController` currently consumes the callback internally through `handleJockClipCompleted`.

Battle01 needs a tokenized additional observer or an awaitable adapter that preserves the internal callback. It must not replace the driver's existing callback and must not advance turns with `Task.sleep(clipDuration)`.

## 6. A1/A2/A3 anchor table

### Asset and hierarchy

```text
Asset: Gravitas Plague/TuringResources/Turing/Props/turing_story_door_bundle_v1.usdz
USD root: /root
Exact authored names: zombie_a1, zombie_a2, zombie_a3
Entity type: empty Xform markers
Parent: /root
USD units: meters
USD up axis: Z
```

The anchors are not currently resolved by `TuringStoryDoorBundleController.Anchors`. They must be added to the door's recursive anchor contract before Battle01 implementation.

| Anchor | Parent | Authored position, USD Z-up | Rotation | Scale | Approx. imported meaning |
|---|---|---|---|---|---|
| `zombie_a1` | `/root` | `(0.14999999, 1.30999994, -0.049999997)` | `(0, 0, 0)` | `(1, 1, 1)` | Initial portal-world idle location, furthest from door. |
| `zombie_a2` | `/root` | `(0.04, 0.40999997, 0.02)` | `(0, 0, 0)` | `(1, 1, 1)` | Intermediate approach/slope guide. |
| `zombie_a3` | `/root` | `(0, 0.04000002, 0.02)` | `(0, 0, 0)` | `(1, 1, 1)` | Door-threshold approach marker. |

All three have identity rotation, so authored anchor orientation currently provides no facing information. Initial facing must be derived from the door/portal basis or explicitly authored later. Camera-relative facing is not deterministic and is not recommended.

Raw authored segment distances:

```text
A1 -> A2: approximately 0.9094 m
A2 -> A3: approximately 0.3722 m
```

The Story door bundle runtime scale is `3.2`, declared by `TuringStoryDoorBundleTuning.assetImportScale` in:

```text
Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundlePlacement.swift
```

Approximate scaled path distances are therefore 2.910 m and 1.191 m, subject to RealityKit import conversion and the placed door transform.

Exact world transforms, slope angles in RealityKit Y-up space, frame clearance, and the A3 relationship to the portal plane are **UNKNOWN until logged after runtime USDZ import and door placement**. Required preparation logs must print each anchor matrix relative to both `portalWorldRoot` and `nil`, plus the portal-plane equation.

## 7. Grounding and path recommendation

### Existing movement support

| Strategy | Existing support | A1/A2/A3 | Slope | Foot contact | Mirror compatibility | Finding |
|---|---|---|---|---|---|---|
| `Entity.move(to:)` | RealityKit standard API | Possible | Transform interpolation only | No | Possible | Not recommended because cancellation, constant speed, and exact mirror synchronization are less explicit. |
| Per-frame transform interpolation | Used by Horde ingress | Yes | Yes, if full 3D anchors are interpolated | Root only | Yes | Recommended MVP. |
| Root motion extraction | Supported by Jock metadata/runtime | Not path-constrained | Poor fit | Clip-dependent | Harder | Disable for authored path. |
| Horde movement controller | Existing | Yes after adapter | Currently flat floor | Root only | Yes | Reuse low-level external-motion and animation behavior. |
| Ground raycast | No complete Story portal-ground helper found | New work | Yes | Root only | Needs mirrored coordinate handling | Optional follow-up if authored path is insufficient. |
| Foot IK/locking | Not present | New subsystem | Yes | Best | Complex | Not MVP unless exact independent foot contact is mandatory. |

### Recommended MVP

1. Interpret A1/A2/A3 as a piecewise-linear path in the door portal coordinate system.
2. Convert path points into the authoritative source entity's world coordinates.
3. Advance by distance per frame for constant speed, not by a fixed segment duration.
4. Interpolate all three position coordinates, including vertical rise.
5. Keep character up aligned with world/door portal up and yaw toward the horizontal path tangent.
6. Disable animation root translation while playing `unstable_walk_01`.
7. Apply the existing visual-bounds root offset to each sampled path height.
8. Sync the portal render mirror after the source animation and motion update.
9. Measure foot/toe joint distance to the authored slab in diagnostics before declaring device acceptance.

This prevents obvious whole-character floating across the authored slope. It does not guarantee both feet are planted independently during every walk frame. If device tests exceed the accepted foot-height tolerance, the next layer is two foot raycasts plus pelvis/root correction or full IK.

### Orientation

Use the door portal basis, not current player head pose. A1 has no authored rotation. Define the initial facing-away direction as the portal exterior direction, then apply two positive 90-degree right turns around the runtime up axis. Validate the final heading against the A1 -> A2 tangent and fail preparation if the authored path direction disagrees beyond a configured tolerance.

This gives a repeatable result even if the player moves during ScriptPoint03.

## 8. Door integration

### Current production owner

```text
Path: Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift
Type: @MainActor TuringStoryDoorBundleController
Classification: Story production
```

Important symbols:

| Symbol | Current behavior | Battle01 use |
|---|---|---|
| `Anchors` | Holds frame, hinge, panel, portal plane, icon, audio, bounds, and portal-only prop references. Does not include A1/A2/A3. | Extend contract. |
| `loadBundleIfNeeded()` | Loads USDZ, applies 3.2 scale, prunes portal-only objects, applies AO. | Reuse unchanged except new anchor resolution. |
| `resolveAnchors(in:)` | Recursively resolves required entities. | Extend for exact lowercase zombie anchor names. |
| `reloadPortalWorld(...)` | Rebuilds portal world content. | Reuse. |
| `installPortalOnlyEntities(...)` | Moves authored slab, fence, and firewood into the portal world while preserving transform. | Reuse. |
| `toggleDoor(reason:)` | Toggles through the private animation controller. | Do not use from Battle01. |
| `reset(reason:)` | Removes/reset door runtime. | Battle cancellation must happen before this. |

Door animation owner:

```text
Path: Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorAnimationController.swift
Type: @MainActor TuringStoryDoorAnimationController
State: closed, opening, open, closing
Open yaw: -145 degrees
Open duration: 1.15 seconds
Close duration: 0.95 seconds
Local hinge axis: (0, 0, 1)
```

The animation currently advances through a 60 Hz Task using smoothstep. It has no public state accessor and no awaitable open-completion result. `currentYawDegrees()` also treats an interrupted `.opening` as fully open and `.closing` as fully closed, which can cause a discontinuity if interrupted. This is a Battle01 integration risk.

### Required adapter contract

Proposed API, not implemented:

```swift
@MainActor
protocol TuringStoryDoorBattleControlling: AnyObject {
    var battleDoorState: TuringStoryDoorBattleState { get }
    func setBattleInteractionLocked(_ locked: Bool, reason: String)
    func openForBattle(
        battleInstanceID: UUID,
        reason: String
    ) async throws -> TuringStoryDoorOpenResult
    func battlePortalContext() throws -> TuringStoryDoorBattlePortalContext
}

struct TuringStoryDoorBattlePortalContext {
    let portalWorldRoot: Entity
    let portalPlane: Entity
    let zombieA1: Entity
    let zombieA2: Entity
    let zombieA3: Entity
    let audioEmitter: Entity
}
```

`openForBattle` must complete when the existing door animation reaches `.open`, not after an estimated sleep. It should be idempotent when already open. While Grandma waits or crosses, the icon/physical door interaction should be locked at the owner so the player cannot close the door onto the character.

Existing door SFX already runs from `TuringStoryDoorAudioEmitter`; reuse it. No authored Grandma hand-contact or push animation was identified. For the current request, Grandma should idle while the door opens. A push animation/SFX is an authoring follow-up.

## 9. Gaze integration

### Existing pose source

```text
Path: Gravitas Plague/Gravitas Plague/Turing/Spatial/PhaseOneSpatialProvider.swift
Types: PhaseOneSpatialProvider, PhaseOneSpawnPose
Symbol: currentPose()
Classification: production Story spatial provider
```

`PhaseOneSpawnPose` exposes `headPosition` and `headForward`. `currentPose()` queries the tracked device anchor and derives forward from negative matrix column 2. No reusable door-gaze helper, eye-gaze ray, line-of-sight test, dwell timer, or one-shot target-seen event currently exists.

The smallest adapter is a pure head-gaze predicate:

```swift
func isLooking(
    pose: PhaseOneSpawnPose,
    targetWorldPosition: SIMD3<Float>,
    minimumDot: Float
) -> Bool {
    let toTarget = simd_normalize(targetWorldPosition - pose.headPosition)
    return simd_dot(simd_normalize(pose.headForward), toTarget) >= minimumDot
}
```

Target the portal-plane center or a Grandma chest/head point, not the animated door panel. The angular cone, dwell duration, line-of-sight requirement, and behavior when the door is open but unseen are author decisions.

Classification: **adapter required**. Do not add gaze polling to Turing Flow. `PlagueImmersiveCoordinator` already obtains head pose in its frame update and can pass the pose to Battle01.

## 10. Music integration

### Existing music owner

```text
Path: Gravitas Plague/Gravitas Plague/Audio/GravitasDemoAudioController.swift
Type: GravitasDemoAudioController
Symbols: startHordeMusicSequence(), stopHordeMusicSequence()
Classification: shared audio controller with Horde-specific music behavior
```

The Horde sequence owns Horde lifecycle and background-music behavior. It must not be invoked by Story Battle01.

Untracked candidate asset:

```text
Path: mrs-dempsey-prologue-battle.mp3
Duration: approximately 240.039 seconds
Size: 5,777,625 bytes
Current use: none; not committed
```

`pr-rich-battle-mrs-dempsey.mp3` is also untracked and likely dialogue/prerecording rather than soundtrack. Its intended use is **UNKNOWN** until specified.

Add a Story-owned `Battle01SoundtrackController` that retains one nonspatial player, is idempotent by `battleInstanceID`, and does not change `AVAudioSession` category. This keeps it compatible with screen recording and walkie speech. Existing fade/duck requirements are **UNKNOWN**.

Recommended technical predicate:

```text
doorReachedFullyOpen
AND grandmaArrivedAtDoorThreshold
AND soundtrackNotStartedForBattleInstance
```

Stop behavior is an author decision. Regardless of that choice, immersive shutdown, mode switch, and explicit Battle01 reset must stop and release it.

## 11. ScriptPoint03 trigger integration

### Existing completion chain

```text
Resource: Gravitas Plague/TuringResources/Turing/ScriptPoints/prologue.scriptPoint03.json
Flow engine: Gravitas Plague/Gravitas Plague/Turing/Flow/TuringFlowEngine.swift
Episode owner: Gravitas Plague/Gravitas Plague/Turing/Flow/TuringEpisodeFlowController.swift
```

`prologue.scriptPoint03` is terminal, has `automaticAdvance: false`, and ends at the microphone interaction gate.

`TuringFlowEngine` creates and awaits its playback-completion task before route finish, gate application, completion logging, and returning `.succeeded`. `TuringEpisodeFlowController.start(...)` calls the engine, records the script-point ID as complete only after success, and then exits because ScriptPoint03 does not auto-advance.

Therefore the correct trigger is not Foundation completion or Qwen completion. It is:

```text
TuringEpisodeFlowController receives a succeeded TuringFlowEngine result
for prologue.scriptPoint03 after actual route playback completion
```

No generic typed point-completion event bus is currently exposed. Add a mode-neutral event sink at the episode/action boundary:

```swift
protocol TuringScriptPointCompletionEventSink: AnyObject {
    @MainActor
    func scriptPointCompleted(
        id: String,
        episodeID: String,
        runID: UUID
    )
}
```

`TuringEpisodeFlowController` should emit this after it commits the completed ID. A Story episode action router can translate `prologue.scriptPoint03` completion into `Battle01Coordinator.prepareAndStart(...)` exactly once. No Horde or RealityKit details belong in Foundation prompts.

Longer term, a script command such as `battleStart` is cleaner than a hard-coded ID, but current production readiness of the EpisodeScriptCompiler battle command is **UNKNOWN**. The smallest safe interim hook is the typed completion event filtered by ID outside `TuringFlowEngine`.

Preload may begin during ScriptPoint03, but it must use a separate Story asset task and cannot delay or mutate Turing audio. Actual load time, clone cost, and memory overlap with Qwen are **UNKNOWN because this investigation did not run a headset measurement**. Add signposts before choosing the final preload point.

## 12. Recommended Battle01 state-machine architecture

### State graph

```text
unloaded
  ScriptPoint03 success -> preparing

preparing
  asset/context ready -> portalIdleFacingAway
  error/cancel -> cancelled

portalIdleFacingAway
  injected 5-second clock fires -> turnRightFirst
  cancel -> cancelled

turnRightFirst
  actual turn_right_90 completion -> turnRightSecond
  cancel/missing clip -> cancelled

turnRightSecond
  actual turn_right_90 completion -> walkingA1ToA2
  cancel/missing clip -> cancelled

walkingA1ToA2
  reaches A2 -> walkingA2ToA3
  cancel -> cancelled

walkingA2ToA3
  reaches A3 -> waitingForDoor
  cancel -> cancelled

waitingForDoor
  door already open and entry policy passed -> portalCrossing
  door closed -> openingDoor
  cancel -> cancelled

openingDoor
  actual door-open completion -> portalCrossing
  cancel/error -> cancelled

portalCrossing
  Horde-derived mirror handoff completes -> combat
  cancel -> cancelled

combat
  Grandma death/Battle01 resolution -> resolved
  cancel -> cancelled

resolved
  explicit debug reset -> unloaded

cancelled
  teardown completed -> unloaded or terminal cancellation
```

### Ownership table

| State | Existing owner | New owner | Entry | Exit truth | Cancellation |
|---|---|---|---|---|---|
| `unloaded` | None | `Battle01Coordinator` | None | Typed ScriptPoint03 success | No entities. |
| `preparing` | Prototype cache/door loader | Coordinator + `Battle01EnemyFactory` | Resolve door context and prepare one source/mirror | All resources validated | Cancel task, remove partial entities. |
| `portalIdleFacingAway` | Jock idle playback | Coordinator | Place at A1, show mirror, play idle | Injectable 5-second clock | Stop owned task; remove mirror/source. |
| `turnRightFirst` | Jock driver | Coordinator | Play `turn_right_90` | Matching clip completion token | Ignore stale completion by run/token. |
| `turnRightSecond` | Jock driver | Coordinator | Commit first yaw, replay clip | Matching second completion token | Same. |
| `walkingA1ToA2` | External-motion hooks | Coordinator | Walk loop and path motion | Distance reaches A2 | Stop external path. |
| `walkingA2ToA3` | External-motion hooks | Coordinator | Continue walk loop | Distance reaches A3 | Stop external path. |
| `waitingForDoor` | Existing door state | Coordinator | Idle and evaluate door/gaze policy | Door policy event | Unlock on teardown. |
| `openingDoor` | Door animation controller | Door adapter + coordinator | Lock interaction, request open | Actual open completion | Cancel wait; define whether physical door animation continues. |
| `portalCrossing` | Horde mirror primitives | Generic portal handoff adapter | Resume motion, sync mirror/source | Existing exit threshold | Disable combat, remove both. |
| `combat` | Jock enemy runtime | Story combat adapter | Enable world source combat | Death/resolution callback | Disable and remove. |
| `resolved` | None | Coordinator | Stop/transition music per policy | Explicit reset/new episode | Idempotent cleanup. |
| `cancelled` | None | Coordinator | One teardown path | Cleanup complete | Idempotent. |

### Proposed production contracts

These are architecture contracts only, not implemented code:

```swift
@MainActor
protocol ScriptedEnemyAnimating: AnyObject {
    func playIdleLoop() throws
    func playRightTurn90(
        token: UUID,
        completion: @escaping @MainActor (UUID, Result<Void, Error>) -> Void
    ) throws
    func playWalkLoop() throws
    func setExternalMotionDriven(_ enabled: Bool)
    func setCombatEnabled(_ enabled: Bool)
}

protocol BattleClock: Sendable {
    func sleep(for duration: Duration) async throws
}

@MainActor
protocol StoryEnemyCombatTakingOver: AnyObject {
    func activateCombat(
        enemy: JockRetargetTestController,
        battleInstanceID: UUID
    ) throws
    func cancelCombat(battleInstanceID: UUID)
}
```

`Task.sleep` is acceptable only behind `BattleClock` for the authored five-second idle. Turn, door, crossing, attack, and death transitions must be callback/event owned.

## 13. Story/Horde separation plan

### Reusable unchanged

```text
Jock animation decoding and retarget runtime
Grandma character sidecar and approved runtime clips
Jock follow/attack/damage/death implementation
HordePortalSkinnedRenderMirror pose-copy implementation
door USDZ, portal world, and existing door animation/SFX
PhaseOneSpatialProvider head pose
shared player damage presentation where it has no Horde score dependency
```

### Reusable through adapters

```text
Horde character prototype preparation
one-enemy controller construction
scripted animation calls and clip-completion observation
portal mirror/source handoff
combat activation on a pre-existing enemy
door open state, scripted opening, and interaction lock
script-point completion publication
Story soundtrack playback
```

### Must not be reused

```text
startHordeBenchmark
spawnNextHordeWave
Horde wave scheduler
Horde score and leaderboard updates
Horde announcer/HUD
Horde replacement-spawn logic
Horde music sequence
Horde enemy-count gates
Horde debug controls
```

Battle01 should receive a `StoryCombatContext` containing only player pose/target access, player damage/death callbacks, world root, lifecycle cancellation, and battle resolution. It should not read or set a global Horde-mode flag.

There must be one authoritative enemy source. The portal clone is always noninteractive. Death cleanup reports to Battle01 once and never asks the Horde coordinator for another wave.

## 14. Files to add

Recommended smallest set:

```text
Gravitas Plague/Gravitas Plague/Battle/Shared/ScriptedPortalEnemyIntroCoordinator.swift
Gravitas Plague/Gravitas Plague/Battle/Shared/ScriptedPortalEnemyProtocols.swift
Gravitas Plague/Gravitas Plague/Battle/Battle01/Battle01Coordinator.swift
Gravitas Plague/Gravitas Plague/Battle/Battle01/Battle01EnemyFactory.swift
Gravitas Plague/Gravitas Plague/Battle/Battle01/Battle01SoundtrackController.swift
Gravitas Plague/Gravitas Plague/Battle/Battle01/Battle01State.swift
Gravitas Plague/Gravitas PlagueTests/Battle/Battle01CoordinatorTests.swift
Gravitas Plague/Gravitas PlagueTests/Battle/Battle01PortalHandoffTests.swift
Gravitas Plague/Gravitas PlagueTests/Battle/Battle01LifecycleTests.swift
```

If the generic intro coordinator would be speculative before a second battle exists, use `Battle01Coordinator` internally but conform it to the shared protocols. Do not copy Horde source into a Battle01 directory.

## 15. Files to modify

Only after this investigation is reviewed:

| Path | Narrow change |
|---|---|
| `Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorBundleController.swift` | Resolve `zombie_a1/a2/a3`; expose immutable battle portal context; expose scripted-open/interaction-lock adapter. |
| `Gravitas Plague/Gravitas Plague/Turing/Props/TuringStoryDoorAnimationController.swift` | Expose read-only state and actual awaitable/tokenized completion; preserve existing door behavior. |
| `Gravitas Plague/Gravitas Plague/JockRetargetTestController.swift` | Add neutral scripted animation and Story combat adapter APIs; preserve Horde call paths. |
| `Gravitas Plague/Gravitas Plague/Turing/Flow/TuringEpisodeFlowController.swift` | Emit one typed script-point-completed event after success is committed. No speech changes. |
| `Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift` | Own/update/cancel Battle01; pass frame time/head pose/world dependencies; no Horde mode activation. |
| Xcode project/resource declarations | Include new Swift files and approved Battle01 soundtrack resource. |

Potential shared extraction:

```text
Gravitas Plague/Gravitas Plague/Horde/HordePortalInstancedIngressController.swift
```

Only extract `HordePortalSkinnedRenderMirror` behind a neutral protocol if necessary. Do not alter Horde thresholds or behavior during the extraction. Add Horde regression tests before changing this file.

## 16. Files that must not change

Battle01 implementation must not modify behavior in:

```text
Gravitas Plague/Gravitas Plague/Turing/TTS/**
Gravitas Plague/Gravitas Plague/Turing/Dialog/**
Gravitas Plague/Gravitas Plague/Turing/Audio/** generated-speech/filler/walkie playback ownership
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringFlowEngine.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringFlowRouteRuntime.swift
Gravitas Plague/Gravitas Plague/Turing/Flow/TuringCharacterRuntimeRegistry.swift
Gravitas Plague/Gravitas Plague/Turing/Interaction/TuringStoryWalkieInteractionController.swift
Gravitas Plague/TuringResources/Turing/Prompts/**
Gravitas Plague/TuringResources/Turing/Characters/** Rich and Big Mike definitions/profiles
Gravitas Plague/TuringResources/Turing/ScriptPoints/prologue.scriptPoint01.json
Gravitas Plague/TuringResources/Turing/ScriptPoints/prologue.scriptPoint02.json
Gravitas Plague/TuringResources/Turing/ScriptPoints/prologue.scriptPoint03.json
room scan, wall placement, placement adjustment, and prop-placement prompt behavior
```

`TuringEpisodeFlowController.swift` may receive only the generic completion event hook described above. No Foundation, Qwen, voice route, generated playback, filler, or microphone gate behavior should change.

Horde high-level behavior must remain separately testable and behaviorally unchanged.

## 17. Unit, integration, and device tests

### Unit tests

Proposed tests in `Gravitas Plague/Gravitas PlagueTests/Battle/Battle01CoordinatorTests.swift`:

```text
testScriptPoint03SuccessStartsBattleExactlyOnce
testScriptPoint03FailureDoesNotStartBattle
testIdleStartsAtA1FacingPortalExterior
testIdleUsesInjectedFiveSecondClock
testFirstTurnWaitsForMatchingActualCompletion
testSecondTurnDoesNotStartBeforeFirstCompletion
testWalkDoesNotStartBeforeSecondTurnCompletion
testStaleAnimationCompletionIsIgnored
testClosedDoorEntersIdleAndRequestsOneOpen
testMovementWaitsForActualDoorOpenCompletion
testAlreadyOpenDoorDoesNotReplayOpenAnimation
testMusicRequiresDoorOpenAndGrandmaAtThreshold
testMusicStartsOncePerBattleInstance
testDuplicateStartIsIgnored
```

Proposed path/handoff tests in `Battle01PortalHandoffTests.swift`:

```text
testDoorBundleResolvesLowercaseA1A2A3
testPathOrderIsA1ThenA2ThenA3
testMotionInterpolatesFullThreeDimensionalPath
testPathYawFollowsTangent
testPortalMirrorHasNoCombatAuthority
testWorldEntityIsNoninteractiveBeforeHandoff
testRevealOccursAtConfiguredPortalLocalThreshold
testOnlyWorldEntityCanAttackAfterHandoff
testMirrorIsRemovedAfterExitCompletion
testStoryCombatDoesNotStartHordeWaveState
```

Lifecycle tests in `Battle01LifecycleTests.swift`:

```text
testCancelDuringIdleRemovesOwnedEntities
testCancelDuringEitherTurnIgnoresLateCompletion
testCancelDuringWalkStopsExternalMotion
testCancelDuringDoorOpenUnlocksInteraction
testCancelDuringCrossingDisablesCombat
testResetStopsMusicAndRemovesMirrorAndWorldEnemy
testImmersiveShutdownUsesOneCleanupPath
testModeSwitchToHordeCancelsStoryBattleFirst
testGrandmaDeathResolvesBattleOnlyOnce
```

### Integration instrumentation

Every log should contain:

```text
battleInstanceID
battleID
enemyID
portalCloneEntityID
worldEnemyEntityID
doorState
state
animationName
anchorID
```

Required logs:

```text
[Battle01] prepared
[Battle01] triggeredAfterScriptPoint03
[Battle01] portal clone installed
[Battle01] idle started
[Battle01] idle completed
[Battle01] turn 1 started
[Battle01] turn 1 completed
[Battle01] turn 2 started
[Battle01] turn 2 completed
[Battle01] path segment started A1->A2
[Battle01] path segment completed A1->A2
[Battle01] path segment started A2->A3
[Battle01] arrived at door
[Battle01] waiting for door
[Battle01] door auto-open started
[Battle01] door auto-open completed
[Battle01] soundtrack started
[Battle01] portal handoff started
[Battle01] portal handoff completed
[Battle01] combat activated
[Battle01] resolved
[Battle01] cancelled
```

Anchor diagnostics must include imported local/world matrices, path distances, path slope, portal-plane signed distance, root-ground offset, and both foot/toe world heights.

### Headset acceptance matrix

Run all of these with state-correlated logs:

1. Door closed, player looking.
2. Door closed, player not looking.
3. Door open, player looking.
4. Door open, player not looking.
5. Player opens door while Grandma waits.
6. Player tries to close door during crossing.
7. Player stands near the portal before exit.
8. Player stands far from door.
9. Door is placed on each supported wall orientation.
10. Door is placed at a different detected floor elevation.
11. Normal authored A1/A2/A3 slope.
12. Exaggerated diagnostic slope.
13. Cancel during every state.
14. Grandma dies after transition.
15. Story reset and explicit replay.
16. System screen recording remains active.
17. Big Mike and Rich playback remain unchanged.
18. No Horde UI, score, wave, or music appears.

Acceptance additionally requires exactly one portal mirror, one source enemy, one music start, one combat activation, and one cleanup per `battleInstanceID`.

## 18. Author decisions still required

1. **Door open, player not looking:** wait at A3, enter immediately, or wait until seen?
2. **Door closed, player opens it while Grandma waits:** should the scripted open request be cancelled or treated as satisfied?
3. **Player attempts to close during crossing:** interaction disabled, close ignored, or allowed?
4. **Music timing:** opening start, full-open completion, A3 arrival when already open, or portal crossing?
5. **Music stop:** Grandma death, Battle01 resolved, player death, Prologue end, immersive shutdown only, or another authored event?
6. **Music fades/ducking:** required fade-in/fade-out and dialogue ducking values.
7. **Gaze definition:** cone angle, dwell, occlusion test, and target point.
8. **Animation episode approval:** approve current `approved_for_episode: false` idle/turn/walk clips or provide episode-approved copies.
9. **Grounding tolerance:** acceptable maximum foot/toe height error before foot IK becomes required.
10. **A3/crossing geometry:** confirm whether A3 is intended to be before the portal plane; device logs must establish this.
11. **Post-crossing marker:** decide whether a room-side authored attack-start marker is needed.
12. **Grandma push behavior:** idle only, authored push animation, or new SFX/contact point.
13. **Soundtrack asset:** confirm `mrs-dempsey-prologue-battle.mp3` and whether it loops.
14. **`pr-rich-battle-mrs-dempsey.mp3`:** identify its ScriptPoint/voice use; it is outside Battle01 music and must not be guessed.
15. **Replay/checkpoint:** whether Battle01 completion persists across Prologue restart or only the current immersive run.

## 19. Risks

| Risk | Consequence | Mitigation |
|---|---|---|
| `JockRetargetTestController` combines production and diagnostic history. | A naive new API can reset transforms or alter Horde behavior. | Add narrow adapter methods and Horde regression tests; do not use `playClip(id:loop:)` because it resets to the default spawn transform. |
| Existing Horde identity enables command-driven brain behavior. | Story combat could stall without Horde brain commands or accidentally activate Horde state. | Add explicit Story combat configuration/context. |
| Door open API lacks real completion. | Grandma can cross before the door clears. | Add tokenized/awaitable completion from the actual animation owner. |
| Door animation interruption computes coarse yaw. | Player interaction can make the panel jump. | Lock interaction during scripted opening/crossing and preserve interpolated yaw when adding adapter. |
| A1/A2/A3 have no authored rotation. | Initial and final heading can be ambiguous. | Derive from portal basis/path tangent or author rotations. Log validation. |
| Existing ingress assumes flat ground. | Grandma can float or penetrate the authored slope. | Battle-owned 3D path motion and root-ground offset; measure foot tolerance. |
| No foot IK exists. | Some foot sliding is expected on slope. | Device acceptance threshold, then add raycast/IK only if required. |
| A3 may not coincide with portal plane. | Reveal/handoff can pop or happen at the wrong depth. | Derive handoff from portal plane signed distance, not A3 identity. |
| Character clips are not episode-approved. | Production content-policy validation may reject them. | Explicit author approval/metadata pass before implementation acceptance. |
| Asset preload overlaps Qwen memory. | Memory pressure or TTS slowdown. | Instrument load time/footprint; schedule Story preload without modifying Qwen and choose timing from measurements. |
| Music controller changes audio session. | System recording or Turing audio can be interrupted. | New controller must not call `AVAudioSession.setCategory`; use existing centralized session policy. |
| Cleanup order races door/portal reset. | Late callbacks can access removed entities. | One coordinator, run IDs, cancellation tokens, and cleanup before door reset. |
| Generic event hook is added in the wrong layer. | Battle becomes coupled to TTS internals. | Emit only from `TuringEpisodeFlowController` after successful point completion. |

## 20. Exact next implementation order

No implementation should begin until this report and the author decisions in section 18 are reviewed.

1. Confirm the baseline tag and decide how to handle the two untracked audio files.
2. Confirm the soundtrack asset, loop/stop/fade policy, and the behavior for an open but unseen door.
3. Approve the current Grandma idle/turn/walk clips for episode use or provide approved versions.
4. Add a device-only anchor inspection that resolves `zombie_a1/a2/a3` and logs their imported matrices, portal-plane signed distances, path slopes, and frame clearance. Do not spawn combat yet.
5. Add unit-testable protocols for clock, scripted animation completion, door control, mirror handoff, combat takeover, music, gaze, and script-point completion.
6. Add the typed ScriptPoint completion sink to `TuringEpisodeFlowController`; prove ScriptPoint03 emits once only after actual playback completion. Run all Turing flow and Rich/Big Mike regressions.
7. Add read-only door state, interaction locking, and actual scripted-open completion while preserving existing tap/toggle behavior.
8. Add neutral scripted animation methods to `JockRetargetTestController`, including a second tokenized completion observer that does not replace internal completion handling.
9. Add `Battle01EnemyFactory` using the existing prototype cache without starting Horde mode. Measure load time, clone time, and memory.
10. Extract or adapt `HordePortalSkinnedRenderMirror` with behavior-locking Horde tests.
11. Implement A1 -> A2 -> A3 code-driven 3D motion and diagnostic foot-height logging before door/combat integration.
12. Implement the Battle01 state machine through `waitingForDoor`, with an injected clock and no music/combat yet.
13. Integrate scripted door opening and the selected gaze policy.
14. Integrate portal-plane crossing and verify source/mirror pose continuity on headset.
15. Add Story combat takeover on the existing enemy runtime, suppressing all Horde wave/score/UI/music side effects.
16. Add the Story-owned soundtrack controller with one-shot predicate and centralized audio-session compliance.
17. Add Battle01 cancellation to immersive shutdown, Story reset, mode switch, player death, and explicit debug replay.
18. Run the complete unit, integration, headset, system-recording, Turing voice, and Horde regression matrices.

Only after these pass should Battle01 be connected to normal Prologue progression by default.
