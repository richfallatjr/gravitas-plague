import CoreGraphics
import Foundation
import RealityKit
import simd

/// Builds the production facial projector with the public visionOS 27
/// programmatic ShaderGraph API. `CustomMaterial` is unavailable on visionOS;
/// this is the supported equivalent and keeps one material on the actual Angel
/// mesh instead of introducing a card or duplicate face.
@MainActor
enum MindEyeProjectionMaterialFactory {
    private static let programCache = MindEyeProjectionMaterialProgramCache()

    struct ApplicationReport: Sendable, Equatable {
        let resolvedMaterialCount: Int
        let appliedMaterialCount: Int
        let runtimeMaterialAvailable: Bool
    }

    private final class CompilationPayload: @unchecked Sendable {
        let inputValues: [String: MaterialParameters.Value]
        let faceCulling: PhysicallyBasedMaterial.FaceCulling
        let contract: MindEyeProjectionImportedPBRContract
        let contractSHA256: String
        let diagnosticMode: MindEyeProjectionMaterialDiagnosticMode

        init(
            inputValues: [String: MaterialParameters.Value],
            faceCulling: PhysicallyBasedMaterial.FaceCulling,
            contract: MindEyeProjectionImportedPBRContract,
            contractSHA256: String,
            diagnosticMode: MindEyeProjectionMaterialDiagnosticMode
        ) {
            self.inputValues = inputValues
            self.faceCulling = faceCulling
            self.contract = contract
            self.contractSHA256 = contractSHA256
            self.diagnosticMode = diagnosticMode
        }
    }

    static func prepare(
        package: MindEyeProjectionPlatePackage,
        projectionTexture: MindEyeProjectionTextureSource,
        receiverMask: MindEyeProjectionReceiverMaskTextureSource,
        subjectRoot: Entity,
        diagnosticMode: MindEyeProjectionMaterialDiagnosticMode = .production
    ) async throws -> MindEyeProjectionMaterialPreparation {
        let resolution = try MindEyeProjectionTargetResolver.resolve(
            descriptor: package.target,
            subjectRoot: subjectRoot
        )
        let materialDescriptor = MindEyeProjectionMaterialDescriptor(
            profile: package.profile,
            camera: package.camera
        )
        var payloads: [CompilationPayload] = []
        var snapshots: [MindEyeProjectionImportedPBRSnapshot] = []
        for target in resolution.materials {
            guard let pbr = target.material as? PhysicallyBasedMaterial else {
                throw MindEyeProjectionError.materialApplicationFailed(
                    "the exact projection slot is not PhysicallyBasedMaterial"
                )
            }
            let snapshot = try MindEyeProjectionImportedPBRSnapshot(
                PBR: pbr,
                contract: package.importedPBRContract,
                entityPath: target.entityPath
            )
            snapshots.append(snapshot)
            let subjectFromEntity = target.entity.transformMatrix(relativeTo: subjectRoot)
            payloads.append(
                CompilationPayload(
                    inputValues: try inputValues(
                        PBR: snapshot,
                        contract: package.importedPBRContract,
                        projectionTexture: projectionTexture.textureResource,
                        receiverMask: receiverMask.textureResource,
                        clipFromEntity: package.camera.clipFromSubjectMatrix * subjectFromEntity,
                        descriptor: materialDescriptor,
                        diagnosticMode: diagnosticMode
                    ),
                    faceCulling: snapshot.faceCulling,
                    contract: package.importedPBRContract,
                    contractSHA256: package.importedPBRContractSHA256,
                    diagnosticMode: diagnosticMode
                )
            )
        }

        // Graph construction and GPU program compilation do not run on the
        // MainActor. The payload is immutable and all RealityKit resources it
        // carries are retained for the duration of compilation.
        let programs = try await Task.detached(priority: .userInitiated) {
            try await payloads.asyncMap { payload in
                let cacheKey = MindEyeProjectionMaterialProgramCache.Key(
                    graphVersion: payload.contract.graphVersion,
                    importedPBRContractSHA256: payload.contractSHA256,
                    diagnosticMode: payload.diagnosticMode
                )
                let program = try await programCache.program(key: cacheKey) {
                    let graph = try MindEyeProjectionShaderGraph.make(
                        contract: payload.contract,
                        diagnosticMode: payload.diagnosticMode
                    )
                    return try await ShaderGraphMaterial.Program(
                        descriptor: .init(
                            shaderGraph: graph,
                            lightingModel: .lit(),
                            isColorDitheringEnabled: false,
                            inputValues: payload.inputValues
                        )
                    )
                }
                return program
            }
        }.value
        let materials = try zip(payloads, programs).map { payload, program in
            var material = ShaderGraphMaterial(program: program)
            for (name, value) in payload.inputValues {
                // These five resources, their hashes, sampling semantics, and
                // the subject-asset hash are immutable members of the imported
                // PBR contract used by the program-cache key. RealityKit 27
                // accepts MaterialParameters.Texture while compiling a Program
                // but does not permit rebinding that enum case on an instance.
                // Keep the exact compiled defaults; all genuinely per-instance
                // inputs (projection/mask textures and matrices) are rebound.
                if importedPBRTextureParameterNames.contains(name) { continue }
                // A newly compiled program already carries these exact defaults.
                // RealityKit rejects redundant writes to some imported texture
                // parameters even though it accepts the same type when the
                // resource actually changes on a cached program.
                if material.getParameter(name: name) == value { continue }
                do {
                    try material.setParameter(name: name, value: value)
                } catch {
                    throw MindEyeProjectionError.materialApplicationFailed(
                        "compiled graph rejected parameter \(name): \(error.localizedDescription)"
                    )
                }
            }
            material.faceCulling = payload.faceCulling
            return material
        }

        let targets = zip(zip(resolution.materials, snapshots), materials).map {
            resolvedAndSnapshot, replacement in
            let (resolved, snapshot) = resolvedAndSnapshot
            return MindEyeProjectionMaterialPreparation.Target(
                entity: resolved.entity,
                entityPath: resolved.entityPath,
                materialIndex: resolved.materialIndex,
                originalMaterial: resolved.material,
                originalPBR: snapshot,
                replacement: replacement
            )
        }
        return MindEyeProjectionMaterialPreparation(
            targets: targets,
            report: .init(
                resolvedMaterialCount: resolution.materials.count,
                preparedMaterialCount: targets.count,
                graphVersion: materialDescriptor.graphVersion
            )
        )
    }

