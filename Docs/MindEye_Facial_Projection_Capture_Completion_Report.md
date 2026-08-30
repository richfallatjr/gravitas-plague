# Mind’s Eye facial-projection capture completion report

## Final status

- Decision: BLOCKED
- Starting commit: `3f85a367683704eb91b8c747ddc3f58ae24011e6`
- Branch: `main`
- Dirty worktree preserved: Yes; 157 pre-existing/current worktree entries remain and no unrelated change was reset.
- Files added: 65 across projection runtime, authoring runtime, shared Chapter 3 scene assembly, runtime JSON, host automation, tests, and this report.
- Files modified: 5 (`GravitasPlagueApp.swift`, `Chapter03AngelPortalEntity.swift`, `Chapter03LightTunnelPresenter.swift`, `MindEyeCompositeUniforms.swift`, and `MindEyeCompositorPipeline.swift`).
- Files removed: 0
- Owner files reset: 0
- Commit created: No

## Shared scene

- Angel asset: `/Users/richardfallat/Projects/dev/gravitas-plague/angel_posed_01.usdz`
- Angel presentation variant: Static posed Chapter 3 portal Angel (`Chapter03StaticPosedAngelVisual`).
- Scene factory: `/Users/richardfallat/Projects/dev/gravitas-plague/Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter03/LightTunnel/Chapter03LightTunnelSceneFactory.swift`
- Runtime presenter migrated: Yes; `Chapter03LightTunnelPresenter` now delegates common assembly to the shared factory.
- Heaven EXR: `/Users/richardfallat/Projects/dev/gravitas-plague/heaven-sunrise.exr`
- IBL intensity: `0.5` exponent in both runtime and capture.
- Bloom: Preserved for the runtime portal world; omitted from offscreen authoring because `RealityRenderer` does not expose the production world bloom pass.
- Frame-zero float offset: `0 m` procedural float; authored `angelInsideOffsetMeters = 1.0` and `angelRootYOffsetMeters = -0.9` remain preserved.
- Runtime/capture scene duplication: None for Angel, EXR, dome, IBL, or transforms; all use the shared factory.

## Target resolution

- Subject root: `Chapter03PortalAngelRoot`
- Target entity path: `Chapter03PortalAngelRoot/Chapter03StaticPosedAngelVisual/root/Root/mesh1/mesh1`
- Framing entity path: Same as target; no face/head framing node exists.
- Target material indices: `[0]`
- Target material names: Imported material name is not exposed by RealityKit; reflected type is `PhysicallyBasedMaterial`.
- Target material count: 1
- Placeholder values remaining: None, but the exact resolved target is ineligible because it is the entire body.
- Hierarchy report: `/Users/richardfallat/Projects/dev/gravitas-plague/.build/mind-eye-projection/angel_head_v1/inspect-subject/angel_head_v1_scene-hierarchy.txt`

## Square pixel budget

- Source dimensions: `1728 × 1728`
- Source pixel count: `2,985,984`
- Existing source pixel count: `2,985,984` (`2304 × 1296`)
- Source byte count: `11,943,936` bytes per RGBA8 layer
- Viewport dimensions: `1440 × 1440`
- Viewport pixel count: `2,073,600`
- Existing output pixel count: `2,073,600` (`1920 × 1080`)
- Output byte count: `8,294,400` bytes for BGRA8
- Additional pixel-budget regression: 0 pixels / 0 bytes

## Camera

