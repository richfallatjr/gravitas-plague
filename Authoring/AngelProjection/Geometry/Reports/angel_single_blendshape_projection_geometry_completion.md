# Angel single-blendshape projection geometry completion report

## Final status

- Decision: BLOCKED only on physical Vision Pro performance/shading review and owner sculpt approval; implementation, automated capture, Simulator, Release build, and device archive gates pass.
- Starting commit: `e1d107c546e9fb7575a68de33a197314a91313ef`
- Branch: `main`
- Dirty worktree preserved: yes
- Files added: sparse-offset runtime payload/loader/repair, projection runtime, plate package, compositor, shader, pose captures, validators, and reports
- Files modified: Chapter 3 Angel integration, authoring capture, resource contracts, tests, and host tools
- Files removed: no owner source removed; the former root `angel/` delivery directory was moved into the canonical runtime plate package
- Owner files reset: none
- Commit created: no

## Owner target

- Target path: `/Users/richardfallat/Projects/dev/gravitas-plague/angel_posed_mouth_open_blend_01_v0001.usdz`
- Target SHA-256: `830d005f31b13a106598b4f0ae241bfedf451cc113d679cffbcdb14addeef28f`
- Base production asset path: `/Users/richardfallat/Projects/dev/gravitas-plague/angel_posed_01.usdz`
- Base SHA-256 before: `7c7b71c23a4dccd33bd227d11b31e57f68df476acd243c2b325704e3ebf7610c`
- Base SHA-256 after: `c274c2a294cf32b4d3dca036d36e854e07bf12a6279a1177d88e5a6148bbaa0f`
- Target textures imported: no
- Target bundled: no

## Topology

- Stage units: 1 meter per unit
- Up axis: Z
- Mesh-pair count: 1
- Base/target topology hashes: `bd51218caa51945d3aa10e105c4e18b10aadcfbc37c4e548aea3602f7af6329f` / `31e6cab7e0160b78a43bfa7bcae8218b973b94c517f3f2223ab3c85f115830b6`; semantic topology comparison passed despite differing source prim paths
- Point-count mismatches: none; both corresponding meshes contain 1,062,657 points
- Face-index mismatches: none
- Transform mismatches: none after corresponding-root normalization
- UV mismatches: none
- Joint-binding mismatches: none
- Nonfinite values: none
- Changed-point count by mesh: `/root/Root/mesh1/mesh1`: 5,721
- Maximum displacement: 0.011016777 m
- Zero-deformation meshes: none among the one matched production mesh

## Blendshape authoring

- Channel name: `jawOpenProjection`
- Changed mesh paths: `/root/Root/mesh1/mesh1`
- Sparse point-index count: 5,721
- Normal offsets: unavailable in owner target; no fabricated normals were authored
- Existing blendshapes preserved: yes
- Default weight: 0
- Time samples: none
- USD checker: PASS
- USDZ package compliance: PASS through OpenUSD package creation and `/usr/bin/usdchecker`
- Base textures/materials preserved: exact inventory preserved
- Runtime asset duplication: one production Angel only; sculpt target absent from app and archive
- Bundle byte delta: USDZ +74,642 bytes; offset-repair payload +160,242 bytes

## RealityKit import probe

- SDK: Xcode 27 beta, visionOS 27 SDK
- Simulator runtime: visionOS 27.0, `RealityDevice14,1`
- Model entities: 1 matching production mesh
- blendWeightNames: `jawOpenProjection`
- Binding count: 1
- Component auto-present: yes; RealityKit exposed the semantic target but imported its sparse offset buffer as zeros
- Component mapping created: stable `MeshResource.contents` repair installs the validated sparse offsets once, then the normal `BlendShapeWeightsComponent` drives the target
- 0.00 result: accepted
- 0.33 result: accepted and captured
- 0.50 result: accepted and captured
- 1.00 result: accepted and captured
- Return-to-zero result: accepted
- Unrelated weights preserved: yes
- Imported mesh evidence after repair: 1,062,667 offsets, maximum 0.011016777 m

## Semantic mapping

- Rest: 0.00
- Teeth: 0.00
- Small: 0.33
- Round: 0.50
- Wide: 1.00
- Heaven ember teeth multiplier: 1.75
- Mapping-source collision: none; projection, geometry, and embers consume one `Chapter03AngelPerformanceSample`

## Response

- Opening half-life: 0.03 s
- Closing half-life: 0.05 s
- Crossing half-life: 0.035 s
- Maximum delta: 0.05 s
- Epsilon: 0.0005
- Overshoot: none by exponential response construction
- Frame-rate comparison: covered by deterministic response tests; physical frame timing remains unmeasured
- Assignments while steady: zero after epsilon convergence

## Projection readiness

- Camera ready: hash-bound before nonzero geometry
- Material ready: required
- Texture ready: first GPU frame completes before installation
- Mask ready: 1440×1440 linear-16 union mask required
- Blendshape ready: validated target plus repaired nonzero offsets required
- Nonzero weight allowed without projection: no
- Mid-performance projection failure: geometry returns to 0 and imported material is restored
- Base fallback: original PBR/emission material
- Audio/story impact: none; visual failures are fail-soft

## Canonical pose ownership

- Pose clock owner: actual Angel prerecorded playback through `Chapter03AngelVisemePlayback`
- Projected mouth consumer: `MindEyeAngelProjectionController`
- Blendshape consumer: `Chapter03AngelBlendShapeController`
- Heaven ember consumer: `Chapter03HeavenPortalEmberController`
- Duplicate cue samplers: none
- Actual playback identity: run ID plus playback ID
- Stale playback rejection: implemented in `Chapter03AngelPerformanceCoordinator`

