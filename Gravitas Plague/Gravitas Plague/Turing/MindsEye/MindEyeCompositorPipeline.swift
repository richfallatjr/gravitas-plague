import Foundation
import MLX
import Metal
import RealityKit

nonisolated final class MindEyeCompositorMetalResources: @unchecked Sendable {
    let commandQueue: any MTLCommandQueue
    let computePipeline: any MTLComputePipelineState

    init(
        commandQueue: any MTLCommandQueue,
        computePipeline: any MTLComputePipelineState
    ) {
        self.commandQueue = commandQueue
        self.computePipeline = computePipeline
    }
}

actor MindEyeCompositorPipeline {
    private let device: any MTLDevice
    private let compileQueue: DispatchQueue
    private var cached: Result<MindEyeCompositorMetalResources, MindEyeFailure>?

    init(
        device: any MTLDevice,
        compileQueueLabel: String =
            "com.gravitas.plague.mindseye.compositor-pipeline"
    ) {
        self.device = device
        compileQueue = DispatchQueue(label: compileQueueLabel, qos: .userInitiated)
    }

    func resources() async -> Result<MindEyeCompositorMetalResources, MindEyeFailure> {
        if let cached { return cached }
        let result: Result<MindEyeCompositorMetalResources, MindEyeFailure> =
            await withCheckedContinuation { continuation in
                compileQueue.async { [device] in
                    dispatchPrecondition(condition: .notOnQueue(.main))
                    precondition(Thread.isMainThread == false)
                    let value: Result<MindEyeCompositorMetalResources, MindEyeFailure> =
                        autoreleasepool {
                            guard let library = device.makeDefaultLibrary(),
                                  let function = library.makeFunction(
                                    name: "mindEyeCompositeFrame"
                                  ),
                                  let queue = device.makeCommandQueue() else {
                                return .failure(MindEyeFailure(
                                    code: .dynamicCompositorUnavailable,
                                    characterID: nil,
                                    vignetteID: nil,
                                    resourcePath: nil,
                                    message: "Mind's Eye dynamic Metal resources are unavailable."
                                ))
                            }
                            do {
                                let pipeline = try device.makeComputePipelineState(
                                    function: function
                                )
                                queue.label = "MindEyeCompositorCommandQueue"
                                return .success(MindEyeCompositorMetalResources(
                                    commandQueue: queue,
                                    computePipeline: pipeline
                                ))
                            } catch {
                                return .failure(MindEyeFailure(
                                    code: .dynamicCompositorUnavailable,
                                    characterID: nil,
                                    vignetteID: nil,
                                    resourcePath: nil,
                                    message: "Mind's Eye pipeline compilation failed: \(error.localizedDescription)"
                                ))
                            }
                        }
                    continuation.resume(returning: value)
                }
            }
        cached = result
        return result
    }
}

