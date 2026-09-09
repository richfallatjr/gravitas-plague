# Dad Vocal BlendShape Lip-Sync Pilot — Completion Report

Status: **BLOCKED only on Vision Pro acceptance evidence**. The implementation, authored production asset, resource validation, focused contract type-check, and generic visionOS app build pass. This report does not claim an in-headset result.

## 1. Repository state

- Branch: `main`
- Starting commit: `e4c5e5e0047f9f1e76d68f2468d8dc13e5357945`
- Ending commit: `e4c5e5e0047f9f1e76d68f2468d8dc13e5357945`
- Delivery form: uncommitted worktree changes; nothing was staged or committed.
- Existing Turing optimization changes were preserved and not rewritten by this pilot.

Final `git status --porcelain=v1` snapshot before this report was written:

```text
 M .gitignore
 M Docs/Turing_System_Stability_Architect_Handoff.md
 M "Gravitas Plague/Gravitas Plague/Battle/Shared/StoryPortalEnemyRenderMirrorAdapter.swift"
 M "Gravitas Plague/Gravitas Plague/GravitasDemoAudioController.swift"
 M "Gravitas Plague/Gravitas Plague/Horde/HordePortalInstancedIngressController.swift"
 M "Gravitas Plague/Gravitas Plague/PlagueCharacterArchetype.swift"
 M "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
 M "Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter01/DadFinalBattle/Chapter01DadBattleEnemyFactory.swift"
 M "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringQwenOutputPostProcessor.swift"
 M "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringSpatialAudioEndpoint.swift"
 M "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenBenchmark/main.swift"
 M "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeBaseCloneEngine.swift"
 M "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeFreshInstance.swift"
 M "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeGenerationLane.swift"
 M "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeLaneStream.swift"
 M "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeParallelLanePool.swift"
 M "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeParallelScheduler.swift"
 M ThirdParty/LocalSwiftPackages/mlx-swift/Source/MLX/Stream.swift
 M ThirdParty/LocalSwiftPackages/mlx-swift/Tests/MLXTests/StreamTests.swift
?? Authoring/DadVocalBlendShape/
?? Docs/TuringBenchmarks/phase5-host-quick.json
?? Docs/Turing_Optimization_Phase_4_Completion_Report.md
?? Docs/Turing_Optimization_Phase_5_Completion_Report.md
?? "Gravitas Plague/Gravitas Plague/CharacterLibrary/FacialPerformance/"
?? "Gravitas Plague/Gravitas Plague/CharacterPerformance/"
?? "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringPCMStreamBuffer.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringPCMStreamProducerStore.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringPCMStreamRateConverter.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringPCMStreamTypes.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringQwenDeterministicTimeStretcher.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringQwenStreamingOutputPostProcessor.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/Audio/TuringRealityKitPCMStreamBridge.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeExperimentalStreaming.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativeGrowingPrefixSpeechDecoder.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativePhase5BenchmarkMatrix.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Sources/TuringQwenNative/TuringQwenNativePhase5Qualification.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Tests/TuringQwenNativeTests/TuringQwenNativeExperimentalStreamingTests.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Tests/TuringQwenNativeTests/TuringQwenNativeLaneStreamTests.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Tests/TuringQwenNativeTests/TuringQwenNativePhase5BenchmarkMatrixTests.swift"
?? "Gravitas Plague/Gravitas Plague/Turing/QwenNative/Tests/TuringQwenNativeTests/TuringQwenNativePhase5QualificationTests.swift"
?? "Gravitas Plague/Gravitas PlagueTests/Battle/HordePortalBlendShapeWeightGroupParityTests.swift"
?? "Gravitas Plague/Gravitas PlagueTests/CharacterPerformance/"
?? "Gravitas Plague/Gravitas PlagueTests/Turing/Audio/TuringPCMStreamFoundationTests.swift"
?? "Gravitas Plague/Gravitas PlagueTests/Turing/Audio/TuringQwenStreamingOutputPostProcessorTests.swift"
?? Scripts/build_dad_vocal_blendshape.sh
?? Scripts/dad_vocal_blendshape.py
?? Scripts/dad_vocal_blendshape/
?? Scripts/tests/dad_vocal_blendshape/
?? Tools/Turing/benchmark_qwen_phase5.sh
?? dad_biped.usdz
?? dad_breathing.wav
```

## 2. Pilot files

Added:

- `Authoring/DadVocalBlendShape/dad_vocal_close_source.json`
- `Authoring/DadVocalBlendShape/Reports/dad_vocal_close.validation.json`
- `Scripts/build_dad_vocal_blendshape.sh`
- `Scripts/dad_vocal_blendshape.py`
- `Scripts/dad_vocal_blendshape/*.py`
- `Scripts/tests/dad_vocal_blendshape/test_runtime_contract.py`
- `Gravitas Plague/Gravitas Plague/CharacterLibrary/FacialPerformance/dad_infected_vocal_blendshape.json`
- `Gravitas Plague/Gravitas Plague/CharacterLibrary/FacialPerformance/dad_infected_vocal_blendshape_offsets.bin`
- `Gravitas Plague/Gravitas Plague/CharacterPerformance/VocalBlendShape/*.swift`
- `Gravitas Plague/Gravitas Plague/CharacterPerformance/VocalBlendShape/CharacterVocalBlendShapeDeformer.metal`
- `Gravitas Plague/Gravitas PlagueTests/CharacterPerformance/DadVocalBlendShapeContractTests.swift`
- `Gravitas Plague/Gravitas PlagueTests/Battle/HordePortalBlendShapeWeightGroupParityTests.swift`

Changed for integration:

- `.gitignore`
- `dad_biped.usdz`
- `GravitasDemoAudioController.swift`
- `PlagueImmersiveCoordinator.swift`
- `PlagueCharacterArchetype.swift`
- `Chapter01DadBattleEnemyFactory.swift`
- `StoryPortalEnemyRenderMirrorAdapter.swift`
- `HordePortalInstancedIngressController.swift`

## 3. Canonical asset and target proof

- Canonical production USDZ: repository root `dad_biped.usdz`
- SHA-256: `8549be0963c2e20c10f7b942e3db35e2bfca0416876b12110546b5aedd6439e6`
- Size: 55,331,751 bytes
- Xcode status: copied into the built `Gravitas Plague.app`; the built copy has the same SHA-256.
- Target name: `dadVocalClose`
- Target prim: `/root/Armature/char1/char1_dadVocalClose`
- Driven mesh: `/root/Armature/char1/char1`
- Direction: weight `0.0` is the production default wide/open mouth; `0.5` is small/round; `1.0` is the owner-authored closed/tense mouth.
- Sparse target records: 2,004 of 144,525 source points.
- Displacement: mean 0.001606 m, RMS 0.002701 m, maximum 0.012514 m.
- Donor asset: `dad_biped_mouth_closed.usdz` remains authoring-only, ignored, and absent from the app bundle.
- Donor-only `/root/Cube`, `/root/Camera`, and `/root/Light` are absent from production.
- `usdchecker`: PASS.

RealityKit's public `blendShapeOffsets(named:)` accessor reports an all-zero compatibility buffer for Dad. The importer separately preserves the real target in its native `dadVocalClose|blendTargetPosDeltas` render buffer. A sparse payload is retained to validate that native buffer exactly; it is not written back into the mesh:

- Payload: `dad_infected_vocal_blendshape_offsets.bin`
- SHA-256: `c77649e5218dfd095da4fda580e45a1f325a33ab6b6406b97a8c6de0a40be67e`
- Size: 56,170 bytes
- Contract: one mesh, 2,004 sorted records, exact render-to-source index and delta validation.

### Horde device correction

The first Horde device run proved that all nine audio tracks prepared successfully, but visual registration stopped at the mesh-repair gate. The gate incorrectly inherited Angel's assumption that RealityKit would add no more than 64 render vertices.

Dad's locked asset imports as:

```text
USD control points:                 144,525
RealityKit render positions:        172,668
RealityKit seam duplicates:          28,143
Authored changed control points:      2,004
Render vertices requiring offsets:    2,479
Affected seam duplicates:               475
```

The original 144,525 imported positions and all 2,004 sparse anchors match the locked USD positions exactly. RealityKit's native `originalPartVertexIndex` map expands them to exactly 2,479 affected render vertices, including 475 seam duplicates.

The next Horde device run exposed why the initial runtime-repair approach was unsafe: even a no-op `mesh.replace(with: mesh.contents)` on this imported skinned asset drops its skeleton collection and changes its private coordinate basis. Jock then animates an invalid mesh and the character stretches apart. The runtime no longer calls `mesh.replace` or regenerates Dad's mesh. It validates RealityKit's already-correct native delta buffer against every payload record, uploads those immutable render-vertex deltas once, and applies them with a visionOS 27 GPU `MeshDeformer` before RealityKit's blend-shape and skinning deformers. Only the small scalar mouth weight changes at runtime. A missing or mismatched native buffer disables only the visual pilot rather than mutating Dad's mesh.

RealityKit does not preserve a custom mesh deformer when this imported model is cloned. The physical Dad and every portal mirror therefore receive separately installed bindings while sharing the same authored pose clock. Teardown removes/restores a deformer component only while the component is still owned by that exact binding.