- Camera ID: `angel_head_v1.camera`
- Camera descriptor path: `/Users/richardfallat/Projects/dev/gravitas-plague/Gravitas Plague/TuringResources/Turing/MindsEye/Projection/cameras/angel_head_v1.camera.json`
- Vertical FOV: `30°`
- Near/far: `0.02 m / 20 m`
- Subject-from-camera: `[0.99999994,0,0,0, 0,1,0,0, 0,0,0.99999994,0, 0.0023173392,0.9448799,3.9434516,1]`
- Clip-from-subject: `[3.7320511,0,0,0, 0,3.7320511,0,0, 0,0,-1.001001,-1, -0.008648428,-3.52634,3.9273794,3.943452]`
- Camera SHA: `fb39c87eb9adbf2f8bbdb0c0111e7423b1ffbb54b3a2ffe17be3a3196fd51fc2`
- Runtime camera SHA: Same
- Capture camera SHA: Same in the rejected diagnostic capture
- Camera identity match: Exact byte identity passed, including negative-zero normalization.
- Mask occupancy: `26.35265292781207%` in the rejected whole-body diagnostic; not a valid facial occupancy measurement.
- Center error: `[7.5, -4.0]` pixels in that diagnostic.
- Edge clipping: False in that diagnostic.

## RealityRenderer spike

- SDK: visionOS 27.0, build `24M5348a`, Xcode 27 beta.
- Simulator runtime: visionOS 27.0 arm64.
- RealityRenderer construction: Compile- and runtime-proven with `RealityRenderer()`.
- Entity collection API: Compile- and runtime-proven with `renderer.entities.append(contentsOf:)`.
- Active camera: Compile- and runtime-proven with a subject-relative `PerspectiveCameraComponent` entity.
- Camera output: Compile- and runtime-proven.
- Single projection: Compile- and runtime-proven with `.singleProjection(colorTexture:)`.
- updateAndRender: Compile- and runtime-proven.
- Completion callback: Used for every frame and readback boundary.
- Nonblack render: Yes; the rejected diagnostic rendered the fully lit Angel.
- MainActor wait: No blocking wait and no `waitUntilCompleted()`; completion is awaited asynchronously with a ten-second watchdog.

## Capture outputs

- Scene beauty: `/Users/richardfallat/Projects/dev/gravitas-plague/.build/mind-eye-projection/rejected-whole-body-capture/angel_head_v1_scene-beauty.png`
- Face beauty: `/Users/richardfallat/Projects/dev/gravitas-plague/.build/mind-eye-projection/rejected-whole-body-capture/angel_head_v1_face-beauty.png` (diagnostic only; equals scene beauty because the asset has one whole-body material).
- Linear16 mask: `/Users/richardfallat/Projects/dev/gravitas-plague/.build/mind-eye-projection/rejected-whole-body-capture/angel_head_v1_projection-mask-linear16.png`
- Mask preview: `/Users/richardfallat/Projects/dev/gravitas-plague/.build/mind-eye-projection/rejected-whole-body-capture/angel_head_v1_projection-mask-preview.png`
- Alignment guide: `/Users/richardfallat/Projects/dev/gravitas-plague/.build/mind-eye-projection/rejected-whole-body-capture/angel_head_v1_alignment-guide.png`
- Camera JSON: `/Users/richardfallat/Projects/dev/gravitas-plague/.build/mind-eye-projection/rejected-whole-body-capture/angel_head_v1_camera.json`
- Capture manifest: `/Users/richardfallat/Projects/dev/gravitas-plague/.build/mind-eye-projection/rejected-whole-body-capture/angel_head_v1_capture-manifest.json`
- Hierarchy report: `/Users/richardfallat/Projects/dev/gravitas-plague/.build/mind-eye-projection/rejected-whole-body-capture/angel_head_v1_scene-hierarchy.txt`
- Completion marker: `/Users/richardfallat/Projects/dev/gravitas-plague/.build/mind-eye-projection/rejected-whole-body-capture/angel_head_v1_complete.json`
- Output-set SHA: `82e904aa7f3f8417cf80e7b7f3f51b25ee9e8d1e7d4180dc302c9166aecb5cab` (rejected diagnostic)

## Mask

