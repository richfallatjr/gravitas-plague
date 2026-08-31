import CryptoKit
import Foundation
import Metal
import MetalKit
import RealityKit

nonisolated struct MindEyeProjectionReceiverMaskMetadata: Sendable, Equatable {
    let resourcePath: String
    let SHA256: String
    let width: Int
    let height: Int
    let bitsPerChannel: Int
    let convention: MindEyeProjectionProfile.ReceiverMaskConvention
    let UVSetName: String
    let UVSetIndex: Int
}

nonisolated final class MindEyeProjectionReceiverMaskPayload: @unchecked Sendable {
    let metadata: MindEyeProjectionReceiverMaskMetadata
    let rawTexture: any MTLTexture

    init(
        metadata: MindEyeProjectionReceiverMaskMetadata,
        rawTexture: any MTLTexture
    ) {
        self.metadata = metadata
        self.rawTexture = rawTexture
    }
}

nonisolated final class MindEyeProjectionReceiverMaskLoader: @unchecked Sendable {
    private let device: any MTLDevice
    private let queue = DispatchQueue(
        label: "com.gravitas.plague.mindseye.projection.receiver-mask-loader",
        qos: .userInitiated
    )

    init(device: any MTLDevice) {
        self.device = device
    }

    func load(
        locator: MindEyeResourceLocator,
        descriptor: MindEyeProjectionProfile.ReceiverUVMask
    ) async throws -> MindEyeProjectionReceiverMaskPayload {
        try Task.checkCancellation()
        let payload: MindEyeProjectionReceiverMaskPayload = try await
            withCheckedThrowingContinuation { continuation in
                queue.async { [device] in
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    precondition(!Thread.isMainThread)
                    continuation.resume(with: autoreleasepool {
                        Result {
                            try descriptor.validate()
                            let url = try locator.resolve(
                                resourcePath: descriptor.resourcePath
                            )
                            let data = try Data(
                                contentsOf: url,
                                options: [.mappedIfSafe]
                            )
                            guard !data.isEmpty else {
                                throw MindEyeProjectionError.missingResource(
                                    descriptor.resourcePath
                                )
                            }
                            let hash = SHA256.hash(data: data).map {
                                String(format: "%02x", $0)
                            }.joined()
                            guard hash == descriptor.SHA256 else {
                                throw MindEyeProjectionError.hashMismatch(
                                    "projection receiver UV mask"
                                )
                            }
                            let header = try MindEyeProjectionReceiverMaskPNGHeader(
                                data: data
                            )
                            guard header.width == descriptor.width,
                                  header.height == descriptor.height,
                                  header.bitsPerChannel == descriptor.bitsPerChannel,
                                  [0, 2, 4, 6].contains(header.colorType) else {
                                throw MindEyeProjectionError.invalidReceiverMask(
                                    "UV receiver-mask PNG metadata does not match the profile"
                                )
                            }
                            let texture = try MTKTextureLoader(device: device).newTexture(
                                URL: url,
                                options: [
                                    .SRGB: NSNumber(value: false),
                                    .origin: MTKTextureLoader.Origin.topLeft,
                                    .textureUsage: NSNumber(
                                        value: MTLTextureUsage.shaderRead.rawValue
                                    ),
                                    .textureStorageMode: NSNumber(
                                        value: MTLStorageMode.private.rawValue
                                    ),
                                    .generateMipmaps: NSNumber(value: false),
                                ]
                            )
                            guard texture.width == descriptor.width,
                                  texture.height == descriptor.height else {
                                throw MindEyeProjectionError.invalidReceiverMask(
                                    "UV receiver-mask dimensions do not match the profile"
                                )
                            }
                            texture.label = "MindEyeProjectionReceiverMaskRaw"
                            return MindEyeProjectionReceiverMaskPayload(
                                metadata: .init(
                                    resourcePath: descriptor.resourcePath,
                                    SHA256: descriptor.SHA256,
                                    width: descriptor.width,
                                    height: descriptor.height,
                                    bitsPerChannel: descriptor.bitsPerChannel,
                                    convention: descriptor.convention,
                                    UVSetName: descriptor.UVSetName,
                                    UVSetIndex: descriptor.UVSetIndex
                                ),
                                rawTexture: texture
                            )
                        }
                    })
                }
            }
        try Task.checkCancellation()
        return payload
    }
}

