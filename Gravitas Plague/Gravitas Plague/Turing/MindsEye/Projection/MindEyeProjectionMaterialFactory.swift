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
    struct ApplicationReport: Sendable, Equatable {
        let resolvedMaterialCount: Int
        let appliedMaterialCount: Int
        let runtimeMaterialAvailable: Bool
    }

    private final class CompilationPayload: @unchecked Sendable {
        let inputValues: [String: MaterialParameters.Value]
        let faceCulling: PhysicallyBasedMaterial.FaceCulling

        init(
            inputValues: [String: MaterialParameters.Value],
            faceCulling: PhysicallyBasedMaterial.FaceCulling
        ) {
            self.inputValues = inputValues
            self.faceCulling = faceCulling
        }
    }

    static func install(
        package: MindEyeProjectionPlatePackage,
        textureSource: MindEyeProjectionTextureSource,
        subjectRoot: Entity,
        controller: MindEyeProjectionMaterialController
    ) async throws -> ApplicationReport {
        let resolution = try MindEyeProjectionTargetResolver.resolve(
            descriptor: package.target,
            subjectRoot: subjectRoot
        )
        let materialDescriptor = MindEyeProjectionMaterialDescriptor(
            profile: package.profile,
            camera: package.camera
        )
        let cameraPositionSubject = SIMD3<Float>(
            package.camera.subjectFromCameraMatrix.columns.3.x,
            package.camera.subjectFromCameraMatrix.columns.3.y,
            package.camera.subjectFromCameraMatrix.columns.3.z
        )

        var payloads: [CompilationPayload] = []
        for target in resolution.materials {
            guard let pbr = target.material as? PhysicallyBasedMaterial else {
                throw MindEyeProjectionError.materialApplicationFailed(
                    "the exact projection slot is not PhysicallyBasedMaterial"
                )
            }
            try validateImportedPBR(pbr, entityPath: target.entityPath)
            let subjectFromEntity = target.entity.transformMatrix(relativeTo: subjectRoot)
            let entityFromSubject = subjectFromEntity.inverse
            payloads.append(
                CompilationPayload(
                    inputValues: try inputValues(
                        pbr: pbr,
                        projectionTexture: textureSource.textureResource,
                        clipFromEntity: package.camera.clipFromSubjectMatrix * subjectFromEntity,
                        cameraPositionEntity: entityFromSubject.transformPoint(cameraPositionSubject),
                        descriptor: materialDescriptor
                    ),
                    faceCulling: pbr.faceCulling
                )
            )
        }

        // Graph construction and GPU program compilation do not run on the
        // MainActor. The payload is immutable and all RealityKit resources it
        // carries are retained for the duration of compilation.
        let materials = try await Task.detached(priority: .userInitiated) {
            try await payloads.asyncMap { payload in
                let graph = try MindEyeProjectionShaderGraph.make()
                let programDescriptor = ShaderGraphMaterial.Program.Descriptor(
                    shaderGraph: graph,
                    lightingModel: .lit(),
                    isColorDitheringEnabled: false,
                    inputValues: payload.inputValues
                )
                let program = try await ShaderGraphMaterial.Program(
                    descriptor: programDescriptor
                )
                var material = ShaderGraphMaterial(program: program)
                material.faceCulling = payload.faceCulling
                return material
            }
        }.value

        try controller.apply(materials, to: resolution)
        return ApplicationReport(
            resolvedMaterialCount: resolution.materials.count,
            appliedMaterialCount: controller.appliedMaterialCount,
            runtimeMaterialAvailable: controller.appliedMaterialCount ==
                package.target.requiredTargetMaterialCount
        )
    }

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

    private static func validateImportedPBR(
        _ pbr: PhysicallyBasedMaterial,
        entityPath: String
    ) throws {
        guard pbr.baseColor.texture != nil,
              pbr.metallic.texture != nil,
              pbr.roughness.texture != nil,
              pbr.normal.texture != nil,
              pbr.emissiveColor.texture != nil else {
            throw MindEyeProjectionError.materialApplicationFailed(
                "the imported Angel PBR maps are incomplete at \(entityPath)"
            )
        }
    }

    private static func inputValues(
        pbr: PhysicallyBasedMaterial,
        projectionTexture: TextureResource,
        clipFromEntity: simd_float4x4,
        cameraPositionEntity: SIMD3<Float>,
        descriptor: MindEyeProjectionMaterialDescriptor
    ) throws -> [String: MaterialParameters.Value] {
        guard let base = pbr.baseColor.texture,
              let metallic = pbr.metallic.texture,
              let roughness = pbr.roughness.texture,
              let normal = pbr.normal.texture,
              let emission = pbr.emissiveColor.texture else {
            throw MindEyeProjectionError.materialApplicationFailed(
                "the imported Angel PBR maps disappeared during compilation"
            )
        }
        return [
            "projectionTexture": .textureResource(projectionTexture),
            "baseTexture": .texture(base),
            "metallicTexture": .texture(metallic),
            "roughnessTexture": .texture(roughness),
            "normalTexture": .texture(normal),
            "emissionTexture": .texture(emission),
            "baseTint": .color(pbr.baseColor.__tint),
            "emissionTint": .color(pbr.emissiveColor.__color),
            "metallicScale": .float(pbr.metallic.scale),
            "roughnessScale": .float(pbr.roughness.scale),
            "specularScale": .float(pbr.specular.scale),
            "emissionIntensity": .float(pbr.emissiveIntensity),
            "clipFromEntity": .float4x4(clipFromEntity),
            "cameraPositionEntity": .simd3Float(cameraPositionEntity),
            "emissionGain": .float(descriptor.emissionGain),
            "albedoSuppression": .float(descriptor.albedoSuppression),
            "specularSuppression": .float(descriptor.specularSuppression),
            "fullQualityCosine": .float(cos(descriptor.fullQualityAngleRadians)),
            "zeroProjectionCosine": .float(cos(descriptor.zeroProjectionAngleRadians)),
            "frustumFeather": .float(descriptor.frustumFeather),
        ]
    }
}