An equivalent CPU custom deformer was rejected after measurement: although geometrically correct, it added roughly 19 ms on changing host frames. The Metal path preserved Dad's body and a posed Jock arm in the render probe. Two quiet host runs measured approximately 0.23–0.38 ms incremental GPU-completion wall time; a loaded host run measured 2.17 ms, so on-device performance remains part of the required acceptance pass.

The next Horde device log did not exercise that GPU path. It reached `mesh ready` and then disabled the visual with `Character vocal blendshape binding is stale` before controller registration, track joining, weight assignment, or a RealityKit callback. Two invalid identity assumptions caused that rejection: the ownership guard compared RealityKit's normalized imported deformation stack before first installation, and the resolver treated the transient Swift `MeshResource` wrapper's `ObjectIdentifier` as persistent across an async suspension. RealityKit can recreate and coalesce those wrappers even while the same entity, native mesh, target, and vertex contract remain intact. First installation now intentionally replaces the captured imported stack; subsequent ownership checks apply only to the binding's installed stack; and binding validity uses the stable entity/target/group contract rather than wrapper identity. Device logs now distinguish `binding installed`, `registered`, `track joined`, and subsequent pose/target-weight transitions so setup can no longer be mistaken for live deformation.

The exact production resolver/controller probe subsequently passed five fresh runs: source and recursive mirror each resolved one binding, both first installations reached weight `1.0`, both were driven to exact `0.0`, their renders matched, and the visual difference remained confined to the same 21 × 22 pixel mouth region. Shutdown restored both original imported empty deformer components.

The authoring shell also now treats `--check-only` as read-only; it no longer rebuilds the production USDZ during validation.

## 4. Runtime descriptor

The versioned descriptor locks:

```text
descriptorID = dad.infected.vocalBlendShape.v1
blendShapeName = dadVocalClose
basePose = wide
wide = 0.00
small = 0.50
round = 0.50
rest = 1.00
teeth = 1.00
fallback = 1.00
increasing/closing half-life = 0.050 s
decreasing/opening half-life = 0.030 s
intermediate crossing half-life = 0.035 s
maximum frame delta = 0.050 s
assignment epsilon = 0.0005
```

The descriptor, 55 MB production USDZ, and sparse payload are read, decoded, hashed, and parsed off-main. Descriptor or native-buffer validation failure disables only the visual pilot; audio, combat, Jock animation, portal progression, and story continue.

## 5. Exact Dad vocal inventory

All files are PCM signed 16-bit little-endian, 48 kHz, stereo WAVs.

| Role | File/path | Duration | SHA-256 |
|---|---|---:|---|
| presence loop | `dad_breathing.wav` | 30.000 s | `db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb` |
| damage | `Gravitas Plague/Gravitas Plague/Audio/dad-damaged-01.wav` | 4.500 s | `fd079a1794c72cd18b565a7398bbb3d601c18fce8be68c85578d0d10f67bf7a5` |
| damage | `Gravitas Plague/Gravitas Plague/Audio/dad-damaged-02.wav` | 5.000 s | `024cc7fc72276ac2501c729faa97aa5ef855f2739af4d1eba408a6304eca3e71` |
| damage | `Gravitas Plague/Gravitas Plague/Audio/dad-damaged-03.wav` | 5.000 s | `e28f6eba93636333ead99be7b9059bd9742136375b4aaf87fa1ab1e4e6581da1` |
| damage | `Gravitas Plague/Gravitas Plague/Audio/dad-damaged-04.wav` | 5.000 s | `4f5fd5842e046ab7a0fc3fb51d4fe38eb5ad4d2f923b3bacf53cb9fa262a2cbf` |
| death | `Gravitas Plague/Gravitas Plague/Audio/dad-death-01.wav` | 5.000 s | `670ff38fd3eb5e8f95d1b5848ec346b9a9e7b2f1b610b61a4c6f93e97d40b2f4` |
| death | `Gravitas Plague/Gravitas Plague/Audio/dad-death-02.wav` | 5.000 s | `bedad39a231b62e7acb4fc7462680d62d84367e5b3e341ccfe4761774853fcff` |
| death | `Gravitas Plague/Gravitas Plague/Audio/dad-death-03.wav` | 5.000 s | `a06c5cf435c3597d7bbd6e98023dc170250e9a95c8bd807fda2ecb67746ff0dc` |
| death | `Gravitas Plague/Gravitas Plague/Audio/dad-death-04.wav` | 5.000 s | `48d97a9a5558870a4ba4ee238f805ca4dd86465ffe3bace1898036f66b9dd205` |

