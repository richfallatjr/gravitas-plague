# Gravitas Plague — Angel camera-space projection with UV-space receiver mask

## Architect handoff and corrective implementation brief

**Prepared:** 2026-08-30  
**Repository:** `/Users/richardfallat/Projects/dev/gravitas-plague`  
**Inspected commit:** `841190e` on `main`  
**Status:** corrective architecture is required before another implementation pass

This document supersedes the runtime-mask portions of the earlier Mind's Eye facial
projection handoff. It does not supersede the approved single-blendshape geometry,
the owner-authored projector camera, the Mind's Eye facial plates, blink/viseme
timing, or the fail-soft audio contract.

The owner has clarified the required coordinate-space contract:

> Mind's Eye imagery must be projected from the owner-authored camera onto the
> Angel's deformed geometry. It must not be placed into the Angel's UV space.
> `projection-mask.png` is the receiver mask and must be sampled in the Angel's
> authored mesh UV space. The original Angel textures/material appearance must
> remain correctly wired into the production blendshape model.

The Heaven portal embers are acceptable for now. Do not redesign, optimize, or
retune the ember system in this pass.

---

## 1. Outcome required

Implement one production Angel mesh that simultaneously supports:

1. the original, correct Angel PBR appearance;
2. the existing `jawOpenProjection` blendshape;
3. dynamic Mind's Eye face plates projected in the locked camera's perspective;
4. an independently sampled, UV-authored receiver mask;
5. clean fallback to the original Angel material if any projection resource fails;
6. no visible material or texture pop when the projection runtime becomes ready.

The two texture coordinate systems must remain independent:

```text
Mind's Eye color plates
    -> dynamic 1440 x 1440 composite
    -> sample with projectorUV derived from deformed object position
    -> camera/projector space

projection-mask.png
    -> sample with the production mesh's authored modelUV / primvars:st
    -> UV space
    -> controls where projected color may affect the mesh

original Angel PBR maps
    -> sample with their original model UVs, channels, transforms, samplers,
       color-space semantics, and imported material parameters
    -> UV space
```

No implementation may collapse those into one UV lookup.

---

## 2. Owner-visible failure

The owner supplied this physical-device screenshot:

```text
/Users/richardfallat/Downloads/IMG_1957.PNG
```

Observed behavior:

- The original Angel appears first.
- A visible pop occurs during asynchronous projection preparation.
- After the pop, the Angel has incorrect/scrambled material regions.
- The portal and embers are otherwise present.

The corresponding device log is:

```text
/Users/richardfallat/.codex/attachments/
f974c407-1c06-4781-8fbe-96f9393af252/pasted-text.txt
```

Relevant evidence:

```text
[Chapter03AngelEmission] updated asset=angel_posed_01.usdz ...
[Chapter03AngelBlendShape] mesh import ready repairedParts=1 ...
[Chapter03AngelBlendShape] loaded assetSHA=c274c2a2... target=jawOpenProjection
[Chapter03Angel] static portal pose installed
...
[MindEyeProjection] mesh materials installed count=1 ...
[MindEyeProjection] Angel runtime ready ... materialCount=1
[Chapter03AngelEmission] ownership changed projectionOwnsEmission=true ...
[Chapter03AngelBlendShape] projectionReady=true ...
```

There is no runtime load of
`angel_posed_mouth_open_blend_01_v0001.usdz`. The log identifies the production
asset as `angel_posed_01.usdz`, whose current SHA-256 is:

```text
c274c2a294cf32b4d3dca036d36e854e07bf12a6279a1177d88e5a6148bbaa0f
```

The target/sculpt file is authoring input. The production asset already carries the
blendshape, and runtime mesh repair restores its sparse offsets after RealityKit
import. The visible pop aligns with the projection `ShaderGraphMaterial` replacing
the imported PBR material, not with a second USDZ replacing the Angel.

Do not attempt to fix this by loading the sculpt-target USDZ at runtime.

---

## 3. Confirmed implementation defect

### 3.1 The receiver mask is currently baked in camera space

Current production resources include both:

```text
Gravitas Plague/TuringResources/Turing/MindsEye/Projection/masks/
    angel_head_v1_projection-mask-linear16.png  # 1440 x 1440 camera-space mask
    angel_head_v1_projection-mask-uv.png        # 1024 x 1024 owner UV mask
```