private nonisolated extension simd_float4x4 {
    func transformPoint(_ point: SIMD3<Float>) -> SIMD3<Float> {
        let transformed = self * SIMD4<Float>(point, 1)
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z) /
            max(0.000_001, transformed.w)
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
    static func make() throws -> ShaderGraph {
        let library = ShaderGraph.NodeLibrary(version: .default)
        let graph = try ShaderGraph(
            named: "MindEyeAngelFacialProjection",
            inputs: inputs,
            outputs: [
                .init(name: "surface", type: .surfaceShader),
            ],
            nodeLibrary: library
        )
        var builder = Builder(graph: graph, library: library)
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
        .init(name: "cameraPositionEntity", type: .float3, isUniform: true),
        .init(name: "emissionGain", type: .float, isUniform: true),
        .init(name: "albedoSuppression", type: .float, isUniform: true),
        .init(name: "specularSuppression", type: .float, isUniform: true),
        .init(name: "fullQualityCosine", type: .float, isUniform: true),
        .init(name: "zeroProjectionCosine", type: .float, isUniform: true),
        .init(name: "frustumFeather", type: .float, isUniform: true),
    ]

    private struct Builder {
        let graph: ShaderGraph
        let library: ShaderGraph.NodeLibrary
        private var serial = 0

        init(graph: ShaderGraph, library: ShaderGraph.NodeLibrary) {
            self.graph = graph
            self.library = library
        }

        mutating func build() throws {
            let zero = try constant(.float(0), "zero")
            let one = try constant(.float(1), "one")
            let half = try constant(.float(0.5), "half")
            let negativeHalf = try constant(.float(-0.5), "negativeHalf")
            let object = try constant(.string("object"), "objectSpace")
            let tangent = try constant(.string("tangent"), "tangentSpace")

            let position = try node("ND_position_vector3", "position")
            try connect(object, to: position, input: "space")
            let position4 = try node("ND_combine2_vector4VF", "position4")
            try connect(position, to: position4, input: "in1")
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
            let u = try binary("ND_add_float", uScaled, nil, half, nil, "projectedU")
            let v = try binary("ND_add_float", vScaled, nil, half, nil, "projectedV")
            let projectedUV = try node("ND_combine2_vector2", "projectedUV")
            try connect(u, to: projectedUV, input: "in1")
            try connect(v, to: projectedUV, input: "in2")

            let projection = try textureSample(
                input: "projectionTexture",
                uv: projectedUV,
                color: true,
                name: "projectionSample",
                noFlipV: true
            )
            let projectionParts = try node("ND_separate2_color4CF", "projectionParts")
            try connect(projection, to: projectionParts, input: "in")

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

            let normal = try node("ND_normal_vector3", "objectNormal")
            try connect(object, to: normal, input: "space")
            let toCamera = try node("ND_subtract_vector3", "toCamera")
            try argument("cameraPositionEntity", to: toCamera, input: "in1")
            try connect(position, to: toCamera, input: "in2")
            let viewDirection = try node("ND_normalize_vector3", "viewDirection")
            try connect(toCamera, to: viewDirection, input: "in")
            let facingDot = try node("ND_dotproduct_vector3", "facingDot")
            try connect(normal, to: facingDot, input: "in1")
            try connect(viewDirection, to: facingDot, input: "in2")
            let facing = try node("ND_smoothstep_float", "viewConeFade")
            try connect(facingDot, to: facing, input: "in")
            try argument("zeroProjectionCosine", to: facing, input: "low")
            try argument("fullQualityCosine", to: facing, input: "high")

            var coverage = try multiply(
                projectionParts,
                port: "outa",
                edgeU0,
                name: "coverageMaskU0"
            )
            for (factor, name) in [
                (edgeU1, "coverageMaskU1"),
                (edgeV0, "coverageMaskV0"),
                (edgeV1, "coverageMaskV1"),
                (depthNear, "coverageDepthNear"),
                (depthFar, "coverageDepthFar"),
                (positiveW, "coveragePositiveW"),
                (facing, "coverageViewCone"),
            ] {
                coverage = try multiply(coverage, port: nil, factor, name: name)
            }
            let clampedCoverage = try node("ND_clamp_float", "coverage")
            try connect(coverage, to: clampedCoverage, input: "in")
            try connect(zero, to: clampedCoverage, input: "low")
            try connect(one, to: clampedCoverage, input: "high")

            let modelUV = try node("ND_texcoord_vector2", "modelUV")
            let baseSample = try textureSample(
                input: "baseTexture", uv: modelUV, color: true,
                name: "baseSample", noFlipV: false
            )
            let baseParts = try node("ND_separate2_color4CF", "baseParts")
            try connect(baseSample, to: baseParts, input: "in")
            let tintedBase = try node("ND_multiply_color3", "tintedBase")
            try connect(baseParts, port: "outrgb", to: tintedBase, input: "in1")
            try argument("baseTint", to: tintedBase, input: "in2")
            let coverageAlbedo = try multiply(
                clampedCoverage, port: nil, argument: "albedoSuppression",
                name: "coverageAlbedoSuppression"
            )
            let baseMultiplier = try binary(
                "ND_subtract_float", one, nil, coverageAlbedo, nil, "baseMultiplier"
            )
            let finalBase = try node("ND_multiply_color3FA", "finalBase")
            try connect(tintedBase, to: finalBase, input: "in1")
            try connect(baseMultiplier, to: finalBase, input: "in2")

            let metallicValue = try scalarMap(
                textureInput: "metallicTexture", uv: modelUV,
                scaleArgument: "metallicScale", name: "metallic"
            )
            let roughnessValue = try scalarMap(
                textureInput: "roughnessTexture", uv: modelUV,
                scaleArgument: "roughnessScale", name: "roughness"
            )
            let oneMinusCoverage = try binary(
                "ND_subtract_float", one, nil, clampedCoverage, nil, "oneMinusCoverage"
            )
            let retainedRoughness = try multiply(
                roughnessValue, port: nil, oneMinusCoverage,
                name: "retainedRoughness"
            )
            let finalRoughness = try binary(
                "ND_add_float", retainedRoughness, nil, clampedCoverage, nil,
                "finalRoughness"
            )
            let coverageSpecular = try multiply(
                clampedCoverage, port: nil, argument: "specularSuppression",
                name: "coverageSpecularSuppression"
            )
            let specularMultiplier = try binary(
                "ND_subtract_float", one, nil, coverageSpecular, nil,
                "specularMultiplier"
            )
            let finalSpecular = try multiply(
                specularMultiplier, port: nil, argument: "specularScale",
                name: "finalSpecular"
            )

            let emissionSample = try textureSample(
                input: "emissionTexture", uv: modelUV, color: true,
                name: "emissionSample", noFlipV: false
            )
            let emissionParts = try node("ND_separate2_color4CF", "emissionParts")
            try connect(emissionSample, to: emissionParts, input: "in")
            let tintedEmission = try node("ND_multiply_color3", "tintedEmission")
            try connect(emissionParts, port: "outrgb", to: tintedEmission, input: "in1")
            try argument("emissionTint", to: tintedEmission, input: "in2")
            let retainedEmissionScale = try multiply(
                oneMinusCoverage, port: nil, argument: "emissionIntensity",
                name: "retainedEmissionScale"
            )
            let retainedEmission = try node("ND_multiply_color3FA", "retainedEmission")
            try connect(tintedEmission, to: retainedEmission, input: "in1")
            try connect(retainedEmissionScale, to: retainedEmission, input: "in2")
            let projectionScale = try multiply(
                clampedCoverage, port: nil, argument: "emissionGain",
                name: "projectionEmissionScale"
            )
            let projectedEmission = try node("ND_multiply_color3FA", "projectedEmission")
            try connect(projectionParts, port: "outrgb", to: projectedEmission, input: "in1")
            try connect(projectionScale, to: projectedEmission, input: "in2")
            let finalEmission = try node("ND_add_color3", "finalEmission")
            try connect(retainedEmission, to: finalEmission, input: "in1")
            try connect(projectedEmission, to: finalEmission, input: "in2")

            let normalSample = try textureSample(
                input: "normalTexture", uv: modelUV, color: false,
                name: "normalSample", noFlipV: false
            )
            let normalParts = try node("ND_separate4_vector4", "normalParts")
            try connect(normalSample, to: normalParts, input: "in")
            let normalRGB = try node("ND_combine3_vector3", "normalRGB")
            try connect(normalParts, port: "outx", to: normalRGB, input: "in1")
            try connect(normalParts, port: "outy", to: normalRGB, input: "in2")
            try connect(normalParts, port: "outz", to: normalRGB, input: "in3")
            let objectTangent = try node("ND_tangent_vector3", "objectTangent")
            try connect(object, to: objectTangent, input: "space")
            let mappedNormal = try node("ND_normalmap", "mappedNormal")
            try connect(normalRGB, to: mappedNormal, input: "in")
            try connect(tangent, to: mappedNormal, input: "space")
            try connect(one, to: mappedNormal, input: "scale")
            try connect(normal, to: mappedNormal, input: "normal")
            try connect(objectTangent, to: mappedNormal, input: "tangent")

            let opaque = try node("ND_combine3_color3", "opaque")
            try connect(one, to: opaque, input: "in1")
            try connect(one, to: opaque, input: "in2")
            try connect(one, to: opaque, input: "in3")
            let surface = try node("ND_standard_surface_surfaceshader", "surface")
            try connect(one, to: surface, input: "base")
            try connect(finalBase, to: surface, input: "base_color")
            try connect(metallicValue, to: surface, input: "metalness")
            try connect(finalSpecular, to: surface, input: "specular")
            try connect(finalRoughness, to: surface, input: "specular_roughness")
            try connect(one, to: surface, input: "emission")
            try connect(finalEmission, to: surface, input: "emission_color")
            try connect(opaque, to: surface, input: "opacity")
            try connect(mappedNormal, to: surface, input: "normal")
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
            noFlipV: Bool
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
            return result
        }

        private mutating func scalarMap(
            textureInput: String,
            uv: String,
            scaleArgument: String,
            name: String
        ) throws -> String {
            let sample = try textureSample(
                input: textureInput,
                uv: uv,
                color: false,
                name: "\(name)Sample",
                noFlipV: false
            )
            let components = try node("ND_separate4_vector4", "\(name)Components")
            try connect(sample, to: components, input: "in")
            return try multiply(
                components,
                port: "outx",
                argument: scaleArgument,
                name: "\(name)Scaled"
            )
        }
    }
}
