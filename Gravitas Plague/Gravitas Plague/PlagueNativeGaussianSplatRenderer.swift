import Foundation
import Metal
import RealityKit
import simd

struct PlagueGaussianSplatAttributeStats {
    var positionMin = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
    var positionMax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)

    var rawScaleMin = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
    var rawScaleMax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)

    var activatedScaleMin = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
    var activatedScaleMax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)

    var rawOpacityMin = Float.greatestFiniteMagnitude
    var rawOpacityMax = -Float.greatestFiniteMagnitude

    var activatedOpacityMin = Float.greatestFiniteMagnitude
    var activatedOpacityMax = -Float.greatestFiniteMagnitude

    var dcMin = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
    var dcMax = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)

    mutating func record(
        position: SIMD3<Float>,
        rawScale: SIMD3<Float>,
        activatedScale: SIMD3<Float>,
        rawOpacity: Float,
        activatedOpacity: Float,
        dc: SIMD3<Float>
    ) {
        positionMin = componentMin(positionMin, position)
        positionMax = componentMax(positionMax, position)
        rawScaleMin = componentMin(rawScaleMin, rawScale)
        rawScaleMax = componentMax(rawScaleMax, rawScale)
        activatedScaleMin = componentMin(activatedScaleMin, activatedScale)
        activatedScaleMax = componentMax(activatedScaleMax, activatedScale)
        rawOpacityMin = min(rawOpacityMin, rawOpacity)
        rawOpacityMax = max(rawOpacityMax, rawOpacity)
        activatedOpacityMin = min(activatedOpacityMin, activatedOpacity)
        activatedOpacityMax = max(activatedOpacityMax, activatedOpacity)
        dcMin = componentMin(dcMin, dc)
        dcMax = componentMax(dcMax, dc)
    }

    var maxActivatedScale: Float {
        max(
            activatedScaleMax.x,
            max(activatedScaleMax.y, activatedScaleMax.z)
        )
    }

    private func componentMin(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            min(lhs.x, rhs.x),
            min(lhs.y, rhs.y),
            min(lhs.z, rhs.z)
        )
    }

    private func componentMax(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            max(lhs.x, rhs.x),
            max(lhs.y, rhs.y),
            max(lhs.z, rhs.z)
        )
    }
}

private struct PlaguePreparedGaussianSplatChunk {
    let scales: [SIMD3<Float>]
    let opacities: [Float]
    let sphericalHarmonicsRGB: [SIMD3<Float>]
    let stats: PlagueGaussianSplatAttributeStats
}

enum PlagueNativeGaussianSplatRenderer {
    static func makeEntities(
        plyURL: URL
    ) async throws -> [Entity] {
        throw NSError(
            domain: "PlagueNativeGaussianSplatRenderer",
            code: 1401,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Bulk Gaussian splat entity loading is disabled for \(plyURL.lastPathComponent). Use PlagueGaussianForestEnvironmentController's stateful stream so chunk 0 renders immediately and the stream runs to completion."
            ]
        )
    }

    static func makeEntity(
        plyURL: URL,
        name: String
    ) async throws -> Entity {
        try PlagueGaussianSplatAvailability.assertNativeAvailable()

        let cloud = try await Task.detached(priority: .userInitiated) {
            try PlagueGaussianSplatPLYParser.parse(
                url: plyURL
            )
        }.value

        let entity = try makeEntity(
            cloud: cloud,
            name: name
        )

        print(
            """
            [PlagueNativeGaussianSplatRenderer] entity created
              name: \(name)
              file: \(plyURL.lastPathComponent)
              splats: \(cloud.splatCount)
              shDegree: \(cloud.sphericalHarmonicsDegree)
              nativeRealityKitGaussianSplat: true
            """
        )

        return entity
    }

    static func makeEntity(
        cloud: PlagueGaussianSplatCloud,
        name: String
    ) throws -> Entity {
        try makeEntity(
            cloud: cloud,
            name: name,
            appearance: PlagueSplatAppearancePresets.nativeRaw
        )
    }

    static func makeEntity(
        cloud: PlagueGaussianSplatCloud,
        name: String,
        appearance: PlagueGaussianSplatAppearanceSettings
    ) throws -> Entity {
        #if os(visionOS) && !targetEnvironment(simulator)
        if #available(visionOS 27.0, *) {
            return try makeNativeEntity(
                cloud: cloud,
                name: name,
                appearance: appearance
            )
        }
        #endif

        try PlagueGaussianSplatAvailability.assertNativeAvailable()

        fatalError("Native Gaussian splat compile gate was true but renderer path was not compiled.")
    }

    static func makeEntity(
        chunk: PlagueGaussianSplatChunk
    ) throws -> Entity {
        try makeEntity(
            chunk: chunk,
            appearance: PlagueSplatAppearancePresets.nativeRaw
        )
    }

    static func makeEntity(
        chunk: PlagueGaussianSplatChunk,
        appearance: PlagueGaussianSplatAppearanceSettings
    ) throws -> Entity {
        #if os(visionOS) && !targetEnvironment(simulator)
        if #available(visionOS 27.0, *) {
            return try makeNativeEntity(
                chunk: chunk,
                appearance: appearance
            )
        }
        #endif

        try PlagueGaussianSplatAvailability.assertNativeAvailable()

        fatalError("Native Gaussian splat compile gate was true but chunk renderer path was not compiled.")
    }
}

