# Dad Vocal BlendShape Lip-Sync Pilot — Completion Report

> Historical Dad-pilot record. The production implementation has since been
> expanded to Dad, Grandma, Spouse, Biker, and Neighbor. Use
> `Docs/Fixed_Character_Vocal_Viseme_Completion_Report.md` for the current release
> status, verification totals, runtime routing, and device acceptance checklist.

Status: **BLOCKED only on Vision Pro acceptance evidence**. Dad now uses nine shipped, phone-derived pose tracks authored by the mechanically verified Angel pipeline. Resource validation, focused contract tests, and the generic visionOS app build pass. This report does not claim an in-headset result.

## 1. Repository state

- Branch: `main`
- Starting commit: `e4c5e5e0047f9f1e76d68f2468d8dc13e5357945`
- Corrected viseme implementation baseline: `614e0246b8ad3713ff6cb805dc015ad421afce6b`
- Delivery commit: not created; changes remain in the working tree.
- Delivery form: uncommitted worktree changes; nothing was staged or committed.
- Existing Turing optimization changes were preserved and not rewritten by this pilot.

The ending checkout remains intentionally dirty. It contains owner work and earlier
character/glyph/Turing changes outside this correction. None of those unrelated
changes were reset, stashed, cleaned, staged, or committed. The correction is
confined to the shared Angel authoring extraction, Dad viseme authoring/runtime
resources, focused contracts, and this report, plus the minimum descriptor routing
needed to keep the other character pilots working.

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
- SHA-256: `a08f6f72f563c6e4e29610e7f591832ab45a2f3861ea3226555fc1de80db5aeb`
- Size: 55,419,246 bytes
- Xcode status: copied into the built `Gravitas Plague.app`; the built copy has the same SHA-256.
- Target name: `dadVocalClose`
- Target prim: `/root/Armature/char1/char1_dadVocalClose`
- Driven mesh: `/root/Armature/char1/char1`
- Direction: weight `0.0` is the production default wide/open mouth; `0.5` is small/round; `1.0` is the owner-authored closed/tense mouth.
- Sparse target records: 3,707 of 144,525 source points, derived from the current owner-authored donor rather than fixed in the tool.
- Displacement: mean 0.007244 m, RMS 0.009295 m, maximum 0.024946 m.
- Donor asset: `dad_biped_mouth_closed.usdz` remains authoring-only, ignored, and absent from the app bundle.
- Donor-only `/root/Cube`, `/root/Camera`, and `/root/Light` are absent from production.
- `usdchecker`: PASS.

RealityKit's public `blendShapeOffsets(named:)` accessor reports an all-zero compatibility buffer for Dad. The importer separately preserves the real target in its native `dadVocalClose|blendTargetPosDeltas` render buffer. A sparse payload is retained to validate that native buffer exactly; it is not written back into the mesh:

- Payload: `dad_infected_vocal_blendshape_offsets.bin`
- SHA-256: `ed02b06b87f8d5d456a15a38543a9b5d409a277283ab1ec9b990658b8b9b530d`
- Size: 103,854 bytes
- Contract: one mesh, 3,707 sorted records, exact render-to-source index and delta validation.

The authoring tool no longer hard-codes a changed-point count or displacement ceiling. It imports every meaningful owner-authored point delta and reports the resulting coverage and displacement. When Blender exports `dadVocalClose` as a bound shape key, the tool evaluates that target over the donor Basis before comparing it with production; this prevents an updated shape key from being silently discarded. The current donor supplies 144,525 indexed shape-key records with 3,622 nonzero offsets; evaluation against the production Basis produces 3,707 sparse target records. A donor without that named target retains the destructive-sculpt `Mesh.points` fallback. Donor-side Blender armature names and skin-weight serialization are ignored because none of that data is copied; production topology, skeleton, materials, animation, textures, and bind state remain authoritative.

### Horde device correction

The first Horde device run proved that all nine audio tracks prepared successfully, but visual registration stopped at the mesh-repair gate. The gate incorrectly inherited Angel's assumption that RealityKit would add no more than 64 render vertices.

The previous 2,004-point target used during the initial device diagnosis imported as:

```text
USD control points:                 144,525
RealityKit render positions:        172,668
RealityKit seam duplicates:          28,143
Authored changed control points:      2,004
Render vertices requiring offsets:    2,479
Affected seam duplicates:               475
```