@MainActor
enum MindEyeCompositeEncoder {
    static func encodeAndCommit(
        package: MindEyeAssetPackage,
        frame requestedFrame: MindEyeCompositeFrameState,
        surface: MindEyeDynamicOutputSurface,
        resources: MindEyeCompositorMetalResources,
        awaitCompletion: Bool,
        canvasProfile: MindEyeCompositorCanvasProfile = .landscapePortraitCard
    ) async -> Result<MindEyeCompositeFrameReceipt, MindEyeFailure> {
        if let failure = MindEyeCompositeFrameStateValidator.validateBasic(requestedFrame) {
            return .failure(failure)
        }
        let background: MindEyeSanitizedLayerTransform
        let character: MindEyeSanitizedLayerTransform
        do {
            background = try MindEyeLayerTransformSanitizer
                .sanitize(requestedFrame.backgroundTransform).get()
            character = try MindEyeLayerTransformSanitizer
                .sanitize(requestedFrame.characterTransform).get()
        } catch let failure as MindEyeFailure {
            return .failure(failure)
        } catch {
            return .failure(failure(package, error.localizedDescription))
        }
        let frame = MindEyeCompositeFrameState(
            sequence: requestedFrame.sequence,
            backgroundTransform: background.value,
            characterTransform: character.value,
            eyeSelection: requestedFrame.eyeSelection,
            mouthSelection: requestedFrame.mouthSelection,
            maskMode: requestedFrame.maskMode
        )
        let layers: MindEyeResolvedCompositeLayers
        switch MindEyeCompositeLayerResolver.resolve(package: package, frame: frame) {
        case .failure(let failure): return .failure(failure)
        case .success(let value): layers = value
        }
        guard validatesFormats(layers: layers),
              surface.lowLevelTexture.descriptor.pixelFormat == .bgra8Unorm_srgb,
              surface.lowLevelTexture.descriptor.width == Int(canvasProfile.outputDimensions.x),
              surface.lowLevelTexture.descriptor.height == Int(canvasProfile.outputDimensions.y) else {
            return .failure(failure(package, "Composite texture formats are invalid."))
        }

        let encodeStart = DispatchTime.now().uptimeNanoseconds
        guard let commandBuffer = resources.commandQueue.makeCommandBuffer() else {
            return .failure(failure(package, "Could not create a command buffer."))
        }
        commandBuffer.label = "MindEyeComposite.\(package.vignetteID).\(frame.sequence)"
        let output = surface.lowLevelTexture.replace(using: commandBuffer)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return .failure(failure(package, "Could not create a compute encoder."))
        }
        encoder.label = "MindEyeCompositeEncoder"
        encoder.setComputePipelineState(resources.computePipeline)
        encoder.setTexture(layers.background, index: 0)
        encoder.setTexture(layers.characterBase, index: 1)
        encoder.setTexture(layers.selectedEyes, index: 2)
        encoder.setTexture(layers.selectedMouth, index: 3)
        encoder.setTexture(layers.featherMask, index: 4)
        encoder.setTexture(output, index: 5)
        var uniforms = MindEyeCompositeUniforms.make(
            frame: frame,
            canvasProfile: canvasProfile
        )
        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<MindEyeCompositeUniforms>.stride,
            index: 0
        )
        let width = max(1, resources.computePipeline.threadExecutionWidth)
        let height = max(
            1,
            resources.computePipeline.maxTotalThreadsPerThreadgroup / width
        )
        encoder.dispatchThreads(
            MTLSize(
                width: Int(canvasProfile.outputDimensions.x),
                height: Int(canvasProfile.outputDimensions.y),
                depth: 1
            ),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
        let cpuNanoseconds = DispatchTime.now().uptimeNanoseconds - encodeStart

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
            commandBuffer.addCompletedHandler { completedBuffer in
                continuation.resume(returning: completedBuffer.status == .completed)
            }
            commandBuffer.commit()
        }
        guard completed else {
            return .failure(failure(package, "Dynamic GPU composite command failed."))
        }
        let gpuNanoseconds: UInt64?
        if commandBuffer.gpuEndTime > commandBuffer.gpuStartTime,
           commandBuffer.gpuStartTime > 0 {
            gpuNanoseconds = UInt64(
                (commandBuffer.gpuEndTime - commandBuffer.gpuStartTime) * 1_000_000_000
            )
        } else {
            gpuNanoseconds = nil
        }
        let receipt = MindEyeCompositeFrameReceipt(
            requestedSequence: requestedFrame.sequence,
            completedSequence: frame.sequence,
            wasCropClamped: background.wasClamped || character.wasClamped,
            cpuEncodeNanoseconds: cpuNanoseconds,
            gpuExecutionNanoseconds: gpuNanoseconds
        )
        #if GR_MIND_EYE_QUALIFICATION
        MindEyeReleaseQualificationHooks.shared.recordCompositor(receipt)
        #endif
        return .success(receipt)
    }

    private static func validatesFormats(
        layers: MindEyeResolvedCompositeLayers
    ) -> Bool {
        let colorFormats: Set<MTLPixelFormat> = [
            .rgba8Unorm_srgb,
            .bgra8Unorm_srgb,
            .rgba16Float
        ]
        let colors = [
            layers.background,
            layers.characterBase,
            layers.selectedEyes,
            layers.selectedMouth
        ]
        let maskFormats: Set<MTLPixelFormat> = [
            .r8Unorm,
            .rg8Unorm,
            .rgba8Unorm,
            .bgra8Unorm,
            .rgba16Float
        ]
        return colors.allSatisfy { colorFormats.contains($0.pixelFormat) } &&
            maskFormats.contains(layers.featherMask.pixelFormat)
    }

    private static func failure(
        _ package: MindEyeAssetPackage,
        _ message: String
    ) -> MindEyeFailure {
        MindEyeFailure(
            code: .dynamicCompositeFailed,
            characterID: package.characterID,
            vignetteID: package.vignetteID,
            resourcePath: nil,
            message: message
        )
    }
}
