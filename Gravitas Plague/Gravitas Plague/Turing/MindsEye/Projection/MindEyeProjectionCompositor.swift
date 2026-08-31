import Foundation
import MLX
import Metal
import RealityKit

nonisolated final class MindEyeProjectionCompositorResources: @unchecked Sendable {
    let commandQueue: any MTLCommandQueue
    let pipeline: any MTLComputePipelineState

    init(commandQueue: any MTLCommandQueue, pipeline: any MTLComputePipelineState) {
        self.commandQueue = commandQueue
        self.pipeline = pipeline
    }
}

actor MindEyeProjectionCompositorPipeline {
    private let device: any MTLDevice
    private let compileQueue = DispatchQueue(
        label: "com.gravitas.plague.mindseye.angel-projection-compositor",
        qos: .userInitiated
    )
    private var cached: Result<MindEyeProjectionCompositorResources, Error>?

    init(device: any MTLDevice) {
        self.device = device
    }

    func resources() async throws -> MindEyeProjectionCompositorResources {
        if let cached { return try cached.get() }
        let result: Result<MindEyeProjectionCompositorResources, Error> =
            await withCheckedContinuation { continuation in
                compileQueue.async { [device] in
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    precondition(!Thread.isMainThread)
                    continuation.resume(returning: autoreleasepool {
                        Result {
                            guard let library = device.makeDefaultLibrary(),
                                  let function = library.makeFunction(
                                    name: "mindEyeCompositeProjectionFrame"
                                  ),
                                  let queue = device.makeCommandQueue() else {
                                throw MindEyeProjectionError.rendererUnavailable(
                                    "projection compositor Metal resources are unavailable"
                                )
                            }
                            queue.label = "MindEyeProjectionCompositorCommandQueue"
                            return MindEyeProjectionCompositorResources(
                                commandQueue: queue,
                                pipeline: try device.makeComputePipelineState(function: function)
                            )
                        }
                    })
                }
            }
        cached = result
        return try result.get()
    }
}

nonisolated struct MindEyeProjectionCompositeUniforms: Sendable, Equatable {
    var sourceAndOutputDimensions: SIMD4<UInt32>
    var cropOrigin: SIMD2<UInt32>
    var reserved: SIMD2<UInt32> = .zero
}

@MainActor
enum MindEyeProjectionCompositeEncoder {
    #if DEBUG
    private static var completedFrameCount: UInt64 = 0
    private static var accumulatedGPUMilliseconds: Double = 0
    #endif

    static func encodeAndCommit(
        package: MindEyeProjectionPlatePackage,
        frame: MindEyeCompositeFrameState,
        output: MindEyeProjectionTextureSource,
        resources: MindEyeProjectionCompositorResources
    ) async throws {
        if let failure = MindEyeCompositeFrameStateValidator.validateBasic(frame) {
            throw failure
        }
        let eye: MindEyeProjectionPlateTexture
        switch frame.eyeSelection {
        case .open(let index):
            guard package.eyeOpen.indices.contains(index) else {
                throw MindEyeProjectionError.invalidPlateManifest("open-eye index is unavailable")
            }
            eye = package.eyeOpen[index]
        case .closed(let index):
            guard package.eyeClosed.indices.contains(index) else {
                throw MindEyeProjectionError.invalidPlateManifest("closed-eye index is unavailable")
            }
            eye = package.eyeClosed[index]
        }
        guard let mouths = package.mouths[frame.mouthSelection.pose],
              mouths.indices.contains(frame.mouthSelection.variantIndex) else {
            throw MindEyeProjectionError.invalidPlateManifest("mouth index is unavailable")
        }
        let mouth = mouths[frame.mouthSelection.variantIndex]
        let colors = [
            package.projectionBase.texture,
            eye.texture,
            mouth.texture,
        ]
        guard colors.allSatisfy({
            $0.width == 1_728 && $0.height == 1_728 &&
                [.rgba8Unorm_srgb, .bgra8Unorm_srgb].contains($0.pixelFormat)
        }),
        output.lowLevelTexture.descriptor.width == 1_440,
        output.lowLevelTexture.descriptor.height == 1_440 else {
            throw MindEyeProjectionError.invalidPlateManifest(
                "projection compositor texture formats violate the square contract"
            )
        }

        guard let commandBuffer = resources.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MindEyeProjectionError.rendererUnavailable(
                "projection compositor could not create a command buffer"
            )
        }
        commandBuffer.label = "MindEyeProjectionComposite.\(frame.sequence)"
        let destination = output.lowLevelTexture.replace(using: commandBuffer)
        encoder.label = "MindEyeProjectionCompositeEncoder"
        encoder.setComputePipelineState(resources.pipeline)
        encoder.setTexture(package.projectionBase.texture, index: 0)
        encoder.setTexture(eye.texture, index: 1)
        encoder.setTexture(mouth.texture, index: 2)
        encoder.setTexture(destination, index: 3)
        var uniforms = MindEyeProjectionCompositeUniforms(
            sourceAndOutputDimensions: SIMD4(1_728, 1_728, 1_440, 1_440),
            cropOrigin: SIMD2(144, 144)
        )
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<MindEyeProjectionCompositeUniforms>.stride,
            index: 0
        )
        let width = max(1, resources.pipeline.threadExecutionWidth)
        let height = max(1, resources.pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: 1_440, height: 1_440, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
        TuringMetalDiagnostics.setExternalInFlightCounts(
            appMetal: 1,
            mindEyeCompositor: 1
        )
        defer {
            TuringMetalDiagnostics.setExternalInFlightCounts(
                appMetal: 0,
                mindEyeCompositor: 0
            )
        }
        let completed = await withCheckedContinuation {
            (continuation: CheckedContinuation<Bool, Never>) in
            commandBuffer.addCompletedHandler { buffer in
                continuation.resume(returning: buffer.status == .completed)
            }
            commandBuffer.commit()
        }
        guard completed else {
            throw MindEyeProjectionError.renderFailed(
                "projection compositor command failed; last good frame retained"
            )
        }
        #if DEBUG
        if commandBuffer.gpuEndTime > commandBuffer.gpuStartTime,
           commandBuffer.gpuStartTime > 0 {
            let GPUms = (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000
            completedFrameCount &+= 1
            accumulatedGPUMilliseconds += GPUms
            if completedFrameCount <= 3 || completedFrameCount % 30 == 0 {
                let average = accumulatedGPUMilliseconds /
                    Double(completedFrameCount)
                print(
                    "[MindEyeProjectionPerf] frame=\(frame.sequence) " +
                        "gpuMS=\(String(format: "%.3f", GPUms)) " +
                        "averageGPUms=\(String(format: "%.3f", average)) " +
                        "compositor=directTexelRead"
                )
            }
        }
        #endif
    }
}