The owner UV mask exists, but the runtime does not use it.

The current profile and plate manifest point to the 1440 camera-space mask:

```text
Gravitas Plague/TuringResources/Turing/MindsEye/Projection/profiles/
    angel_head_v1.json

Gravitas Plague/TuringResources/Turing/MindsEye/Projection/plates/angel_head_v1/
    source-manifest.json
```

`MindEyeProjectionCompositor.swift` binds that mask as compositor texture index 3.
`MindEyeProjectionPlateComposite.metal` then performs:

```metal
half mask = projectionMask.read(gid).r;
output.a = composed.a * mask;
```

The projection material subsequently treats the composited alpha as its facial
coverage. This makes the receiver boundary an image-space mask. That is the wrong
contract for the owner-authored asset.

### 3.2 The runtime replaces the entire imported PBR material

`MindEyeProjectionMaterialController` replaces material slot zero with a newly
constructed `ShaderGraphMaterial`.

`MindEyeProjectionMaterialFactory` attempts to reconstruct the imported PBR using
raw texture resources and a generic `ND_texcoord_vector2` sample. Even if every
texture resource exists, this is not yet demonstrated to preserve the imported
material's full rendering semantics. It must account for the real asset's:

- exact UV set and interpolation;
- texture V orientation;
- texture transforms and wrap modes;
- color versus data texture semantics;
- metallic and roughness channel selection;
- normal-map convention and tangent basis;
- base/emission tints and intensities;
- opacity behavior;
- face culling / double-sided state;
- every imported property required for a pixel-equivalent coverage-zero result.

The physical-device screenshot demonstrates that the current reconstruction is not
visually equivalent.

### 3.3 The scene becomes visible before the replacement material is ready

`Chapter03LightTunnelPresenter.prepare` currently calls:

```text
worldAnchor.addChild(bundle.root)
```

before awaiting `MindEyeAngelProjectionController.prepare(...)`.

This exposes the imported Angel first and the replacement material later, producing
the observed pop even if the replacement eventually becomes correct. The projection
package, first composite, program, and material binding must be ready before the
Angel can become visible, or the root must remain disabled/fully hidden until the
atomic presentation boundary.

---

## 4. Authoritative render contract

### 4.1 Projected Mind's Eye color

The existing owner-authored camera remains authoritative:

```text
profile: angel_head_v1
vertical FOV: 30 degrees
source: /root/face_proxy/Cube_001
camera descriptor:
Turing/MindsEye/Projection/cameras/angel_head_v1.camera.json
```

The camera was framed from the cube in:

```text
angel_posed_mouth_open_blend_01_v0001.usdz
```

Do not frame from the face bounds, viewer position, or a head-tracked camera. Do not
move the projector with the viewer.

At rasterization time, derive projector coordinates from the current deformed mesh
position:

```metal
float4 projectorClip =
    clipFromEntity * float4(objectPositionAfterBlendshape, 1.0);

float3 projectorNDC = projectorClip.xyz / projectorClip.w;

float2 projectorUV = float2(
    projectorNDC.x * 0.5 + 0.5,
    1.0 - (projectorNDC.y * 0.5 + 0.5)
);
```

The dynamic Mind's Eye color texture is sampled only with `projectorUV`.

### 4.2 UV receiver mask

The owner-authored mask is:

```text
Gravitas Plague/TuringResources/Turing/MindsEye/Projection/masks/
angel_head_v1_projection-mask-uv.png
```

It originated as `textures/projection-mask.png` in the owner target USDZ. The
existing authoring code already records its convention: the facial receiver is dark
and the excluded region is light.

Therefore the material must perform the equivalent of:

```metal
float maskLuminance = sampleAsLinearData(
    projectionReceiverMask,
    modelUV
).r;

float receiverCoverage = 1.0 - maskLuminance;
```

Confirm this convention with a deterministic UV-mask diagnostic render before
shipping. Do not silently invert it to make one screenshot look plausible.

The receiver mask must:

- use the production mesh's authored `primvars:st` / model UV;
- be treated as linear data, not photographic sRGB color;
- preserve its authored feather;
- remain fixed to the mesh while the blendshape moves;
- never be cropped or sampled using `projectorUV`;
- never be premultiplied into the 1440 camera-space composite.

### 4.3 Original PBR maps

The production `angel_posed_01.usdz` currently packages:

```text
textures/angel_emission.png
textures/extracted_image_0.jpg
textures/extracted_image_2.jpg_roughness.png
textures/extracted_image_2.jpg_metallic.png
textures/extracted_image_1.jpg
textures/color_0C0C0C.exr
```

The production blendshape asset must retain and correctly render these base-asset
materials and textures. Target/sculpt textures do not replace the production PBR
set. The target's mask is an additional shader input, not a wholesale replacement
material.

At weight zero and projection coverage zero, the projection-capable material must
match the untouched imported PBR Angel. A material that merely contains the same
texture objects but renders differently does not satisfy this requirement.

### 4.4 Coverage equation

The production material must compute separate camera and UV samples:

```metal
float4 projected = projectionTexture.sample(projectorSampler, projectorUV);
float receiver = 1.0 - projectionReceiverMask.sample(maskSampler, modelUV).r;

float coverage = saturate(
    receiver
    * projected.a
    * validProjectorPosition
    * frustumFade
    * facingFade
);

baseColorOut = importedBaseColor
    * (1.0 - coverage * albedoSuppression);

specularOut = importedSpecular
    * (1.0 - coverage * specularSuppression);

projectedEmission = projected.rgb
    * coverage
    * projectionEmissionGain;

emissionOut = importedEmission * (1.0 - coverage)
    + projectedEmission;
```

Exact blending may be tuned only after base-material parity is proven. The projection
must not double the original Angel emission in the receiver region.

---

## 5. Dynamic compositor correction

The 1440-square compositor continues to combine:

```text
projection-base
selected eye variant
selected mouth variant
```

It must no longer consume the UV receiver mask or the derived camera-space
`linear16` receiver mask.

Required compositor output:

```text
RGB: composited photographic plate color
A: authored plate/source-over alpha only
```

The dynamic output remains one reusable `LowLevelTexture` and one reusable
`TextureResource`. Do not recreate either on mouth or eye changes.

The camera-space `linear16` mask may remain an authoring/diagnostic artifact if the
architect can justify its capture-validation role, but it must not control runtime
receiver coverage. If it remains in the shipped bundle without a runtime purpose,
remove it from production resources rather than paying duplicate residency and app
size.

Update the profile/manifest schema so the runtime contract names the UV receiver
mask explicitly. Do not retain the misleading field name `projectionMask` for two
different coordinate spaces.

Suggested explicit names:

```text
projectionReceiverUVMaskResourcePath
projectionReceiverUVMaskSHA256
projectionReceiverUVMaskConvention: darkProjectsLightSuppresses
projectionReceiverUVSet: primvars:st
```

The architect may choose a better schema, but coordinate space and convention must
be unambiguous and validated.

---

## 6. Material implementation decision required from architect

The current programmatic `ShaderGraphMaterial` exists because `CustomMaterial` is
not available for this visionOS target. Do not copy an unavailable API from the old
handoff.

The architect must select and prove one compile-valid visionOS 27 path that:

1. preserves the imported PBR appearance at zero coverage;
2. samples the dynamic color texture in projector space;
3. samples the receiver mask in model UV space;
4. uses the deformed blendshape position for projection;
5. does not duplicate the Angel geometry;
6. does not add a face card;
7. does not create materials or texture resources per frame.

Acceptable areas to investigate include:

- a corrected programmatic ShaderGraph that faithfully reconstructs every imported
  PBR semantic used by this asset;
- an authored ShaderGraph/material binding packaged into the production USDZ, with
  runtime parameters for the dynamic texture and projector matrix;
- a stable RealityKit material extension path available in the installed SDK that
  modifies projection/emission while preserving imported PBR behavior.

Do not commit to an API signature until a minimal compile-and-render spike passes on
the installed visionOS 27 SDK.

The architect's directive must state exactly how the imported texture sampler,
channel, UV, normal, and material properties are preserved. “Pass the same textures
into a new material” is not sufficient.

---