struct PlagueNativeSplatChunkHandle {
    let entity: Entity
    let debugChunkIndex: Int
    let debugSplatCount: Int
}

enum PlagueRealityKitGaussianSplatBridge {
    static func makeHandle(
        chunk: PlagueGaussianSplatChunk,
        appearance: PlagueGaussianSplatAppearanceSettings
    ) throws -> PlagueNativeSplatChunkHandle {
        let entity = try makeEntity(
            chunk: chunk,
            appearance: appearance
        )

        return PlagueNativeSplatChunkHandle(
            entity: entity,
            debugChunkIndex: chunk.chunkIndex,
            debugSplatCount: chunk.count
        )
    }

    static func makeEntity(
        chunk: PlagueGaussianSplatChunk
    ) throws -> Entity {
        try makeEntity(
            chunk: chunk,
            appearance: PlagueSplatAppearancePresets.nativeRaw
        )
    }

    static func makeEntity(
        chunk: PlagueGaussianSplatChunk,
        appearance: PlagueGaussianSplatAppearanceSettings
    ) throws -> Entity {
        print(
            """
            [PlagueRealityKitGaussianSplatBridge] creating native resource
              chunkIndex: \(chunk.chunkIndex)
              splats: \(chunk.count)
              shDegree: \(chunk.sphericalHarmonicsDegree)
              positionCount: \(chunk.positions.count)
              scaleCount: \(chunk.scales.count)
              rotationCount: \(chunk.rotations.count)
              opacityCount: \(chunk.opacities.count)
              shCount: \(chunk.sphericalHarmonicsRGB.count)
              noFallback: true
            """
        )

        let entity = try PlagueNativeGaussianSplatRenderer.makeEntity(
            chunk: chunk,
            appearance: appearance
        )

        print(
            """
            [PlagueRealityKitGaussianSplatBridge] native component attached
              chunkIndex: \(chunk.chunkIndex)
              splats: \(chunk.count)
              noFallback: true
            """
        )

        return entity
    }
}

#if os(visionOS) && !targetEnvironment(simulator)
@available(visionOS 27.0, *)
private extension PlagueNativeGaussianSplatRenderer {
    static func prepareChunkForUpload(
        chunk: PlagueGaussianSplatChunk,
        appearance: PlagueGaussianSplatAppearanceSettings
    ) throws -> PlaguePreparedGaussianSplatChunk {
        let coeffCount = (chunk.sphericalHarmonicsDegree + 1)
            * (chunk.sphericalHarmonicsDegree + 1)

        guard chunk.sphericalHarmonicsRGB.count == chunk.count * coeffCount else {
            throw NSError(
                domain: "PlagueSplatAppearance",
                code: 200,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Spherical harmonic buffer count mismatch for chunk \(chunk.chunkIndex). expected=\(chunk.count * coeffCount) actual=\(chunk.sphericalHarmonicsRGB.count)"
                ]
            )
        }