private nonisolated struct MindEyeProjectionReceiverMaskPNGHeader {
    let width: Int
    let height: Int
    let bitsPerChannel: Int
    let colorType: Int

    init(data: Data) throws {
        guard data.count >= 33,
              data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]),
              data[12..<16] == Data("IHDR".utf8) else {
            throw MindEyeProjectionError.invalidReceiverMask("invalid PNG header")
        }
        func uint32(_ offset: Int) -> Int {
            Int(data[offset]) << 24 |
                Int(data[offset + 1]) << 16 |
                Int(data[offset + 2]) << 8 |
                Int(data[offset + 3])
        }
        width = uint32(16)
        height = uint32(20)
        bitsPerChannel = Int(data[24])
        colorType = Int(data[25])
    }
}

@MainActor
final class MindEyeProjectionReceiverMaskTextureSource {
    let metadata: MindEyeProjectionReceiverMaskMetadata
    let lowLevelTexture: LowLevelTexture
    let textureResource: TextureResource

    private init(
        metadata: MindEyeProjectionReceiverMaskMetadata,
        lowLevelTexture: LowLevelTexture,
        textureResource: TextureResource
    ) {
        self.metadata = metadata
        self.lowLevelTexture = lowLevelTexture
        self.textureResource = textureResource
    }

    static func make(
        payload: MindEyeProjectionReceiverMaskPayload,
        device: any MTLDevice
    ) async throws -> MindEyeProjectionReceiverMaskTextureSource {
        let descriptor = LowLevelTexture.Descriptor(
            textureType: .type2D,
            pixelFormat: .rgba8Unorm,
            width: payload.metadata.width,
            height: payload.metadata.height,
            depth: 1,
            mipmapLevelCount: 1,
            arrayLength: 1,
            textureUsage: [.shaderRead, .shaderWrite],
            swizzle: .init(red: .red, green: .green, blue: .blue, alpha: .alpha)
        )
        let lowLevelTexture = try LowLevelTexture(descriptor: descriptor)
        try await MindEyeProjectionReceiverMaskUploader.upload(
            source: payload.rawTexture,
            destination: lowLevelTexture,
            device: device
        )
        let textureResource = try await TextureResource(from: lowLevelTexture)
        return MindEyeProjectionReceiverMaskTextureSource(
            metadata: payload.metadata,
            lowLevelTexture: lowLevelTexture,
            textureResource: textureResource
        )
    }
}

@MainActor
private enum MindEyeProjectionReceiverMaskUploader {
    static func upload(
        source: any MTLTexture,
        destination: LowLevelTexture,
        device: any MTLDevice
    ) async throws {
        guard let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(
                name: "mindEyeNormalizeReceiverMask"
              ),
              let commandQueue = device.makeCommandQueue(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MindEyeProjectionError.rendererUnavailable(
                "receiver-mask normalization resources are unavailable"
            )
        }
        let pipeline = try await device.makeComputePipelineState(function: function)
        let output = destination.replace(using: commandBuffer)
        guard source.width == output.width, source.height == output.height else {
            throw MindEyeProjectionError.invalidReceiverMask(
                "raw and normalized receiver-mask dimensions differ"
            )
        }
        commandBuffer.label = "MindEyeProjectionReceiverMaskUpload"
        encoder.label = "MindEyeProjectionReceiverMaskNormalize"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(output, index: 1)
        let width = max(1, pipeline.threadExecutionWidth)
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: output.width, height: output.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
        let completed = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            commandBuffer.addCompletedHandler { buffer in
                continuation.resume(returning: buffer.status == .completed)
            }
            commandBuffer.commit()
        }
        guard completed else {
            throw MindEyeProjectionError.renderFailed(
                "receiver-mask normalization command failed"
            )
        }
    }
}