## 7. Blendshape and asset boundaries

Keep the approved single semantic channel:

```text
jawOpenProjection
```

Keep the existing mapping:

```text
rest:  0.00
teeth: 0.00
small: 0.33
round: 0.50
wide:  1.00
```

The sculpt target remains authoring-only:

```text
angel_posed_mouth_open_blend_01_v0001.usdz
```

The production runtime asset remains one Angel:

```text
angel_posed_01.usdz
```

Required asset invariants:

- one production Angel USDZ;
- original base points at weight zero;
- original base texture inventory and material binding retained;
- one `jawOpenProjection` target;
- default blendshape weight zero;
- target/sculpt PBR textures not copied into the app;
- UV receiver mask available once as a shader resource;
- no second full Angel texture set;
- no runtime OpenUSD dependency;
- no runtime load of the sculpt target.

Mesh repair may remain if it is still required for RealityKit's sparse-offset import
bug, but it must not mutate UVs, material indices, tangents, or base points.

---

## 8. Atomic presentation and pop prevention

The current scene attaches to `CinematicWorldPresentationCoordinator` before the
projection material finishes compiling. Correct that ordering.

Required sequence:

```text
load production Angel
validate original PBR and blendshape
load dynamic plates and UV receiver mask
render first complete rest/open-eye composite
compile the projection-capable material
bind all original PBR resources and projection resources
run readiness and zero-coverage parity validation
atomically install the material
only then enable/attach the portal root for presentation
```

If projection preparation fails:

```text
leave jawOpenProjection at zero
retain the untouched imported PBR material
continue the portal, music, Angel PR, and story
log one structured fail-soft event
```

Do not briefly expose one material and then swap to another in visible space. Do not
hide a broken swap with a timed delay.

---

## 9. Files the implementation directive must address

At minimum, inspect and specify exact changes for:

```text
Gravitas Plague/Gravitas Plague/Turing/MindsEye/Projection/
    MindEyeAngelProjectionController.swift
    MindEyeProjectionCompositor.swift
    MindEyeProjectionMaterialController.swift
    MindEyeProjectionMaterialFactory.swift
    MindEyeProjectionPlatePackage.swift
    MindEyeProjectionProfile.swift
    MindEyeProjectionValidation.swift
    Shaders/MindEyeProjectionPlateComposite.metal
    Shaders/MindEyeFacialProjection.metal

Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter03/LightTunnel/
    Chapter03LightTunnelPresenter.swift
    Chapter03AngelPortalEntity.swift
    Chapter03AngelEmissionFallbackController.swift

Gravitas Plague/TuringResources/Turing/MindsEye/Projection/
    profiles/angel_head_v1.json
    plates/angel_head_v1/source-manifest.json
    masks/angel_head_v1_projection-mask-uv.png
    masks/angel_head_v1_projection-mask-linear16.png
    cameras/angel_head_v1.camera.json
    targets/angel_head_v1.target.json
```

Also update the relevant host validators, resource publication scripts, and focused
tests. Search for both mask filenames before finalizing; the UV mask is presently
referenced by authoring scripts but not by the production loader.

---

## 10. Required diagnostics

Add bounded, transition-only diagnostics that prove coordinate ownership without
logging every frame:

```text
[AngelProjectionMaterial]
  productionAssetSHA
  originalMaterialType
  projectionMaterialType
  base/emission/normal/metallic/roughness bindings present
  receiverMaskResourcePath
  receiverMaskSHA
  receiverMaskDimensions
  receiverMaskCoordinateSpace=modelUV
  projectionTextureCoordinateSpace=projectorUV
  cameraSHA
  targetSHA
  materialInstalledBeforeVisibility=true|false
  zeroCoverageParityQualified=true|false
```

Add a developer-only diagnostic render mode with four mutually exclusive outputs:

```text
1. original imported PBR only
2. reconstructed projection-capable PBR with projection coverage forced to zero
3. UV receiver mask visualized on the Angel mesh
4. camera-space projector checker/color grid multiplied by UV receiver coverage
```

These modes must be excluded or unreachable in TestFlight production UI.

---

## 11. Acceptance tests

### 11.1 Base material parity

From the same fixed camera and lighting:

```text
render A: untouched imported PBR Angel
render B: projection-capable material, coverage forced to zero
```

Require no UV scrambling, missing texture regions, normal/tangent inversion, channel
swap, or material discontinuity. Establish a numerical image tolerance and include
the comparison artifacts in the completion report.

This test must fail the implementation visible in `IMG_1957.PNG`.

### 11.2 Coordinate-space proof

Use a high-contrast projector checker or numbered grid and a separately distinctive
UV mask diagnostic.

Required result:

- moving the projector camera changes the projected checker registration;
- it does not move the UV receiver boundary on the mesh;
- changing the UV receiver mask changes only the allowed receiver region;
- it does not reframe or warp the projected checker;
- changing the blendshape moves geometry through the fixed projector correctly;
- Mind's Eye features do not swim in UV space.

### 11.3 Blendshape sweep

Test weights:

```text
0.00, 0.25, 0.33, 0.50, 0.75, 1.00
```

At every weight verify:

- original PBR remains correct outside receiver coverage;
- projected face remains registered from the locked camera;
- UV receiver mask remains attached to geometry;
- no material recreation;
- no texture-resource recreation;
- no base-mesh or material pop;
- no invalid sparse-offset repair side effects.

### 11.4 Lifecycle

Test:

- first portal run;
- cancellation during projection preparation;
- projection compilation failure;
- resource/hash failure;
- Angel PR start and completion;
- second portal run;
- reset and teardown.

The original PBR fallback must be restored exactly once, audio must continue, and no
stale material completion may overwrite a newer run.

### 11.5 Physical-device review

On Vision Pro, review from the intended hero view and moderate lateral movement:

- no incorrect/scrambled Angel textures;
- no visible material pop;
- face projection appears emitted from the Angel surface;
- projector registration matches the authored 30-degree camera;
- mask boundary stays on the intended facial geometry;
- profile views fade to the original PBR surface gracefully;
- no duplicate emission;
- no card, duplicate face, or UV-space Mind's Eye image.

Do not claim this pass from simulator-only evidence.

---

## 12. Prohibited shortcuts

Do not:

1. place the Mind's Eye composite into model UV space;
2. sample `projection-mask.png` with projector coordinates;
3. bake the UV receiver mask into the 1440 output alpha;
4. use the camera-space `linear16` mask as production receiver coverage;
5. load the sculpt-target USDZ at runtime;
6. replace the production Angel with the target file;
7. add a face card or duplicate face mesh;
8. ship two complete Angel assets or duplicate PBR texture sets;
9. discard the original PBR appearance outside projection coverage;
10. treat identical texture references as proof of identical material rendering;
11. recreate a material, `LowLevelTexture`, or `TextureResource` per viseme;
12. move the projector with the viewer;
13. tune embers in this pass;
14. hide a material pop behind an arbitrary timer;
15. make projection failure chapter-fatal or audio-fatal;
16. weaken hashes or validators just to make the current payload load.

---

## 13. Required architect deliverable

Return a repository-specific, code-complete Codex implementation directive, not a
general design essay. It must include:

- the selected compile-valid RealityKit material path;
- exact Swift and shader contracts;
- the corrected resource schema;
- exact file-by-file changes;
- migration/removal treatment for the camera-space runtime mask;
- imported-PBR parity strategy;
- atomic presentation ordering;
- fail-soft lifecycle behavior;
- focused unit, GPU, integration, source-audit, and device tests;
- build and validation commands for the installed visionOS 27 SDK;
- a mandatory `PASS / BLOCKED / FAIL` completion report format.

If a public RealityKit API cannot preserve imported material parity while adding the
two-coordinate-space projection, the architect must document the exact SDK
limitation and provide the smallest compile spike proving it before proposing an
asset-authored ShaderGraph fallback. Do not silently approximate the Angel's
material.

---

## 14. Final acceptance statement

The correction is complete only when the production Angel remains visually
identical to its imported PBR appearance outside UV receiver coverage, while the
dynamic Mind's Eye face is perspective-projected from the cube-authored camera onto
the currently deformed blendshape geometry. The UV-authored mask controls only where
that projection is allowed to appear. No projection plate is mapped into the
Angel's UV space, and no UV mask is interpreted in camera space.