Those original 144,525 imported positions and all 2,004 historical sparse anchors matched the prior USD positions exactly. RealityKit's native `originalPartVertexIndex` map expanded them to 2,479 affected render vertices, including 475 seam duplicates. These figures document the earlier device diagnosis, not the current evaluated donor target.

The next Horde device run exposed why the initial runtime-repair approach was unsafe: even a no-op `mesh.replace(with: mesh.contents)` on this imported skinned asset drops its skeleton collection and changes its private coordinate basis. Jock then animates an invalid mesh and the character stretches apart. The runtime no longer calls `mesh.replace` or regenerates Dad's mesh. It validates RealityKit's already-correct native delta buffer against every payload record, uploads those immutable render-vertex deltas once, and applies them with a visionOS 27 GPU `MeshDeformer` before RealityKit's blend-shape and skinning deformers. Only the small scalar mouth weight changes at runtime. A missing or mismatched native buffer disables only the visual pilot rather than mutating Dad's mesh.

RealityKit does not preserve a custom mesh deformer when this imported model is cloned. The physical Dad and every portal mirror therefore receive separately installed bindings while sharing the same authored pose clock. Teardown removes/restores a deformer component only while the component is still owned by that exact binding.

The custom GPU deformer remains on-demand: the scalar changes only during mouth transitions, and RealityKit caches its pre-skinning output. The replacement stack ends with RealityKit's `BoundingBoxCalculator` after skinning so animated world bounds follow the complete posed character; omitting that terminal pass caused camera-dependent close-up clipping and pixelated passthrough scanlines around Dad's head. A host probe installed weight `1.0` once, changed Dad's joint transforms for 60 renders, observed no redundant custom callbacks, and produced a final image byte-identical to the original closed render. Idle and silence request `.rest` at weight `1.0`.

An equivalent CPU custom deformer was rejected after measurement: although geometrically correct, it added roughly 19 ms on changing host frames. The Metal path preserved Dad's body and a posed Jock arm in the render probe. Two quiet host runs measured approximately 0.23–0.38 ms incremental GPU-completion wall time; a loaded host run measured 2.17 ms, so on-device performance remains part of the required acceptance pass.

The next Horde device log did not exercise that GPU path. It reached `mesh ready` and then disabled the visual with `Character vocal blendshape binding is stale` before controller registration, track joining, weight assignment, or a RealityKit callback. Two invalid identity assumptions caused that rejection: the ownership guard compared RealityKit's normalized imported deformation stack before first installation, and the resolver treated the transient Swift `MeshResource` wrapper's `ObjectIdentifier` as persistent across an async suspension. RealityKit can recreate and coalesce those wrappers even while the same entity, native mesh, target, and vertex contract remain intact. First installation now intentionally replaces the captured imported stack; subsequent ownership checks apply only to the binding's installed stack; and binding validity uses the stable entity/target/group contract rather than wrapper identity. Device logs now distinguish `binding installed`, `registered`, `track joined`, and subsequent pose/target-weight transitions so setup can no longer be mistaken for live deformation.

The current source target contains 3,707 exact sparse offsets, which RealityKit maps to 4,589 moved render vertices including 882 seam duplicates. It renders visibly closed/tense at weight `1.0`, while weight `0.0` retains the wide/open source mouth. Clean import inspection confirms that the large displacement is now carried by the jaw and chin while the upper lip remains comparatively stable. The production Basis is unchanged, and the prior target is replaced rather than stacked. On-demand output remained stable through alternating joint transforms. Source/mirror parity and performance still require the device acceptance pass below.

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
| animated presence loop | `dad_breathing.wav` | 30.000 s | `db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb` |
| damage | `Gravitas Plague/Gravitas Plague/Audio/dad-damaged-01.wav` | 4.500 s | `fd079a1794c72cd18b565a7398bbb3d601c18fce8be68c85578d0d10f67bf7a5` |
| damage | `Gravitas Plague/Gravitas Plague/Audio/dad-damaged-02.wav` | 5.000 s | `024cc7fc72276ac2501c729faa97aa5ef855f2739af4d1eba408a6304eca3e71` |
| damage | `Gravitas Plague/Gravitas Plague/Audio/dad-damaged-03.wav` | 5.000 s | `e28f6eba93636333ead99be7b9059bd9742136375b4aaf87fa1ab1e4e6581da1` |
| damage | `Gravitas Plague/Gravitas Plague/Audio/dad-damaged-04.wav` | 5.000 s | `4f5fd5842e046ab7a0fc3fb51d4fe38eb5ad4d2f923b3bacf53cb9fa262a2cbf` |
| death | `Gravitas Plague/Gravitas Plague/Audio/dad-death-01.wav` | 5.000 s | `670ff38fd3eb5e8f95d1b5848ec346b9a9e7b2f1b610b61a4c6f93e97d40b2f4` |
| death | `Gravitas Plague/Gravitas Plague/Audio/dad-death-02.wav` | 5.000 s | `bedad39a231b62e7acb4fc7462680d62d84367e5b3e341ccfe4761774853fcff` |
| death | `Gravitas Plague/Gravitas Plague/Audio/dad-death-03.wav` | 5.000 s | `a06c5cf435c3597d7bbd6e98023dc170250e9a95c8bd807fda2ecb67746ff0dc` |
| death | `Gravitas Plague/Gravitas Plague/Audio/dad-death-04.wav` | 5.000 s | `48d97a9a5558870a4ba4ee238f805ca4dd86465ffe3bace1898036f66b9dd205` |