        let scaleOffset = log(
            max(appearance.gaussianScaleMultiplier, 0.0001)
        )

        var uploadedScales: [SIMD3<Float>] = []
        var uploadedOpacities: [Float] = []
        var uploadedSphericalHarmonics = chunk.sphericalHarmonicsRGB
        var stats = PlagueGaussianSplatAttributeStats()

        uploadedScales.reserveCapacity(chunk.count)
        uploadedOpacities.reserveCapacity(chunk.count)

        for index in 0..<chunk.count {
            let rawScale = chunk.scales[index]
            let rawScaleWithOffset = SIMD3<Float>(
                rawScale.x + scaleOffset,
                rawScale.y + scaleOffset,
                rawScale.z + scaleOffset
            )

            let uploadedScale: SIMD3<Float>
            let activatedScale: SIMD3<Float>

            if appearance.useRawScaleWithExponentialActivation {
                uploadedScale = rawScaleWithOffset
                activatedScale = SIMD3<Float>(
                    exp(rawScaleWithOffset.x),
                    exp(rawScaleWithOffset.y),
                    exp(rawScaleWithOffset.z)
                )
            } else {
                activatedScale = SIMD3<Float>(
                    exp(rawScaleWithOffset.x),
                    exp(rawScaleWithOffset.y),
                    exp(rawScaleWithOffset.z)
                )
                uploadedScale = activatedScale
            }

            let rawOpacity = chunk.opacities[index]
            let rawOpacityWithBias = rawOpacity + appearance.opacityLogitBias

            let uploadedOpacity: Float
            let activatedOpacity = sigmoid(rawOpacityWithBias)

            if appearance.useRawOpacityWithSigmoidActivation {
                uploadedOpacity = rawOpacityWithBias
            } else {
                uploadedOpacity = activatedOpacity
            }

            let coefficientIndex = index * coeffCount
            let dc = uploadedSphericalHarmonics[coefficientIndex]
            var uploadedDC = dc

            if (!appearance.useRawSphericalHarmonicCoefficients ||
                appearance.debugConvertDegreeZeroDCToRGB) &&
                chunk.sphericalHarmonicsDegree == 0 {
                uploadedDC = PlagueGaussianSplatColorMath.dcToDisplayRGB(dc)

                if appearance.debugSwapRGBToBGR {
                    uploadedDC = SIMD3<Float>(
                        uploadedDC.z,
                        uploadedDC.y,
                        uploadedDC.x
                    )
                }
            }

            uploadedSphericalHarmonics[coefficientIndex] = uploadedDC
            uploadedScales.append(uploadedScale)
            uploadedOpacities.append(uploadedOpacity)

            stats.record(
                position: chunk.positions[index],
                rawScale: rawScale,
                activatedScale: activatedScale,
                rawOpacity: rawOpacity,
                activatedOpacity: activatedOpacity,
                dc: dc
            )
        }

        print(
            """
            [PlagueSplatAppearance] color interpretation
              shDegree: \(chunk.sphericalHarmonicsDegree)
              rawSH: \(appearance.useRawSphericalHarmonicCoefficients)
              debugConvertDegreeZeroDCToRGB: \(appearance.debugConvertDegreeZeroDCToRGB)
              debugSwapRGBToBGR: \(appearance.debugSwapRGBToBGR)
            """
        )

        print(
            """
            [PlagueSplatAppearance] attribute stats
              chunkIndex: \(chunk.chunkIndex)
              positionMin: \(stats.positionMin)
              positionMax: \(stats.positionMax)

              rawScaleMin: \(stats.rawScaleMin)
              rawScaleMax: \(stats.rawScaleMax)
              activatedScaleMin: \(stats.activatedScaleMin)
              activatedScaleMax: \(stats.activatedScaleMax)

              rawOpacityMin: \(stats.rawOpacityMin)
              rawOpacityMax: \(stats.rawOpacityMax)
              activatedOpacityMin: \(stats.activatedOpacityMin)
              activatedOpacityMax: \(stats.activatedOpacityMax)

              dcMin: \(stats.dcMin)
              dcMax: \(stats.dcMax)
            """
        )

