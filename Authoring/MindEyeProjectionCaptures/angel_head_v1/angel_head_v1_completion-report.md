# Mind’s Eye facial-projection capture completion report

## Final status

- Decision: BLOCKED only on physical Vision Pro comparison/performance review; implementation, automatic Simulator capture, Release build, and generic device archive pass.
- Starting commit: `e1d107c546e9fb7575a68de33a197314a91313ef`
- Branch: `main`
- Dirty worktree preserved: yes
- Files added: square Angel projection package/runtime, mesh material path, capture tooling, union-mask publication, captures, tests, and reports
- Files modified: shared Chapter 3 scene/presenter integration and projection authoring contracts
- Files removed: no owner source deleted; supplied plates were moved from the root delivery folder into the canonical package
- Owner files reset: none
- Commit created: no

## Shared scene

- Angel asset: `angel_posed_01.usdz`, SHA `c274c2a294cf32b4d3dca036d36e854e07bf12a6279a1177d88e5a6148bbaa0f`
- Angel presentation variant: `staticPosed`
- Scene factory: `Chapter03LightTunnelSceneFactory`
- Runtime presenter migrated: yes; capture and production share the factory
- Heaven EXR: `heaven-sunrise.exr`, SHA `9893b6c5b29c0bf74306cc0c4ee0f6726f1b3a50ca787ff567b36a0f04e9265e`
- IBL intensity: shared from production scene definition/factory
- Bloom: shared production setup; offscreen/device parity measurement pending
- Frame-zero float offset: zero animation frames advanced
- Runtime/capture scene duplication: none

## Target resolution

- Subject root: `Chapter03PortalAngelRoot`
- Target entity path: `Chapter03PortalAngelRoot/Chapter03StaticPosedAngelVisual/root/Root/mesh1/mesh1`
- Framing entity path: same runtime mesh, framed by owner cube `/root/face_proxy/Cube_001`
- Target material indices: `[0]`
- Target material names: `PhysicallyBasedMaterial`
- Target material count: 1
- Placeholder values remaining: none in the published target/camera
- Hierarchy report: `angel_head_v1_scene-hierarchy.txt`; its automatic whole-body warning is resolved by the exact owner cube, frustum, and face mask contract

## Square pixel budget

- Source dimensions: 1728×1728
- Source pixel count: 2,985,984
- Existing source pixel count: 2304×1296 = 2,985,984
- Source byte count: 11,943,936 bytes per RGBA8 layer
- Viewport dimensions: 1440×1440
- Viewport pixel count: 2,073,600
- Existing output pixel count: 1920×1080 = 2,073,600
- Output byte count: 8,294,400 bytes RGBA8
- Additional pixel-budget regression: none

## Camera

- Camera ID: `angel_head_v1.camera`
- Camera descriptor path: `Gravitas Plague/TuringResources/Turing/MindsEye/Projection/cameras/angel_head_v1.camera.json`
- Vertical FOV: 30° long-lens framing
- Near/far: 0.02 m / 20 m
- Subject-from-camera: owner-cube-derived matrix in the descriptor
- Clip-from-subject: exact published matrix in the descriptor
- Camera SHA: `0f0c8382a94ee2ae2409b6420023be937addbfc4eee9c49ef71360e0111c9092`
- Runtime camera SHA: same
- Capture camera SHA: same
- Camera identity match: exact byte match, validator PASS
- Mask occupancy: 0.2092050728 in the rest reference
- Center error: (-6, 81) source pixels
- Edge clipping: none; bounds `[439, 443, 838, 1004]` remain inside the 144-pixel crop guard

## RealityRenderer spike

- SDK: Xcode 27 beta / visionOS 27
- Simulator runtime: 27.0 on `RealityDevice14,1`
- RealityRenderer construction: PASS
- Entity collection API: shared scene bundle entities
- Active camera: published owner-cube camera
- Camera output: 1728-square offscreen render
- Single projection: one target material slot on the actual Angel mesh
- updateAndRender: PASS
- Completion callback: asynchronous GPU completion
- Nonblack render: PASS
- MainActor wait: none

## Capture outputs

- Scene beauty: `angel_head_v1_scene-beauty.png`, SHA `5d1aac0df61f5afea73244b4a15b679a5d45470523ad4ad010a83ae61d9dc08c`
- Face beauty: `angel_head_v1_face-beauty.png`, SHA `32a873f2f276b9d3a5396a0838cd62b1dca67720c279ad42ea0908f53316ad70`
- Linear16 mask: `angel_head_v1_projection-mask-linear16.png`
- Mask preview: `angel_head_v1_projection-mask-preview.png`
- Alignment guide: `angel_head_v1_alignment-guide.png`
- Camera JSON: `angel_head_v1_camera.json`
- Capture manifest: `angel_head_v1_capture-manifest.json`
- Hierarchy report: `angel_head_v1_scene-hierarchy.txt`
- Completion marker: `angel_head_v1_complete.json`
- Output-set SHA: `e765d02fc227416fca9a6bdf054136bd0963cca09c6ff58cb95c5e655ea77c59`

## Mask

- Binary target AOV: flat owner-authored RGB mask material on geometry; black face and white surrounding geometry, not alpha extraction
- Distance-field implementation: deterministic captured-AOV processing
- Inset: 12 pixels
- Feather: 32 pixels
- Coverage: 0.2092050728 for rest; production uses the four-pose union
- Bounding box: `[439, 443, 838, 1004]`
- Connected components: validated with tiny-island filtering
- Edge contact: none within the locked crop
- Determinism: hash-bound mask/profile/package contract PASS
- Production union mask: 1440×1440 gray16, SHA `dcc34bb6186c8b64d4b7d3512ddadb085c944ca6758e3752341cbbc775414ca3`