- Binary target AOV: Implemented by replacing only descriptor-selected materials with white and every non-target material with black. The current asset selects the entire Angel, so it is not a valid face AOV.
- Distance-field implementation: Deterministic Felzenszwalb/Huttenlocher exact squared Euclidean distance transform.
- Inset: `12 px`
- Feather: `32 px`
- Coverage: `26.35265292781207%` diagnostic whole-body mask.
- Bounding box: `[524, 75, 695, 1570]` diagnostic whole-body mask.
- Connected components: Largest four-connected component retained deterministically; focused tests pass.
- Edge contact: False
- Determinism: Algorithm/unit determinism passes; valid face-capture double-run is blocked by asset topology.

## Mac round trip

- One-command script: `/Users/richardfallat/Projects/dev/gravitas-plague/Scripts/mind_eye_projection/capture_angel_projection_reference.sh`
- Simulator UDID: `98238731-AFA9-49D3-8BAF-E6C323E05461`
- Bundle ID: `GravitasDiscover.Gravitas-Plague`
- App container discovered: Yes, automatically with `simctl`.
- Manual clicks: 0
- Manual AVP transfer: 0
- Camera stage copied: Yes in the diagnostic round trip.
- Rebuild after camera publish: Yes in the diagnostic round trip.
- Final package copied to: No canonical package; the structurally valid but semantically wrong package was moved to `/Users/richardfallat/Projects/dev/gravitas-plague/.build/mind-eye-projection/rejected-whole-body-capture`.
- Script exit code: 1, intentionally, with the exact face-target blocker. The target publisher stops before camera/capture publication and does not overwrite the runtime target.

## Runtime material

- Material model: BLOCKED. The supplied directive selects lit `CustomMaterial`, but the installed visionOS 27 SDK explicitly marks that API unavailable.
- Imported PBR base retained: Yes; the fail-soft factory currently performs validation only and mutates no material.
- Projection expressed as emission: Equation and Metal math contract implemented; no supported production material program is bound yet.
- Albedo suppression formula: `base × (1 - coverage × 0.96)` implemented and tested.
- Specular suppression formula: `specular × (1 - coverage × 0.90)` implemented and tested.
- Frustum fade: `1.5%` smootherstep contract implemented.
- Facing fade: Smootherstep contract implemented.
- Full-quality cone: `22°`
- Zero-projection cone: `42°`
- Outside-mask PBR: Preserved by the math contract and fail-soft behavior; not device-validated.
- Material recreations per frame: 0 in implemented ownership; runtime projection material is not yet available.
- TextureResource recreations per frame: 0; one `LowLevelTexture`/`TextureResource` projection source is implemented.

## Runtime compositor

- Existing 16:9 profile unchanged: Yes; landscape is still the default path and retains `2304 × 1296 → 1920 × 1080`, crop `(192,108)`.
- Square profile: Implemented and unit-tested as `1728 × 1728 → 1440 × 1440`, crop `(144,144)`.
- Projection texture dimensions: `1440 × 1440` descriptor implemented.
- Flat-card drift in projection mode: Disabled by forcing identity background and character transforms.
- Eye/mouth switching: Preserved in compositor state.
- Dynamic texture update: Encoder accepts the square profile, but final square package/surface-to-material integration is blocked with the runtime material and source art.
- Per-frame CPU image allocation: 0 in the runtime projection/compositor path.

## Visual validation

- Exact projector view: BLOCKED pending a valid face target, final source layers, supported runtime material, and Vision Pro run.
- ±10°: Not run
- ±22°: Not run
- ±32°: Not run
- ±42°: Not run
- Vertical movement: Not run
- Registration: Not run
- Double lighting: Not run
- Mask halo: Not run
- Frustum rectangle: Not run
- Texture swimming: Projection-mode 2D drift is statically disabled; device validation not run.
- Stereo separation: Not run
- Bloom/highlights: Not run

## Performance and resources

