import Foundation
import Metal
import MetalKit

nonisolated enum MindEyeTextureColorInterpretation:
    Sendable,
    Equatable
{
    case sRGBColor
    case linearMask
}

nonisolated struct MindEyeTextureLoadRequest:
    Sendable,
    Equatable
{
    let metadata: MindEyeImageMetadata
    let colorInterpretation: MindEyeTextureColorInterpretation
}

nonisolated final class MindEyeGPUTexture: @unchecked Sendable {
    let texture: any MTLTexture
    let metadata: MindEyeImageMetadata
    let colorInterpretation: MindEyeTextureColorInterpretation

    init(
        texture: any MTLTexture,
        metadata: MindEyeImageMetadata,
        colorInterpretation: MindEyeTextureColorInterpretation
    ) {
        self.texture = texture
        self.metadata = metadata
        self.colorInterpretation = colorInterpretation
    }
}

nonisolated protocol MindEyeTextureLoading: Sendable {
    func loadTexture(
        _ request: MindEyeTextureLoadRequest
    ) async throws -> MindEyeGPUTexture
}

nonisolated struct MindEyeTextureExecutionObservation: Sendable, Equatable {
    let isMainThread: Bool
    let queueVerified: Bool
}

nonisolated final class MindEyeSerialTextureLoader:
    @unchecked Sendable,
    MindEyeTextureLoading
{
    private let device: any MTLDevice
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueValue: UInt8 = 1
    private let executionObserver:
        (@Sendable (MindEyeTextureExecutionObservation) -> Void)?

    init(
        device: any MTLDevice,
        label: String = "com.gravitas.plague.mindseye.texture-loader",
        executionObserver:
            (@Sendable (MindEyeTextureExecutionObservation) -> Void)? = nil
    ) {
        self.device = device
        queue = DispatchQueue(label: label, qos: .userInitiated)
        self.executionObserver = executionObserver
        queue.setSpecific(key: queueKey, value: queueValue)
    }

    func loadTexture(
        _ request: MindEyeTextureLoadRequest
    ) async throws -> MindEyeGPUTexture {
        try Task.checkCancellation()
        let texture: MindEyeGPUTexture = try await withCheckedThrowingContinuation {
            continuation in
            queue.async { [self] in
                dispatchPrecondition(condition: .notOnQueue(.main))
                let queueVerified = DispatchQueue.getSpecific(key: queueKey) == queueValue
                precondition(queueVerified)
                precondition(Thread.isMainThread == false)
                executionObserver?(
                    MindEyeTextureExecutionObservation(
                        isMainThread: Thread.isMainThread,
                        queueVerified: queueVerified
                    )
                )

                let result: Result<MindEyeGPUTexture, Error> = autoreleasepool {
                    Result {
                        let loader = MTKTextureLoader(device: device)
                        let isSRGB = request.colorInterpretation == .sRGBColor
                        let options: [MTKTextureLoader.Option: Any] = [
                            .SRGB: NSNumber(value: isSRGB),
                            .generateMipmaps: NSNumber(value: false),
                            .textureUsage: NSNumber(
                                value: MTLTextureUsage.shaderRead.rawValue
                            ),
                            .textureStorageMode: NSNumber(
                                value: MTLStorageMode.private.rawValue
                            ),
                            .origin: MTKTextureLoader.Origin.topLeft
                        ]
                        let sourceTexture = try loader.newTexture(
                            URL: request.metadata.fileURL,
                            options: options
                        )
                        sourceTexture.label = "MindEye_\(request.metadata.resourcePath)"
                        guard sourceTexture.width == request.metadata.header.width,
                              sourceTexture.height == request.metadata.header.height else {
                            throw MindEyeFailure(
                                code: .wrongDimensions,
                                characterID: nil,
                                vignetteID: nil,
                                resourcePath: request.metadata.resourcePath,
                                message: "Loaded Metal texture dimensions do not match validated PNG metadata."
                            )
                        }
                        guard sourceTexture.usage.contains(.shaderRead) else {
                            throw MindEyeFailure(
                                code: .textureLoadFailed,
                                characterID: nil,
                                vignetteID: nil,
                                resourcePath: request.metadata.resourcePath,
                                message: "Mind's Eye source texture is not shader-readable."
                            )
                        }
                        return MindEyeGPUTexture(
                            texture: sourceTexture,
                            metadata: request.metadata,
                            colorInterpretation: request.colorInterpretation
                        )
                    }
                }
                continuation.resume(with: result)
            }
        }
        try Task.checkCancellation()
        return texture
    }
}