        if stats.maxActivatedScale < 0.002 {
            print(
                """
                [PlagueSplatAppearance] WARNING activated Gaussian scales are extremely small
                  chunkIndex: \(chunk.chunkIndex)
                  maxActivatedScale: \(stats.maxActivatedScale)
                  resultLikely: point-cloud-like rendering
                  suggestedTest: increase gaussianScaleMultiplier to 2, 4, or 8
                """
            )
        }

        return PlaguePreparedGaussianSplatChunk(
            scales: uploadedScales,
            opacities: uploadedOpacities,
            sphericalHarmonicsRGB: uploadedSphericalHarmonics,
            stats: stats
        )
    }

    static func sigmoid(
        _ value: Float
    ) -> Float {
        1.0 / (1.0 + exp(-value))
    }

    static func makeNativeEntity(
        chunk: PlagueGaussianSplatChunk,
        appearance: PlagueGaussianSplatAppearanceSettings
    ) throws -> Entity {
        try PlagueGaussianSplatAvailability.assertNativeAvailable()

        print(
            """
            [PlagueNativeGaussianSplatRenderer] building native chunk resource
              file: \(chunk.sourceURL.lastPathComponent)
              chunkIndex: \(chunk.chunkIndex)
              splats: \(chunk.count)
              shDegree: \(chunk.sphericalHarmonicsDegree)
              noFallback: true
            """
        )

        let prepared = try prepareChunkForUpload(
            chunk: chunk,
            appearance: appearance
        )

        let position = try makeFloat3BufferDescriptor(
            chunk.positions,
            label: "positions_chunk\(chunk.chunkIndex)"
        )

        let scale = try makeFloat3BufferDescriptor(
            prepared.scales,
            label: "scales_chunk\(chunk.chunkIndex)"
        )

        let rotation = try makeFloat4BufferDescriptor(
            chunk.rotations,
            label: "rotations_xyzw_chunk\(chunk.chunkIndex)"
        )

        let opacity = try makeFloatBufferDescriptor(
            prepared.opacities,
            label: "opacities_chunk\(chunk.chunkIndex)"
        )

        let sphericalHarmonicCoefficientCount = (chunk.sphericalHarmonicsDegree + 1)
            * (chunk.sphericalHarmonicsDegree + 1)

        let sphericalHarmonics = try makeFloat3BufferDescriptor(
            prepared.sphericalHarmonicsRGB,
            label: "spherical_harmonics_rgb_chunk\(chunk.chunkIndex)",
            descriptorStride: 3 * MemoryLayout<Float>.stride * sphericalHarmonicCoefficientCount
        )

        let degree = try sphericalHarmonicDegree(
            chunk.sphericalHarmonicsDegree
        )

        let bufferResource = try GaussianSplatResource.BufferResource(
            count: chunk.count,
            position: position,
            scale: scale,
            rotation: rotation,
            opacity: opacity,
            sphericalHarmonics: (
                sphericalHarmonics,
                degree
            )
        )

        let resource = GaussianSplatResource(bufferResource)

        resource.scaleActivation = appearance.useRawScaleWithExponentialActivation
            ? .exponential
            : .identity
        resource.opacityActivation = appearance.useRawOpacityWithSigmoidActivation
            ? .sigmoid
            : .identity
        resource.projectionMode = .perspective
        resource.sortingMode = .depth

        print(
            """
            [PlagueSplatAppearance] activation settings
              rawScaleWithExponential: \(appearance.useRawScaleWithExponentialActivation)
              rawOpacityWithSigmoid: \(appearance.useRawOpacityWithSigmoidActivation)
              gaussianScaleMultiplier: \(appearance.gaussianScaleMultiplier)
              opacityLogitBias: \(appearance.opacityLogitBias)
              scaleActivation: \(resource.scaleActivation)
              opacityActivation: \(resource.opacityActivation)
            """
        )

        let entity = Entity()
        entity.name = "GaussianSplatChunk_\(chunk.chunkIndex)"
        entity.components.set(
            GaussianSplatComponent(resource)
        )

        print(
            """
            [PlagueNativeGaussianSplatRenderer] native splat chunk entity created
              name: \(entity.name)
              file: \(chunk.sourceURL.lastPathComponent)
              chunkIndex: \(chunk.chunkIndex)
              range: \(chunk.sourceVertexRange.lowerBound)..<\(chunk.sourceVertexRange.upperBound)
              splats: \(chunk.count)
              shDegree: \(chunk.sphericalHarmonicsDegree)
              noFallback: true
            """
        )

        return entity
    }

    static func makeNativeEntity(
        cloud: PlagueGaussianSplatCloud,
        name: String,
        appearance: PlagueGaussianSplatAppearanceSettings
    ) throws -> Entity {
        try PlagueGaussianSplatAvailability.assertNativeAvailable()

        let position = try makeFloat3BufferDescriptor(
            cloud.positions,
            label: "positions"
        )

        let scale = try makeFloat3BufferDescriptor(
            cloud.scales,
            label: "scales"
        )

        let rotationVectors = cloud.rotations.map(\.vector)

        let rotation = try makeFloat4BufferDescriptor(
            rotationVectors,
            label: "rotations_xyzw"
        )

        let opacity = try makeFloatBufferDescriptor(
            cloud.opacities,
            label: "opacities"
        )

        let sphericalHarmonicCoefficientCount = (cloud.sphericalHarmonicsDegree + 1)
            * (cloud.sphericalHarmonicsDegree + 1)

        let sphericalHarmonics = try makeFloat3BufferDescriptor(
            cloud.sphericalHarmonicsRGB,
            label: "spherical_harmonics_rgb",
            descriptorStride: 3 * MemoryLayout<Float>.stride * sphericalHarmonicCoefficientCount
        )

        let degree = try sphericalHarmonicDegree(
            cloud.sphericalHarmonicsDegree
        )

        let bufferResource = try GaussianSplatResource.BufferResource(
            count: cloud.splatCount,
            position: position,
            scale: scale,
            rotation: rotation,
            opacity: opacity,
            sphericalHarmonics: (
                sphericalHarmonics,
                degree
            )
        )

        let resource = GaussianSplatResource(bufferResource)

        resource.scaleActivation = appearance.useRawScaleWithExponentialActivation
            ? .exponential
            : .identity
        resource.opacityActivation = appearance.useRawOpacityWithSigmoidActivation
            ? .sigmoid
            : .identity
        resource.projectionMode = .perspective
        resource.sortingMode = .depth

        let entity = Entity()
        entity.name = name
        entity.components.set(
            GaussianSplatComponent(resource)
        )

        print(
            """
            [PlagueNativeGaussianSplatRenderer] native splat entity created
              name: \(name)
              file: \(cloud.sourceURL.lastPathComponent)
              splats: \(cloud.splatCount)
              shDegree: \(cloud.sphericalHarmonicsDegree)
              noFallback: true
            """
        )

        return entity
    }

    static func makeFloat3BufferDescriptor(
        _ values: [SIMD3<Float>],
        label: String,
        descriptorStride: Int = 3 * MemoryLayout<Float>.stride
    ) throws -> GaussianSplatResource.BufferDescriptor {
        guard !values.isEmpty else {
            throw NSError(
                domain: "PlagueNativeGaussianSplatRenderer",
                code: 100,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Cannot create empty Gaussian splat buffer \(label)."
                ]
            )
        }

        let byteCount = values.count * 3 * MemoryLayout<Float>.stride
        let buffer = try LowLevelBuffer(
            descriptor: LowLevelBuffer.Descriptor(
                capacity: aligned16(byteCount),
                sizeMultiple: 16
            )
        )

        buffer.replaceUnsafeMutableBytes { rawBuffer in
            let target = rawBuffer.bindMemory(to: Float.self)

            for (index, value) in values.enumerated() {
                let base = index * 3
                target[base] = value.x
                target[base + 1] = value.y
                target[base + 2] = value.z
            }
        }

        buffer.bytesUsed = byteCount

        print(
            """
            [PlagueNativeGaussianSplatRenderer] buffer created
              label: \(label)
              elements: \(values.count)
              storageStride: \(3 * MemoryLayout<Float>.stride)
              descriptorStride: \(descriptorStride)
              bytes: \(byteCount)
              noFallback: true
            """
        )

        return GaussianSplatResource.BufferDescriptor(
            buffer: buffer,
            format: .float3,
            stride: descriptorStride,
            offset: 0
        )
    }

    static func makeFloat4BufferDescriptor(
        _ values: [SIMD4<Float>],
        label: String
    ) throws -> GaussianSplatResource.BufferDescriptor {
        guard !values.isEmpty else {
            throw NSError(
                domain: "PlagueNativeGaussianSplatRenderer",
                code: 100,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Cannot create empty Gaussian splat buffer \(label)."
                ]
            )
        }

        let byteCount = values.count * 4 * MemoryLayout<Float>.stride
        let buffer = try LowLevelBuffer(
            descriptor: LowLevelBuffer.Descriptor(
                capacity: aligned16(byteCount),
                sizeMultiple: 16
            )
        )

        buffer.replaceUnsafeMutableBytes { rawBuffer in
            let target = rawBuffer.bindMemory(to: Float.self)

            for (index, value) in values.enumerated() {
                let base = index * 4
                target[base] = value.x
                target[base + 1] = value.y
                target[base + 2] = value.z
                target[base + 3] = value.w
            }
        }

        buffer.bytesUsed = byteCount

        print(
            """
            [PlagueNativeGaussianSplatRenderer] buffer created
              label: \(label)
              elements: \(values.count)
              storageStride: \(4 * MemoryLayout<Float>.stride)
              descriptorStride: \(4 * MemoryLayout<Float>.stride)
              bytes: \(byteCount)
              noFallback: true
            """
        )

        return GaussianSplatResource.BufferDescriptor(
            buffer: buffer,
            format: .float4,
            stride: 4 * MemoryLayout<Float>.stride,
            offset: 0
        )
    }

    static func makeFloatBufferDescriptor(
        _ values: [Float],
        label: String
    ) throws -> GaussianSplatResource.BufferDescriptor {
        guard !values.isEmpty else {
            throw NSError(
                domain: "PlagueNativeGaussianSplatRenderer",
                code: 100,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Cannot create empty Gaussian splat buffer \(label)."
                ]
            )
        }

        let byteCount = values.count * MemoryLayout<Float>.stride
        let buffer = try LowLevelBuffer(
            descriptor: LowLevelBuffer.Descriptor(
                capacity: aligned16(byteCount),
                sizeMultiple: 16
            )
        )

        buffer.replaceUnsafeMutableBytes { rawBuffer in
            values.withUnsafeBufferPointer { source in
                guard let sourceBase = source.baseAddress,
                      let targetBase = rawBuffer.baseAddress else {
                    return
                }

                targetBase.copyMemory(
                    from: sourceBase,
                    byteCount: byteCount
                )
            }
        }

        buffer.bytesUsed = byteCount

        print(
            """
            [PlagueNativeGaussianSplatRenderer] buffer created
              label: \(label)
              elements: \(values.count)
              storageStride: \(MemoryLayout<Float>.stride)
              descriptorStride: \(MemoryLayout<Float>.stride)
              bytes: \(byteCount)
              noFallback: true
            """
        )

        return GaussianSplatResource.BufferDescriptor(
            buffer: buffer,
            format: .float,
            stride: MemoryLayout<Float>.stride,
            offset: 0
        )
    }

    static func aligned16(
        _ value: Int
    ) -> Int {
        (value + 15) & ~15
    }

    static func sphericalHarmonicDegree(
        _ degree: Int
    ) throws -> GaussianSplatResource.SphericalHarmonicDegree {
        switch degree {
        case 0:
            return .zero
        case 1:
            return .first
        case 2:
            return .second
        case 3:
            return .third
        default:
            throw NSError(
                domain: "PlagueNativeGaussianSplatRenderer",
                code: 101,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unsupported spherical harmonic degree \(degree)."
                ]
            )
        }
    }
}
#endif