- Square compositor GPU time: Not measured
- Projection material GPU time: Not measurable until a supported runtime material exists.
- Source texture residency: Pixel budget proven equal; final `1728 × 1728` source package is not present.
- Output texture residency: `8,294,400` bytes for one BGRA8 `1440 × 1440` level; runtime measurement not run.
- Physical-footprint delta: Not measured
- Frame-time delta: Not measured
- Existing Turing pressure regression: No Turing/MLX source changed; device pressure test not run.
- Authoring files in app bundle: 0. Release-string/resource audit found no authoring launch code or capture artifacts. The thinned qualification app was 248 MB because large runtime resources were deliberately excluded from this compile check.

## Determinism

- Camera JSON comparison: Exact byte identity passed; SHA `fb39c87eb9adbf2f8bbdb0c0111e7423b1ffbb54b3a2ffe17be3a3196fd51fc2`.
- Mask comparison: Unit repeatability passes; no second valid facial mask exists.
- Alignment-guide comparison: Comparison tool enforces exact identity; no second valid facial guide exists.
- Beauty maximum error: Not measured for a valid facial capture.
- Beauty PSNR: Comparison tool enforces max error ≤ 1 and PSNR ≥ 60 dB; no second valid facial capture exists.
- Output hashes: Diagnostic hashes are recorded in its manifest; no canonical face-capture hashes are published.

## Builds and tests

- Camera math tests: PASS
- Mask tests: PASS
- Material math tests: PASS
- Scene factory tests: PASS
- RealityRenderer integration tests: PASS for automatic offscreen rendering; BLOCKED for face-only semantics/runtime projection.
- Host Python tests: PASS, 5 tests
- Source audits: PASS (`git diff --check`, shell syntax, Python compile, no UI automation, one canonical camera, no 2048-square regression, no authoring artifacts in Release bundle).
- arm64 Simulator Debug build: PASS
- arm64 Simulator Release build: PASS
- One-command capture: BLOCKED with explicit whole-body target rejection; no false `PASS` output remains at the canonical path.
- Physical Vision Pro comparison: Not run

## Locked systems

- Existing Mind’s Eye 16:9: Preserved as default.
- Turing: No source changes.
- MLX recovery: No source changes.
- Runtime lip sync: No source changes.
- Filler lip sync: No source changes.
- Chapter 3 timing: Existing definition values and sequence timing preserved; only common visual assembly was refactored.
- Angel geometry: Unchanged.
- Story progress: Authoring mode mounts only its isolated view and performs no progress writes.

## Final asset paths

- Runtime camera: `/Users/richardfallat/Projects/dev/gravitas-plague/Gravitas Plague/TuringResources/Turing/MindsEye/Projection/cameras/angel_head_v1.camera.json` (diagnostic camera; runtime application remains disabled by target validation).
- Runtime profile: `/Users/richardfallat/Projects/dev/gravitas-plague/Gravitas Plague/TuringResources/Turing/MindsEye/Projection/profiles/angel_head_v1.json`
- Runtime target: `/Users/richardfallat/Projects/dev/gravitas-plague/Gravitas Plague/TuringResources/Turing/MindsEye/Projection/targets/angel_head_v1.target.json` (exact hierarchy, but ineligible whole-body target).
- Authoring capture directory: Canonical `/Users/richardfallat/Projects/dev/gravitas-plague/Authoring/MindEyeProjectionCaptures/angel_head_v1` intentionally absent; rejected diagnostic is under `.build`.

## Blockers

- `angel_posed_01.usdz` contains one `PhysicallyBasedMaterial` on one full-body mesh with bounds `0.79386146 × 1.8897598 × 0.59565288 m`. There is no face/head entity, framing node, or independently targetable face material. A DCC update must expose a named face/head/skin entity or material slot (and preferably a head framing entity) without changing the pose/transforms.
- The installed visionOS 27 SDK marks legacy Metal `CustomMaterial` unavailable. A compile-valid lit `ShaderGraphMaterial`/MaterialX program (or another supported RealityKit material route) must be authored and bound before the required projected-emission PBR blend can run.
- Consequently, the final `Authoring/MindEyeProjectionSources/angel_head_v1` art package, physical Vision Pro registration/view-cone checks, and runtime GPU/memory measurements cannot be completed yet.
