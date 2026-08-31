import Foundation
import Metal
import RealityKit

@MainActor
final class MindEyeProjectionTextureSource {
    let lowLevelTexture: LowLevelTexture
    let textureResource: TextureResource

    private init(lowLevelTexture: LowLevelTexture, textureResource: TextureResource) {
        self.lowLevelTexture = lowLevelTexture
        self.textureResource = textureResource
    }

    static func make() async throws -> MindEyeProjectionTextureSource {
        let descriptor = LowLevelTexture.Descriptor(
            textureType: .type2D,
            pixelFormat: .bgra8Unorm_srgb,
            width: 1_440,
            height: 1_440,
            depth: 1,
            mipmapLevelCount: 1,
            arrayLength: 1,
            textureUsage: [.shaderRead, .shaderWrite],
            swizzle: .init(red: .red, green: .green, blue: .blue, alpha: .alpha)
        )
        let lowLevelTexture = try LowLevelTexture(descriptor: descriptor)
        let textureResource = try await TextureResource(from: lowLevelTexture)
        return MindEyeProjectionTextureSource(
            lowLevelTexture: lowLevelTexture,
            textureResource: textureResource
        )
    }
}

#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
@MainActor
enum MindEyeProjectionDiagnosticCheckerEncoder {
    static func encode(
        output: MindEyeProjectionTextureSource,
        device: any MTLDevice
    ) async throws {
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(
                name: "mindEyeProjectionDiagnosticChecker"
              ),
              let queue = device.makeCommandQueue(),
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeComputeCommandEncoder() else {
            throw MindEyeProjectionError.rendererUnavailable(
                "diagnostic checker Metal resources are unavailable"
            )
        }
        let pipeline = try await device.makeComputePipelineState(function: function)
        let destination = output.lowLevelTexture.replace(using: buffer)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(destination, index: 0)
        let width = max(1, pipeline.threadExecutionWidth)
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: destination.width, height: destination.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
        let completed = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            buffer.addCompletedHandler {
                continuation.resume(returning: $0.status == .completed)
            }
            buffer.commit()
        }
        guard completed else {
            throw MindEyeProjectionError.coordinateSpaceProofFailed(
                "diagnostic checker command failed"
            )
        }
    }
}
#endif