    private static let importedPBRTextureParameterNames: Set<String> = [
        "baseTexture",
        "metallicTexture",
        "roughnessTexture",
        "normalTexture",
        "emissionTexture",
    ]

    static func validateTargets(
        target: MindEyeProjectionTargetDescriptor,
        on subjectRoot: Entity
    ) throws -> ApplicationReport {
        let resolution = try MindEyeProjectionTargetResolver.resolve(
            descriptor: target,
            subjectRoot: subjectRoot
        )
        return ApplicationReport(
            resolvedMaterialCount: resolution.materials.count,
            appliedMaterialCount: 0,
            runtimeMaterialAvailable: false
        )
    }

    private static func inputValues(
        PBR: MindEyeProjectionImportedPBRSnapshot,
        contract: MindEyeProjectionImportedPBRContract,
        projectionTexture: TextureResource,
        receiverMask: TextureResource,
        clipFromEntity: simd_float4x4,
        descriptor: MindEyeProjectionMaterialDescriptor,
        diagnosticMode: MindEyeProjectionMaterialDiagnosticMode
    ) throws -> [String: MaterialParameters.Value] {
        return [
            "projectionTexture": .textureResource(projectionTexture),
            "projectionReceiverUVMask": .textureResource(receiverMask),
            "baseTexture": .texture(PBR.baseTexture),
            "metallicTexture": .texture(PBR.metallicTexture),
            "roughnessTexture": .texture(PBR.roughnessTexture),
            "normalTexture": .texture(PBR.normalTexture),
            "emissionTexture": .texture(PBR.emissionTexture),
            "baseTint": .color(PBR.baseTint),
            "emissionTint": .color(PBR.emissionTint),
            "metallicScale": .float(PBR.metallicScale),
            "roughnessScale": .float(PBR.roughnessScale),
            "specularScale": .float(PBR.specularScale),
            "emissionIntensity": .float(PBR.emissionIntensity),
            "clipFromEntity": .float4x4(clipFromEntity),
            "projectorUVScaleX": .float(descriptor.projectorUVScaleX),
            "projectorUVScaleY": .float(descriptor.projectorUVScaleY),
            "projectorUVOffsetX": .float(descriptor.projectorUVOffsetX),
            "projectorUVOffsetY": .float(descriptor.projectorUVOffsetY),
            "projectionEmissionGain": .float(descriptor.emissionGain),
            "albedoSuppression": .float(descriptor.albedoSuppression),
            "specularSuppression": .float(descriptor.specularSuppression),
            "frustumFeather": .float(descriptor.frustumFeather),
            "projectionEnabled": .float(diagnosticMode.projectionEnabled),
        ]
    }
}

private nonisolated extension Array {
    func asyncMap<T>(
        _ transform: (Element) async throws -> T
    ) async rethrows -> [T] {
        var output: [T] = []
        output.reserveCapacity(count)
        for element in self {
            output.append(try await transform(element))
        }
        return output
    }
}