`dad_breathing.wav` now has the narrow root exception `!/dad_breathing.wav`. It is unignored and appears in `git status` as an untracked production input awaiting the owner’s eventual commit. Existing narrow exceptions cover the damage/death banks. Face-hit and attack sounds are excluded from the vocal driver.

## 6. Analysis, cache, and playback ownership

- The existing deterministic `TuringGeneratedSpeechAnalyzer(configuration: .production)` produces the canonical 60-fps pose tracks.
- No Qwen, Foundation Models, PocketSphinx, transcription, forced alignment, or network work is used.
- The nine files prewarm sequentially on one dedicated serial utility queue.
- Hashing, WAV decoding, PCM conversion, and pose analysis occur only in `CharacterVocalPoseTrackStore.swift`.
- Only compact `TuringGeneratedSpeechFrameTrack` results are cached; decoded PCM and envelopes are released.
- Concurrent requests for the same asset coalesce on one preparation task.
- No analysis, decode, file I/O, model load, or blendshape resolution occurs in the hit callback or per-frame update.

Exact playback ownership is published only after RealityKit returns the controller that actually started. Every identity contains playback ID, source ID, character, archetype, role, exact selected filename, and looping status, with a `ContinuousClock.Instant` origin. Replacement cancels the old exact identity. Natural completion removes only an exact identity match, so stale completion cannot clear a newer vocal. Watchdog expiry publishes cancellation, never natural completion.

Damage and death replace the current per-source one-shot visually and audibly. Presence keeps its original clock while hidden and resumes at its current modulo frame. Death is terminal and settles to the closed/rest weight after its vocal completes. Face-hit impact and Rich speech publish no Dad vocal event.

## 7. Physical Dad and portal integration

- Registration is keyed by the exact physical Dad source UUID.
- The final Chapter 1 Dad is registered after its source and portal mirror exist, before its presence loop starts.
- The established immersive frame tick applies the smoothed scalar; it does not perform analysis or binding discovery.
- The final-battle portal source and mirror receive the same controller scalar through explicit custom-deformer bindings.
- Horde portal mirrors are explicitly rebound after cloning because custom deformers do not survive `clone(recursive:)`; the legacy blendweight copier alone cannot drive this target because its public imported weight remains zero.
- There is no second pose clock for a mirror.
- Per-source removal cancels registration/tasks, restores rest, rejects stale events, and removes weak bindings.
- Non-Dad archetypes are ignored by the registry.

## 8. Verification

PASS:

- Dad authoring/runtime Python contract tests: 3/3.
- `usdchecker dad_biped.usdz`.
- Swift syntax parse for all new/modified pilot sources and focused tests.
- Focused Dad contract test file type-check against the built arm64-xros `Gravitas_Plague` module.
- Portal parity helper tests: isolated helper cases pass.
- `git diff --check`.
- Generic visionOS Debug app build, signing disabled: `** BUILD SUCCEEDED **`.
- Dad GPU render probe: exact 172,668-vertex `.float3`/12-byte-stride callback; weight 0/1 deformation remained confined to the face; Jock arm skinning remained intact; 190 alternating updates were byte-stable with no accumulation.
- Built app `default.metallib` contains `characterVocalApplyDenseOffsets`.
- Built app contains the production Dad USDZ, descriptor, validation payload, and all nine exact WAV hashes.
- Built app contains no mouth-closed donor USDZ.
- Static rejection audits find no prohibited ML/transcription dependency and no face-hit asset in the pilot folder.

Project-wide hosted test execution is currently blocked before test launch by pre-existing Mind’s Eye test API drift, specifically:

- `TuringGeneratedPlaybackPreparedClipTests.swift`: missing newer generated-analysis coordinator/policy initializer arguments.
- `TuringRuntimeLipSyncManifestTests.swift`: obsolete `.manifest` access on `TuringRuntimeLipSyncManifest`.

The build emitted no Dad pilot test diagnostics. These unrelated test failures were not changed as part of this scoped implementation.

## 9. Remaining required device pass

The code is ready for a Vision Pro acceptance run, but the pilot is not declared complete until that evidence exists. Exercise:

1. The Chapter 1 final Dad presence loop.
2. All four damage recordings, including rapid replacement and a face-hit-only comparison.
3. All four death recordings and the terminal closed/rest settle.
4. Source/mirror visual parity while crossing the portal.
5. Cancel/retry/Continue, then a second full run.
6. Geometry, skinning, materials, teeth/cavity, audio gain/selection/spatial position, combat, Jock reactions, and story progression against baseline.
7. Confirm no decode/analysis is logged during a hit and capture prewarm timings from `[DadVocalTrack]` logs.

Until those observations are recorded, final qualification remains **BLOCKED**, not failed.