struct PlagueGaussianSplatChunkSettings {
    var maxSplatsPerChunk: Int = 200_000
}

enum PlagueGaussianSplatChunker {
    static func makeChunkEntities(
        cloud: PlagueGaussianSplatCloud,
        baseName: String,
        settings: PlagueGaussianSplatChunkSettings = .init()
    ) throws -> [Entity] {
        guard cloud.splatCount > settings.maxSplatsPerChunk else {
            return [
                try PlagueNativeGaussianSplatRenderer.makeEntity(
                    cloud: cloud,
                    name: baseName
                )
            ]
        }

        var entities: [Entity] = []
        var start = 0
        var chunkIndex = 0

        while start < cloud.splatCount {
            let end = min(
                start + settings.maxSplatsPerChunk,
                cloud.splatCount
            )

            let chunk = slice(
                cloud: cloud,
                range: start..<end
            )

            let entity = try PlagueNativeGaussianSplatRenderer.makeEntity(
                cloud: chunk,
                name: "\(baseName)_chunk\(chunkIndex)"
            )

            entities.append(entity)

            start = end
            chunkIndex += 1
        }

        print(
            """
            [PlagueGaussianSplatChunker] chunked cloud
              baseName: \(baseName)
              splats: \(cloud.splatCount)
              chunks: \(entities.count)
              maxSplatsPerChunk: \(settings.maxSplatsPerChunk)
            """
        )

        return entities
    }