/// Exact perspective projection, mask/view-cone coverage, original PBR
/// reconstruction, and emission ownership. The composited texture already
/// carries the artist mask in alpha; this graph adds only view/frustum safety.
nonisolated enum MindEyeProjectionShaderGraph {
    static func make(
        contract: MindEyeProjectionImportedPBRContract,
        diagnosticMode: MindEyeProjectionMaterialDiagnosticMode = .production
    ) throws -> ShaderGraph {
        let library = ShaderGraph.NodeLibrary(version: .default)
        let graph = try ShaderGraph(
            named: "MindEyeAngelFacialProjection",
            inputs: inputs,
            outputs: [
                .init(name: "surface", type: .surfaceShader),
            ],
            nodeLibrary: library
        )
        var builder = Builder(
            graph: graph,
            library: library,
            contract: contract,
            diagnosticMode: diagnosticMode
        )
        try builder.build()
        guard graph.validate() else {
            throw MindEyeProjectionError.materialApplicationFailed(
                "the production facial-projection ShaderGraph is invalid"
            )
        }
        return graph
    }

    private static let inputs: [ShaderGraph.NodeDefinition.Input] = [
        .init(name: "projectionTexture", type: .texture, isUniform: true),
        .init(name: "projectionReceiverUVMask", type: .texture, isUniform: true),
        .init(name: "baseTexture", type: .texture, isUniform: true),
        .init(name: "metallicTexture", type: .texture, isUniform: true),
        .init(name: "roughnessTexture", type: .texture, isUniform: true),
        .init(name: "normalTexture", type: .texture, isUniform: true),
        .init(name: "emissionTexture", type: .texture, isUniform: true),
        .init(name: "baseTint", type: .cgColor3, isUniform: true),
        .init(name: "emissionTint", type: .cgColor3, isUniform: true),
        .init(name: "metallicScale", type: .float, isUniform: true),
        .init(name: "roughnessScale", type: .float, isUniform: true),
        .init(name: "specularScale", type: .float, isUniform: true),
        .init(name: "emissionIntensity", type: .float, isUniform: true),
        .init(name: "clipFromEntity", type: .float4x4, isUniform: true),
        .init(name: "projectorUVScaleX", type: .float, isUniform: true),
        .init(name: "projectorUVScaleY", type: .float, isUniform: true),
        .init(name: "projectorUVOffsetX", type: .float, isUniform: true),
        .init(name: "projectorUVOffsetY", type: .float, isUniform: true),
        .init(name: "projectionEmissionGain", type: .float, isUniform: true),
        .init(name: "albedoSuppression", type: .float, isUniform: true),
        .init(name: "specularSuppression", type: .float, isUniform: true),
        .init(name: "frustumFeather", type: .float, isUniform: true),
        .init(name: "projectionEnabled", type: .float, isUniform: true),
    ]

    private struct Builder {
        let graph: ShaderGraph
        let library: ShaderGraph.NodeLibrary
        let contract: MindEyeProjectionImportedPBRContract
        let diagnosticMode: MindEyeProjectionMaterialDiagnosticMode
        private var serial = 0

        init(
            graph: ShaderGraph,
            library: ShaderGraph.NodeLibrary,
            contract: MindEyeProjectionImportedPBRContract,
            diagnosticMode: MindEyeProjectionMaterialDiagnosticMode
        ) {
            self.graph = graph
            self.library = library
            self.contract = contract
            self.diagnosticMode = diagnosticMode
        }

        mutating func build() throws {
            let zero = try constant(.float(0), "zero")
            let one = try constant(.float(1), "one")
            let half = try constant(.float(0.5), "half")
            let negativeHalf = try constant(.float(-0.5), "negativeHalf")
            let object = try constant(.string("object"), "objectSpace")

            let deformedObjectPosition = try node(
                "ND_position_vector3",
                "deformedObjectPosition"
            )
            try connect(object, to: deformedObjectPosition, input: "space")
            let position4 = try node(
                "ND_combine2_vector4VF",
                "deformedObjectPosition4"
            )
            try connect(deformedObjectPosition, to: position4, input: "in1")
            try connect(one, to: position4, input: "in2")
            let clipPosition = try node("ND_multiply_matrix44_vector4", "clipPosition")
            try argument("clipFromEntity", to: clipPosition, input: "in1")
            try connect(position4, to: clipPosition, input: "in2")
            let clip = try node("ND_separate4_vector4", "clipComponents")
            try connect(clipPosition, to: clip, input: "in")
            let ndcX = try binary("ND_divide_float", clip, "outx", clip, "outw", "ndcX")
            let ndcY = try binary("ND_divide_float", clip, "outy", clip, "outw", "ndcY")
            let ndcZ = try binary("ND_divide_float", clip, "outz", clip, "outw", "ndcZ")
            let uScaled = try binary("ND_multiply_float", ndcX, nil, half, nil, "uScaled")
            let vScaled = try binary("ND_multiply_float", ndcY, nil, negativeHalf, nil, "vScaled")
            let fullCameraU = try binary(
                "ND_add_float", uScaled, nil, half, nil, "fullCameraU"
            )
            let fullCameraV = try binary(
                "ND_add_float", vScaled, nil, half, nil, "fullCameraV"
            )
            let scaledU = try multiply(
                fullCameraU,
                port: nil,
                argument: "projectorUVScaleX",
                name: "projectorCropScaledU"
            )
            let scaledV = try multiply(
                fullCameraV,
                port: nil,
                argument: "projectorUVScaleY",
                name: "projectorCropScaledV"
            )
            let u = try add(
                scaledU,
                port: nil,
                argument: "projectorUVOffsetX",
                name: "projectedU"
            )
            let v = try add(
                scaledV,
                port: nil,
                argument: "projectorUVOffsetY",
                name: "projectedV"
            )
            // The authored camera plate arrives horizontally mirrored relative
            // to RealityKit's camera-space projector convention. Flip only the
            // photographic plate lookup; the owner-authored UV receiver mask
            // remains in its original primvars:st orientation.
            let projectionSampleU = try binary(
                "ND_subtract_float",
                one,
                nil,
                u,
                nil,
                "projectionSampleUHorizontalFlip"
            )
            let projectedUV = try node("ND_combine2_vector2", "projectedUV")
            try connect(projectionSampleU, to: projectedUV, input: "in1")
            try connect(v, to: projectedUV, input: "in2")

            let projection = try textureSample(
                input: "projectionTexture",
                uv: projectedUV,
                color: true,
                name: "projectionSample",
                // LowLevelTexture has no imported USD orientation metadata.
                // Let RealityKit perform its texture-V correction; opting out
                // here made the authored photographic plate upside down.
                noFlipV: false
            )
            let projectionParts = try node("ND_separate2_color4CF", "projectionParts")
            try connect(projection, to: projectionParts, input: "in")

            // Model UV is deliberately independent from projectorUV. Original
            // USD PBR maps and the owner-authored receiver mask use primvars:st.
            let modelUV = try node("ND_texcoord_vector2", "modelUVPrimvarsST")
            let receiverMaskSample = try textureSample(
                input: "projectionReceiverUVMask",
                uv: modelUV,
                color: false,
                name: "projectionReceiverUVMaskSample",
                // This is an authored UV-space data texture, not a camera-space
                // photographic plate. Preserve its exact primvars:st addressing.
                // Flipping it moved the very small receiver islands onto the
                // wrong geometry and reduced projection coverage to zero.
                noFlipV: true
            )
            let receiverMaskParts = try node(
                "ND_separate4_vector4",
                "projectionReceiverUVMaskComponents"
            )
            try connect(receiverMaskSample, to: receiverMaskParts, input: "in")
            let receiverCoverage = try binary(
                "ND_subtract_float",
                one,
                nil,
                receiverMaskParts,
                "outx",
                "projectionReceiverCoverage"
            )
            let clampedReceiverCoverage = try clamp01(
                receiverCoverage,
                name: "clampedProjectionReceiverCoverage"
            )
            let receiverMaskSuppression = try multiply(
                clampedReceiverCoverage,
                port: nil,
                argument: "projectionEnabled",
                name: "receiverMaskSuppression"
            )
            let clampedReceiverMaskSuppression = try clamp01(
                receiverMaskSuppression,
                name: "clampedReceiverMaskSuppression"
            )

            let oneMinusU = try binary("ND_subtract_float", one, nil, u, nil, "oneMinusU")
            let oneMinusV = try binary("ND_subtract_float", one, nil, v, nil, "oneMinusV")
            let oneMinusZ = try binary("ND_subtract_float", one, nil, ndcZ, nil, "oneMinusZ")
            let edgeU0 = try smoothstep(u, low: zero, highArgument: "frustumFeather", name: "edgeU0")
            let edgeU1 = try smoothstep(oneMinusU, low: zero, highArgument: "frustumFeather", name: "edgeU1")
            let edgeV0 = try smoothstep(v, low: zero, highArgument: "frustumFeather", name: "edgeV0")
            let edgeV1 = try smoothstep(oneMinusV, low: zero, highArgument: "frustumFeather", name: "edgeV1")
            let depthNear = try smoothstep(ndcZ, low: zero, high: 0.001, name: "depthNear")
            let depthFar = try smoothstep(oneMinusZ, low: zero, high: 0.001, name: "depthFar")
            let positiveW = try ifGreater(clip, port: "outw", threshold: 0.000_001, name: "positiveW")

            // Build mask/geometric visibility independently from photographic
            // alpha or mesh-facing angle. The owner-authored projection is
            // camera-space and must remain present across the curved face.
            var receiverVisibility = clampedReceiverCoverage
            for (factor, name) in [
                (edgeU0, "receiverVisibilityEdgeU0"),
                (edgeU1, "receiverVisibilityEdgeU1"),
                (edgeV0, "receiverVisibilityEdgeV0"),
                (edgeV1, "receiverVisibilityEdgeV1"),
                (depthNear, "receiverVisibilityDepthNear"),
                (depthFar, "receiverVisibilityDepthFar"),
                (positiveW, "receiverVisibilityPositiveW"),
            ] {
                receiverVisibility = try multiply(
                    receiverVisibility,
                    port: nil,
                    factor,
                    name: name
                )
            }
            receiverVisibility = try multiply(
                receiverVisibility,
                port: nil,
                argument: "projectionEnabled",
                name: "receiverVisibilityProjectionEnabled"
            )
            let clampedReceiverVisibility = try clamp01(
                receiverVisibility,
                name: "receiverVisibility"
            )
            let coverage = try multiply(
                projectionParts,
                port: "outa",
                clampedReceiverVisibility,
                name: "coverageProjectedAlphaTimesReceiverVisibility"
            )
            let clampedCoverage = try clamp01(coverage, name: "coverage")

            let baseUV = try transformedUV(
                baseUV: modelUV,
                binding: contract.baseColor,
                name: "baseUV"
            )
            let baseSample = try textureSample(
                input: "baseTexture", uv: baseUV, color: true,
                name: "baseSample", noFlipV: contract.baseColor.noFlipV,
                wrapS: contract.baseColor.wrapS, wrapT: contract.baseColor.wrapT
            )
            let baseParts = try node("ND_separate2_color4CF", "baseParts")
            try connect(baseSample, to: baseParts, input: "in")
            let tintedBase = try node("ND_multiply_color3", "tintedBase")
            try connect(baseParts, port: "outrgb", to: tintedBase, input: "in1")
            try argument("baseTint", to: tintedBase, input: "in2")
            let coverageAlbedo = try multiply(
                clampedReceiverMaskSuppression,
                port: nil,
                argument: "albedoSuppression",
                name: "receiverMaskAlbedoSuppression"
            )
            let baseMultiplier = try binary(
                "ND_subtract_float", one, nil, coverageAlbedo, nil, "baseMultiplier"
            )
            let finalBase = try node("ND_multiply_color3FA", "finalBase")
            try connect(tintedBase, to: finalBase, input: "in1")
            try connect(baseMultiplier, to: finalBase, input: "in2")

            let metallicValue = try scalarMap(
                textureInput: "metallicTexture", uv: modelUV,
                binding: contract.metallic,
                scaleArgument: "metallicScale", name: "metallic"
            )
            let roughnessValue = try scalarMap(
                textureInput: "roughnessTexture", uv: modelUV,
                binding: contract.roughness,
                scaleArgument: "roughnessScale", name: "roughness"
            )
            let oneMinusReceiverMaskSuppression = try binary(
                "ND_subtract_float", one, nil,
                clampedReceiverMaskSuppression, nil,
                "oneMinusReceiverMaskSuppression"
            )
            let retainedRoughness = try multiply(
                roughnessValue, port: nil, oneMinusReceiverMaskSuppression,
                name: "retainedRoughness"
            )
            let finalRoughness = try binary(
                "ND_add_float", retainedRoughness, nil,
                clampedReceiverMaskSuppression, nil,
                "finalRoughness"
            )
            let coverageSpecular = try multiply(
                clampedReceiverMaskSuppression, port: nil,
                argument: "specularSuppression",
                name: "receiverMaskSpecularSuppression"
            )
            let specularMultiplier = try binary(
                "ND_subtract_float", one, nil, coverageSpecular, nil,
                "specularMultiplier"
            )
            let finalSpecular = try multiply(
                specularMultiplier, port: nil, argument: "specularScale",
                name: "finalSpecular"
            )

            let emissionUV = try transformedUV(
                baseUV: modelUV,
                binding: contract.emission,
                name: "emissionUV"
            )
            let emissionSample = try textureSample(
                input: "emissionTexture", uv: emissionUV, color: true,
                name: "emissionSample", noFlipV: contract.emission.noFlipV,
                wrapS: contract.emission.wrapS, wrapT: contract.emission.wrapT
            )
            let emissionParts = try node("ND_separate2_color4CF", "emissionParts")
            try connect(emissionSample, to: emissionParts, input: "in")
            let tintedEmission = try node("ND_multiply_color3", "tintedEmission")
            try connect(emissionParts, port: "outrgb", to: tintedEmission, input: "in1")
            try argument("emissionTint", to: tintedEmission, input: "in2")
            let importedEmissionEnabled = try node(
                "ND_subtract_float",
                "importedEmissionEnabled"
            )
            try connect(one, to: importedEmissionEnabled, input: "in1")
            try argument(
                "projectionEnabled",
                to: importedEmissionEnabled,
                input: "in2"
            )
            let retainedEmissionScale = try multiply(
                importedEmissionEnabled, port: nil,
                argument: "emissionIntensity",
                name: "retainedEmissionScale"
            )
            let retainedEmission = try node("ND_multiply_color3FA", "retainedEmission")
            try connect(tintedEmission, to: retainedEmission, input: "in1")
            try connect(retainedEmissionScale, to: retainedEmission, input: "in2")
            let projectionScale = try multiply(
                clampedCoverage, port: nil, argument: "projectionEmissionGain",
                name: "projectionEmissionScale"
            )
            let projectedEmission = try node("ND_multiply_color3FA", "projectedEmission")
            try connect(projectionParts, port: "outrgb", to: projectedEmission, input: "in1")
            try connect(projectionScale, to: projectedEmission, input: "in2")
            let finalEmission = try node("ND_add_color3", "finalEmission")
            try connect(retainedEmission, to: finalEmission, input: "in1")
            try connect(projectedEmission, to: finalEmission, input: "in2")

            let normalUV = try transformedUV(
                baseUV: modelUV,
                binding: contract.normal,
                name: "normalUV"
            )
            let normalSample = try textureSample(
                input: "normalTexture", uv: normalUV, color: false,
                name: "normalSample", noFlipV: contract.normal.noFlipV,
                wrapS: contract.normal.wrapS, wrapT: contract.normal.wrapT
            )
            let normalParts = try node("ND_separate4_vector4", "normalParts")
            try connect(normalSample, to: normalParts, input: "in")
            // RealityKit's PBR surface consumes a signed tangent-space normal
            // directly. The UsdUVTexture scale/bias in the extracted contract
            // performs that exact [0, 1] -> [-1, 1] decode. Routing through
            // MaterialX ND_normalmap would convert it into world space, which
            // is correct for Standard Surface but not for RealityKit PBR.
            let mappedNormal = try mappedVector3(
                components: normalParts,
                binding: contract.normal,
                name: "mappedTangentNormal"
            )

            // Use RealityKit's native PBR surface rather than the generic
            // MaterialX Standard Surface. This is the renderer contract used
            // by PhysicallyBasedMaterial and is required for zero-coverage
            // parity with the imported Angel material.
            let surface = try node(
                "ND_realitykit_pbr_surfaceshader_2_0",
                "realityKitPBRSurface"
            )
            if diagnosticMode == .visualizeReceiverUVMask {
                let black = try node("ND_combine3_color3", "diagnosticBlack")
                try connect(zero, to: black, input: "in1")
                try connect(zero, to: black, input: "in2")
                try connect(zero, to: black, input: "in3")
                let receiverGray = try node(
                    "ND_combine3_color3",
                    "diagnosticReceiverCoverage"
                )
                try connect(clampedReceiverCoverage, to: receiverGray, input: "in1")
                try connect(clampedReceiverCoverage, to: receiverGray, input: "in2")
                try connect(clampedReceiverCoverage, to: receiverGray, input: "in3")
                try connect(black, to: surface, input: "baseColor")
                try connect(receiverGray, to: surface, input: "emissiveColor")
            } else {
                try connect(finalBase, to: surface, input: "baseColor")
                try connect(finalEmission, to: surface, input: "emissiveColor")
            }
            try connect(mappedNormal, to: surface, input: "normal")
            try connect(finalRoughness, to: surface, input: "roughness")
            try connect(metallicValue, to: surface, input: "metallic")
            try connect(finalSpecular, to: surface, input: "specular")
            try connect(one, to: surface, input: "opacity")
            try graph.connect(
                surface,
                outputPort: "out",
                to: graph.results.name,
                inputPort: "surface"
            )
        }

        private mutating func node(_ definition: String, _ name: String) throws -> String {
            guard let resolved = library.definition(named: definition) else {
                throw MindEyeProjectionError.materialApplicationFailed(
                    "visionOS ShaderGraph node is unavailable: \(definition)"
                )
            }
            serial += 1
            return try graph.addNode(
                .init(name: "\(name)_\(serial)", data: .definition(resolved))
            )
        }

        private mutating func constant(
            _ value: ShaderGraph.Value,
            _ name: String
        ) throws -> String {
            serial += 1
            return try graph.addConstant(value, named: "\(name)_\(serial)")
        }

        private func connect(
            _ output: String,
            port: String? = nil,
            to inputNode: String,
            input: String
        ) throws {
            try graph.connect(
                output,
                outputPort: port,
                to: inputNode,
                inputPort: input
            )
        }

        private func argument(
            _ name: String,
            to inputNode: String,
            input: String
        ) throws {
            try connect(graph.arguments.name, port: name, to: inputNode, input: input)
        }

        private mutating func binary(
            _ definition: String,
            _ first: String,
            _ firstPort: String?,
            _ second: String,
            _ secondPort: String?,
            _ name: String
        ) throws -> String {
            let result = try node(definition, name)
            try connect(first, port: firstPort, to: result, input: "in1")
            try connect(second, port: secondPort, to: result, input: "in2")
            return result
        }

        private mutating func multiply(
            _ first: String,
            port: String?,
            _ second: String,
            name: String
        ) throws -> String {
            try binary("ND_multiply_float", first, port, second, nil, name)
        }

        private mutating func multiply(
            _ first: String,
            port: String?,
            argument: String,
            name: String
        ) throws -> String {
            let result = try node("ND_multiply_float", name)
            try connect(first, port: port, to: result, input: "in1")
            try self.argument(argument, to: result, input: "in2")
            return result
        }

        private mutating func add(
            _ first: String,
            port: String?,
            argument: String,
            name: String
        ) throws -> String {
            let result = try node("ND_add_float", name)
            try connect(first, port: port, to: result, input: "in1")
            try self.argument(argument, to: result, input: "in2")
            return result
        }

        private mutating func smoothstep(
            _ value: String,
            low: String,
            highArgument: String,
            name: String
        ) throws -> String {
            let result = try node("ND_smoothstep_float", name)
            try connect(value, to: result, input: "in")
            try connect(low, to: result, input: "low")
            try argument(highArgument, to: result, input: "high")
            return result
        }

        private mutating func smoothstep(
            _ value: String,
            low: String,
            high: Float,
            name: String
        ) throws -> String {
            let highValue = try constant(.float(high), "\(name)High")
            let result = try node("ND_smoothstep_float", name)
            try connect(value, to: result, input: "in")
            try connect(low, to: result, input: "low")
            try connect(highValue, to: result, input: "high")
            return result
        }

        private mutating func ifGreater(
            _ value: String,
            port: String,
            threshold: Float,
            name: String
        ) throws -> String {
            let thresholdNode = try constant(.float(threshold), "\(name)Threshold")
            let one = try constant(.float(1), "\(name)One")
            let zero = try constant(.float(0), "\(name)Zero")
            let result = try node("ND_ifgreater_float", name)
            try connect(value, port: port, to: result, input: "value1")
            try connect(thresholdNode, to: result, input: "value2")
            try connect(one, to: result, input: "in1")
            try connect(zero, to: result, input: "in2")
            return result
        }

        private mutating func textureSample(
            input: String,
            uv: String,
            color: Bool,
            name: String,
            noFlipV: Bool,
            wrapS: String? = nil,
            wrapT: String? = nil
        ) throws -> String {
            let result = try node(
                color ? "ND_RealityKitTexture2D_color4" :
                    "ND_RealityKitTexture2D_vector4",
                name
            )
            try argument(input, to: result, input: "file")
            try connect(uv, to: result, input: "texcoord")
            let flip = try constant(.bool(noFlipV), "\(name)NoFlipV")
            try connect(flip, to: result, input: "no_flip_v")
            if let wrapS {
                let value = try constant(
                    .string(try shaderGraphWrapMode(wrapS)),
                    "\(name)WrapS"
                )
                try connect(value, to: result, input: "u_wrap_mode")
            }
            if let wrapT {
                let value = try constant(
                    .string(try shaderGraphWrapMode(wrapT)),
                    "\(name)WrapT"
                )
                try connect(value, to: result, input: "v_wrap_mode")
            }
            return result
        }

        private func shaderGraphWrapMode(_ value: String) throws -> String {
            switch value {
            case "repeat": return "repeat"
            case "mirror": return "mirrored_repeat"
            case "clamp": return "clamp_to_edge"
            case "black": return "clamp_to_zero"
            default:
                throw MindEyeProjectionError.unsupportedImportedPBR(
                    "unsupported texture wrap mode \(value)"
                )
            }
        }

        private mutating func clamp01(
            _ value: String,
            name: String
        ) throws -> String {
            let zero = try constant(.float(0), "\(name)Zero")
            let one = try constant(.float(1), "\(name)One")
            let result = try node("ND_clamp_float", name)
            try connect(value, to: result, input: "in")
            try connect(zero, to: result, input: "low")
            try connect(one, to: result, input: "high")
            return result
        }

        private mutating func transformedUV(
            baseUV: String,
            binding: MindEyeProjectionImportedPBRContract.TextureBinding,
            name: String
        ) throws -> String {
            guard !binding.isIdentityUVTransform else { return baseUV }
            let parts = try node("ND_separate2_vector2", "\(name)Parts")
            try connect(baseUV, to: parts, input: "in")
            let scaleX = try constant(.float(binding.transformScale[0]), "\(name)ScaleX")
            let scaleY = try constant(.float(binding.transformScale[1]), "\(name)ScaleY")
            let xScaled = try binary(
                "ND_multiply_float", parts, "outx", scaleX, nil, "\(name)XScaled"
            )
            let yScaled = try binary(
                "ND_multiply_float", parts, "outy", scaleY, nil, "\(name)YScaled"
            )
            let radians = binding.transformRotationDegrees * .pi / 180
            let cosine = try constant(.float(cos(radians)), "\(name)Cos")
            let sine = try constant(.float(sin(radians)), "\(name)Sin")
            let xCos = try binary(
                "ND_multiply_float", xScaled, nil, cosine, nil, "\(name)XCos"
            )
            let ySin = try binary(
                "ND_multiply_float", yScaled, nil, sine, nil, "\(name)YSin"
            )
            let xRotated = try binary(
                "ND_subtract_float", xCos, nil, ySin, nil, "\(name)XRotated"
            )
            let xSin = try binary(
                "ND_multiply_float", xScaled, nil, sine, nil, "\(name)XSin"
            )
            let yCos = try binary(
                "ND_multiply_float", yScaled, nil, cosine, nil, "\(name)YCos"
            )
            let yRotated = try binary(
                "ND_add_float", xSin, nil, yCos, nil, "\(name)YRotated"
            )
            let translateX = try constant(
                .float(binding.transformTranslation[0]),
                "\(name)TranslateX"
            )
            let translateY = try constant(
                .float(binding.transformTranslation[1]),
                "\(name)TranslateY"
            )
            let x = try binary(
                "ND_add_float", xRotated, nil, translateX, nil, "\(name)X"
            )
            let y = try binary(
                "ND_add_float", yRotated, nil, translateY, nil, "\(name)Y"
            )
            let result = try node("ND_combine2_vector2", name)
            try connect(x, to: result, input: "in1")
            try connect(y, to: result, input: "in2")
            return result
        }

        private mutating func mappedComponent(
            _ components: String,
            port: String,
            scale: Float,
            bias: Float,
            name: String
        ) throws -> String {
            let scaleNode = try constant(.float(scale), "\(name)Scale")
            let biasNode = try constant(.float(bias), "\(name)Bias")
            let scaled = try binary(
                "ND_multiply_float", components, port, scaleNode, nil,
                "\(name)Scaled"
            )
            return try binary(
                "ND_add_float", scaled, nil, biasNode, nil, "\(name)Biased"
            )
        }

        private mutating func mappedVector3(
            components: String,
            binding: MindEyeProjectionImportedPBRContract.TextureBinding,
            name: String
        ) throws -> String {
            let x = try mappedComponent(
                components, port: "outx", scale: binding.scale[0],
                bias: binding.bias[0], name: "\(name)X"
            )
            let y = try mappedComponent(
                components, port: "outy", scale: binding.scale[1],
                bias: binding.bias[1], name: "\(name)Y"
            )
            let z = try mappedComponent(
                components, port: "outz", scale: binding.scale[2],
                bias: binding.bias[2], name: "\(name)Z"
            )
            let result = try node("ND_combine3_vector3", name)
            try connect(x, to: result, input: "in1")
            try connect(y, to: result, input: "in2")
            try connect(z, to: result, input: "in3")
            return result
        }

        private mutating func scalarMap(
            textureInput: String,
            uv: String,
            binding: MindEyeProjectionImportedPBRContract.TextureBinding,
            scaleArgument: String,
            name: String
        ) throws -> String {
            let transformed = try transformedUV(
                baseUV: uv,
                binding: binding,
                name: "\(name)UV"
            )
            let sample = try textureSample(
                input: textureInput,
                uv: transformed,
                color: false,
                name: "\(name)Sample",
                noFlipV: binding.noFlipV,
                wrapS: binding.wrapS,
                wrapT: binding.wrapT
            )
            let components = try node("ND_separate4_vector4", "\(name)Components")
            try connect(sample, to: components, input: "in")
            let channelIndex: Int
            let port: String
            switch binding.scalarChannel {
            case .red: (channelIndex, port) = (0, "outx")
            case .green: (channelIndex, port) = (1, "outy")
            case .blue: (channelIndex, port) = (2, "outz")
            case .alpha: (channelIndex, port) = (3, "outw")
            case nil:
                throw MindEyeProjectionError.unsupportedImportedPBR(
                    "\(binding.role) has no scalar channel"
                )
            }
            let mapped = try mappedComponent(
                components,
                port: port,
                scale: binding.scale[channelIndex],
                bias: binding.bias[channelIndex],
                name: "\(name)Source"
            )
            return try multiply(
                mapped,
                port: nil,
                argument: scaleArgument,
                name: "\(name)Scaled"
            )
        }
    }
}