`dad_breathing.wav` is both the audible spatial presence loop and the persistent idle mouth-animation clock. Existing narrow exceptions cover the damage/death banks. Face-hit and attack sounds remain excluded from the vocal driver.

## 6. Analysis, cache, and playback ownership

- The former Dad runtime `TuringGeneratedSpeechAnalyzer(configuration: .production)` path is removed. Dad no longer derives mouth poses from amplitude, energy, zero crossings, or a compatibility envelope.
- The shared host authoring core is the exact checked-in Angel Python pipeline: pinned PocketSphinx 5.1.1 all-phone recognition, the existing phone-to-pose map, boundary adjudication, coarticulation, minimum holds, and contiguous 60-fps pose runs.
- Before any Dad output is accepted, the compiler regenerates the Angel pose-run payload and requires the exact production hash `6a48f84827b2842fb3199c1bf4965113b3a65f8c55eedd7c0b23772c983b4a8a`.
- Dad's nonverbal groans and breathing are boundary-gated by PocketSphinx non-silence phone intervals. This preserves phone-derived pose identity while avoiding Silero's measured behavior of classifying seven of the nine nonverbal clips as entirely nonspeech/rest. The Angel path remains byte-identical and continues to use its original Silero policy.
- The authoring tool produces one catalog and nine deterministic manifests: one breathing loop, four damage vocals, and four death vocals. Face-hit and attack audio are rejected from the inventory.
- Production runtime performs no Dad WAV decoding, PCM retention, PocketSphinx work, transcription, loudness calculation, or pose analysis. It loads and validates the tiny JSON resources sequentially off-main, including source-audio, descriptor, model, and run hashes, then retains only immutable compact runs and identities.
- Concurrent Dad requests coalesce on one catalog-loading task. Audio is never delayed by visual readiness; a late exact track joins at the current `ContinuousClock` playback phase.
- The previous analyzer remains isolated in `CharacterPerformance/Compatibility` only for Grandma, Spouse, Biker, and Neighbor until those characters receive their own authored catalogs. That compatibility worker explicitly rejects `characterID == "dad"`.

Exact playback ownership is published only after RealityKit returns the controller that actually started. Every identity contains playback ID, source ID, character, archetype, role, exact selected filename, and looping status, with a `ContinuousClock.Instant` origin. Replacement cancels the old exact identity. Natural completion removes only an exact identity match, so stale completion cannot clear a newer vocal. Watchdog expiry publishes cancellation, never natural completion.

Damage and death replace the current per-source one-shot visually and audibly. While a one-shot is active, its pose track overrides the breathing pose without stopping the breathing clock. When the one-shot ends, breathing resumes at its current modulo phase rather than restarting. Death remains terminal and settles to the closed/rest weight after its vocal completes. Face-hit impact and Rich speech publish no Dad vocal event.

## 7. Physical Dad and portal integration

- Registration is keyed by the exact physical Dad source UUID.
- The final Chapter 1 Dad is registered after its source and portal mirror exist, before its presence loop starts.
- Horde Dad is registered when the portal visual appears, so the portal mirror breathes before the physical room-side source is revealed; room reveal preserves the existing loop and clock.
- The Chapter 1 Dad window attaches its runtime controller to the same presence-loop system and detaches the exact source before releasing its runtime lease.
- The established immersive frame tick applies the smoothed scalar; it does not perform analysis or binding discovery.
- The final-battle portal source and mirror receive the same controller scalar through explicit custom-deformer bindings.
- Horde portal mirrors are explicitly rebound after cloning because custom deformers do not survive `clone(recursive:)`; the legacy blendweight copier alone cannot drive this target because its public imported weight remains zero.
- There is no second pose clock for a mirror.
- Per-source removal cancels registration/tasks, restores rest, rejects stale events, and removes weak bindings.
- Non-Dad archetypes are ignored by the registry.