    static func slice(
        cloud: PlagueGaussianSplatCloud,
        range: Range<Int>
    ) -> PlagueGaussianSplatCloud {
        let coeffCount = (cloud.sphericalHarmonicsDegree + 1)
            * (cloud.sphericalHarmonicsDegree + 1)

        let shStart = range.lowerBound * coeffCount
        let shEnd = range.upperBound * coeffCount

        let positions = Array(cloud.positions[range])
        let scales = Array(cloud.scales[range])
        let rotations = Array(cloud.rotations[range])
        let opacities = Array(cloud.opacities[range])
        let sh = Array(cloud.sphericalHarmonicsRGB[shStart..<shEnd])

        var minV = SIMD3<Float>(
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude
        )

        var maxV = SIMD3<Float>(
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude
        )

        for p in positions {
            minV = componentMin(minV, p)
            maxV = componentMax(maxV, p)
        }

        return PlagueGaussianSplatCloud(
            sourceURL: cloud.sourceURL,
            splatCount: positions.count,
            positions: positions,
            scales: scales,
            rotations: rotations,
            opacities: opacities,
            sphericalHarmonicsRGB: sh,
            sphericalHarmonicsDegree: cloud.sphericalHarmonicsDegree,
            boundsMin: minV,
            boundsMax: maxV
        )
    }

    private static func componentMin(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            min(lhs.x, rhs.x),
            min(lhs.y, rhs.y),
            min(lhs.z, rhs.z)
        )
    }

    private static func componentMax(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            max(lhs.x, rhs.x),
            max(lhs.y, rhs.y),
            max(lhs.z, rhs.z)
        )
    }
}

@MainActor
final class PlagueGaussianSplatCache {
    static let shared = PlagueGaussianSplatCache()

    func entities(
        for atmosphere: PlagueForestAtmosphere,
        sourceURL: URL
    ) async throws -> [Entity] {
        throw NSError(
            domain: "PlagueGaussianSplatCache",
            code: 701,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Cached bulk Gaussian splat entities are disabled for \(atmosphere.rawValue) from \(sourceURL.lastPathComponent). Use PlagueGaussianForestEnvironmentController's stateful stream."
            ]
        )
    }
}