## Mac round trip

- One-command script: `Scripts/mind_eye_projection/capture_angel_projection_reference.sh`; geometry wrapper invokes it by default
- Simulator UDID: `98238731-AFA9-49D3-8BAF-E6C323E05461`
- Bundle ID: `GravitasDiscover.Gravitas-Plague`
- App container discovered: automatically through `simctl`
- Manual clicks: none
- Manual AVP transfer: none
- Camera stage copied: yes
- Rebuild after camera publish: yes
- Final package copied to: `/Users/richardfallat/Projects/dev/gravitas-plague/Authoring/MindEyeProjectionCaptures/angel_head_v1`
- Script exit code: 0

## Runtime material

- Material model: one `ShaderGraphMaterial` per resolved source material using the shared square `LowLevelTexture`
- Imported PBR base retained: captured and restored as fail-soft fallback
- Projection expressed as emission: yes
- Albedo suppression formula: inverse mask × profile suppression × view/frustum coverage
- Specular suppression formula: inverse mask × profile suppression × view/frustum coverage
- Frustum fade: implemented
- Facing fade: implemented
- Full-quality cone: 22°
- Zero-projection cone: 42°
- Outside-mask PBR: original material retained/fallback restored
- Material recreations per frame: 0
- TextureResource recreations per frame: 0

## Runtime compositor

- Existing 16:9 profile unchanged: yes
- Square profile: `angel_head_v1`
- Projection texture dimensions: 1440×1440
- Flat-card drift in projection mode: none; no card or plane exists
- Eye/mouth switching: blink scheduler plus all rest/small/wide/round/teeth families; variants randomly selected through deterministic streams
- Dynamic texture update: one reusable `LowLevelTexture`, one in-flight command, one latest pending state
- Per-frame CPU image allocation: none

## Visual validation

- Exact projector view: Simulator beauty and flat mask AOV captured
- ±10°: material math implemented; physical stereo review pending
- ±22°: full-quality boundary implemented; physical review pending
- ±32°: crossfade region implemented; physical review pending
- ±42°: projection reaches zero by contract; physical review pending
- Vertical movement: frustum projection implemented; physical review pending
- Registration: exact camera/mask hashes and pose captures pass
- Double lighting: projection owns emission while active; imported emission is fallback only
- Mask halo: no source-capture edge contact; physical bloom review pending
- Frustum rectangle: shader clamps/fades outside frustum; physical review pending
- Texture swimming: no internal 2D motion; physical geometry supplies movement
- Stereo separation: physical review pending
- Bloom/highlights: physical review pending

## Performance and resources

- Square compositor GPU time: physical device not measured
- Projection material GPU time: physical device not measured
- Source texture residency: approximately 111,642,624 bytes at full RGBA8/R16 residency
- Output texture residency: 8,294,400 bytes
- Physical-footprint delta: physical device not measured
- Frame-time delta: physical device not measured
- Existing Turing pressure regression: no Turing/MLX code changed; overlap not applicable to end-sequence device test until measured
- Authoring files in app bundle: 0
- On-disk supplied plates: 4,226,341 bytes

## Determinism

- Camera JSON comparison: exact byte identity
- Mask comparison: exact SHA identity
- Alignment-guide comparison: hash recorded in capture manifest
- Beauty maximum error: device comparison not measured
- Beauty PSNR: device comparison not measured
- Output hashes: complete capture manifest and completion marker present

## Builds and tests

- Camera math tests: PASS in focused Simulator suite
- Mask tests: PASS in focused Simulator suite and host validator
- Material math tests: PASS in focused Simulator suite
- Scene factory tests: PASS in focused Simulator suite
- RealityRenderer integration tests: PASS through automatic capture
- Host Python tests: PASS, 9 projection tests
- Source audits: PASS
- arm64 Simulator Debug build: PASS
- arm64 Simulator Release build: PASS
- One-command capture: PASS
- Physical Vision Pro comparison: not run
- Generic arm64 visionOS Release archive: PASS; app payload 3,925,385,216 bytes
- Current whole XCTest target note: blocked before selected tests run by unrelated pre-existing Turing test actor-conformance/argument-order compile errors; prior focused projection suite passed

## Locked systems

- Existing Mind’s Eye 16:9: unchanged
- Turing: unchanged
- MLX recovery: unchanged
- Runtime lip sync: unchanged
- Filler lip sync: unchanged
- Chapter 3 timing: unchanged
- Angel geometry: only the approved single sparse blendshape added
- Story progress: unchanged

## Final asset paths

- Runtime camera: `/Users/richardfallat/Projects/dev/gravitas-plague/Gravitas Plague/TuringResources/Turing/MindsEye/Projection/cameras/angel_head_v1.camera.json`
- Runtime profile: `/Users/richardfallat/Projects/dev/gravitas-plague/Gravitas Plague/TuringResources/Turing/MindsEye/Projection/profiles/angel_head_v1.json`
- Runtime target: `/Users/richardfallat/Projects/dev/gravitas-plague/Gravitas Plague/TuringResources/Turing/MindsEye/Projection/targets/angel_head_v1.target.json`
- Authoring capture directory: `/Users/richardfallat/Projects/dev/gravitas-plague/Authoring/MindEyeProjectionCaptures/angel_head_v1`

## Blockers

- Physical Vision Pro projector-view, view-cone, stereo, bloom, GPU-time, frame-time, and physical-footprint comparison has not been run. No code or asset blocker remains for that test.