## Pose captures

- Projector camera SHA: `0f0c8382a94ee2ae2409b6420023be937addbfc4eee9c49ef71360e0111c9092`
- Rest capture: `GeometryPoses/angel_head_v1_geometry-rest_000.png`, SHA `32a873f2f276b9d3a5396a0838cd62b1dca67720c279ad42ea0908f53316ad70`
- Teeth geometry alias: rest
- Small capture: SHA `5a2694befde31e99358fee39f11e9a784345a734145c3d23431b3093dc1c62bd`
- Round capture: SHA `f682beba3ea1735cbe0a02b6426fd81883058f8dbdc25c3903bc1ee0bd8c681b`
- Wide capture: SHA `8be695da6076fa6ca2bda5bceef7a8fb5133b69b92317f582d2cd64c9db6e013`
- Per-pose coverage: four distinct hashes
- Union mask: generated from all four geometry coverages, then center-cropped to the production 1440 square
- Union contains every pose: validator PASS
- Contact sheet: `Authoring/MindEyeProjectionCaptures/angel_head_v1/GeometryPoses/angel_head_v1_geometry-pose-contact-sheet.png`
- Heatmap: `Authoring/MindEyeProjectionCaptures/angel_head_v1/GeometryPoses/angel_head_v1_geometry-displacement-heatmap.png`
- Round-trip error at rest: exact weight 0 capture; visual pixel-difference reference produced
- Round-trip error at small: distinct capture produced; physical-device error unmeasured
- Round-trip error at round: distinct capture produced; physical-device error unmeasured
- Round-trip error at wide: distinct capture produced; physical-device error unmeasured

## Artist/form review

- Chin/jaw silhouette: deformation is visible and continuous in the contact sheet
- Gonial/ramus read: subtle; owner approval pending
- Preauricular/TMJ read: subtle; owner approval pending
- Masseter/lower cheek: changed region is localized by the heatmap
- Submental/hyoid: changed region is localized by the heatmap
- Upper-neck tension: present without a topology seam in automated renders
- Upper-face preservation: heatmap shows deformation concentrated below the protected upper face
- Lip-screen smoothness: no topological tear in 0/0.33/0.50/1 renders
- Rope-like tendons: none apparent in Simulator reference; physical review pending
- 33% intermediate: captured and distinct
- 50% intermediate: captured and distinct
- Full wide: captured and distinct

## Runtime integration

- Active Angel resource name: `angel_posed_01.usdz`
- Static posed variant retained: yes
- Existing scale retained: 1
- Existing root offsets retained: yes
- Existing float motion retained: yes
- Existing emission applier retained: yes, as exclusive fail-soft fallback
- Blendshape controller owner: `Chapter03AngelPortalEntity`
- Update path: existing `Chapter03LightTunnelPresenter.updateFrame`
- Teardown: resets weight to zero, releases projection, restores PBR/emission, and removes the scene bundle

## Performance

- Frame time at 0: physical device not measured
- Frame time while transitioning: physical device not measured
- Frame time at 1: physical device not measured
- GPU frame-time delta: physical device not measured
- Physical-footprint delta: physical device not measured
- Per-frame allocations: no dense vertex reconstruction or material/texture creation; only weight assignment when outside epsilon
- Material recreations: zero per frame
- Texture recreations: zero per frame
- Audio callback misses: physical device not measured
- Ember update regression: no code change; physical device not measured

## Failure injection

- Missing descriptor: base Angel remains, projection unavailable
- Wrong asset hash: descriptor load rejects, base Angel remains
- Missing target: resolver rejects, base Angel remains
- Stale binding: assignment fails, weight resets to zero
- Projection unavailable: nonzero geometry prohibited
- Projection lost at wide: reset to zero and PBR/emission fallback restored
- Cancel during wide: teardown resets to zero
- Replacement run: old controller teardown precedes new scene ownership
- App inactive: existing scene teardown path retained
- Resulting Angel/audio/story state: base visual or normal scene release; audio/story never blocked

## Builds and tests

- Host doctor: PASS
- Host topology tests: PASS, 5 tests
- USD authoring tests: PASS
- USD checker: PASS
- Runtime descriptor tests: PASS
- Pose-mapping tests: PASS in prior focused Simulator suite
- Response tests: PASS in prior focused Simulator suite
- Resolver tests: PASS in prior focused Simulator suite
- Integration tests: relevant focused Simulator suite PASS; current whole test target is blocked by unrelated pre-existing Turing test compilation errors
- Pose-capture tests: PASS; four distinct beauty hashes and four distinct coverage hashes
- Static audits: PASS for projection scope
- arm64 Simulator build: PASS
- Vision Pro load: not run on physical hardware
- Vision Pro art review: not run
- Release archive: PASS, generic arm64 visionOS archive

## Locked systems

- Turing two-lane system: unchanged
- MLX recovery: unchanged
- Mind’s Eye runtime: existing 16:9 behavior unchanged; a separate square Angel profile was added
- Runtime lip sync: unchanged
- Heaven ember physics: unchanged; existing viseme multiplier consumer reused
- Chapter 3 travel/music/completion: unchanged by this implementation
- Authored film: unchanged

## Owner follow-up

- Target accepted: pending owner review of contact sheet and physical Vision Pro render
- Required sculpt revision: none identified by automated validation
- Exact revision notes: if desired, revise only the owner target USDZ; the cube continues to own camera framing and the host tool deterministically rebuilds all derived assets

## Blockers

- Physical Vision Pro shading/performance measurements and owner visual approval have not been run. Normal offsets were unavailable in the supplied sculpt target, so the handoff's mandatory physical shading review remains required.