## 8. Verification

PASS:

- Dad authored-viseme Python contract tests: 6/6.
- Dad/shared runtime Python contract tests: 19/19.
- Grandma, Spouse, Biker, and Neighbor compatibility regression suites: 5/5 each.
- Host authoring `--golden-angel`: exact run hash `6a48f84827b2842fb3199c1bf4965113b3a65f8c55eedd7c0b23772c983b4a8a`.
- Host authoring `--check`: catalog and all nine manifests validate without rewriting source outputs.
- Two consecutive full `--write` authoring runs reported `changed: []`; catalog and all nine manifest byte hashes remained identical before, between, and after both runs.
- `usdchecker dad_biped.usdz`.
- Swift syntax parse for all new/modified pilot sources and focused tests.
- Focused Dad contract test file type-check against the built arm64-xros `Gravitas_Plague` module.
- Portal parity helper tests: isolated helper cases pass.
- `git diff --check`.
- Generic visionOS Debug app build, signing disabled: `** BUILD SUCCEEDED **`.
- Generic visionOS Release app build, signing disabled: `** BUILD SUCCEEDED **`.
- Dad GPU render probe: exact 172,668-vertex `.float3`/12-byte-stride callback; weight 0/1 deformation remained confined to the face; Jock arm skinning remained intact; 190 alternating updates were byte-stable with no accumulation.
- Built app `default.metallib` contains `characterVocalApplyDenseOffsets`.
- Built app contains the production Dad USDZ, descriptor, validation payload, Dad viseme catalog, all nine unique viseme manifests, and all nine exact animation-driving WAVs, including the breathing loop.
- Built app contains no mouth-closed donor USDZ.
- Built app contains no copied audio under the Dad viseme resource folder and no Dad blendshape/viseme authoring inputs, reports, compiler tools, or donor assets.
- Static rejection audits find no runtime Dad analyzer/WAV decode path and no face-hit or attack asset in the authored catalog.
- Release bundle audit finds exactly one Dad catalog and nine Dad viseme manifests, all byte-identical to source; no audio is duplicated under `DadVisemes`, and no host compiler/tool/test source leaked into the app.

Project-wide hosted test execution is currently blocked before test launch by unrelated existing Turing test-support actor-isolation drift, beginning with:

- `TuringAudiobookSegmentationResponseDecoderTests.swift:194`: actor `ToolCallFoundationRunner` cannot conform to the `@MainActor`-isolated `TuringFoundationQueryRunning` protocol.
- `TuringFlowTestSupport.swift:135`: actor `ControlledVoicePromptService` conflicts with the `@MainActor`-isolated `TuringFlowVoicePromptGenerating` protocol.
- `TuringFlowTestSupport.swift:233`: actor `StubCharacterRenderer` conflicts with the `@MainActor`-isolated `TuringCharacterRendering` protocol.

The `build-for-testing` command exits 65 before any test launches and emits no Dad pilot diagnostic. These unrelated test-support failures were not changed as part of this correction.

## 9. Remaining required device pass

The code is ready for a Vision Pro acceptance run, but the pilot is not declared complete until that evidence exists. Exercise:

1. The Chapter 1 final Dad presence loop remains audible and animates the mouth during idle; damage and death override it, then breathing resumes at the current loop phase.
2. All four damage recordings, including rapid replacement and a face-hit-only comparison.
3. All four death recordings and the terminal closed/rest settle.
4. Source/mirror visual parity while crossing the portal.
5. Cancel/retry/Continue, then a second full run.
6. Geometry, skinning, materials, teeth/cavity, audio gain/selection/spatial position, combat, Jock reactions, and story progression against baseline.
7. Confirm no decode/analysis is logged during a hit, `[CharacterVocalViseme] Dad catalog ready tracks=9 ... runtimeAudioDecode=false runtimeAnalysis=false` appears during prewarm, and every selected file logs an exact track join.

Until those observations are recorded, final qualification remains **BLOCKED**, not failed.
