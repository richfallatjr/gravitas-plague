import Foundation

nonisolated struct MindEyeVisualDescriptor: Sendable, Equatable {
    let characterID: TuringConversationCharacterID
    let vignetteID: String
    let placementTuning: MindEyePlacementTuning
    let outputSize: MindEyePixelSize
}

nonisolated struct MindEyeCompositeFrameReceipt: Sendable, Equatable {
    let requestedSequence: UInt64
    let completedSequence: UInt64
    let wasCropClamped: Bool
    let cpuEncodeNanoseconds: UInt64
    let gpuExecutionNanoseconds: UInt64?
}

@MainActor
protocol MindEyePresentationVisual:
    AnyObject,
    MindEyeVisualSuspensionControlling
{
    var descriptor: MindEyeVisualDescriptor { get }
    var isAttached: Bool { get }
    var lastCompletedSequence: UInt64? { get }

    func attach(
        to target: MindEyePlacementTarget,
        placement: MindEyeResolvedPlacement
    ) -> Result<Void, MindEyeFailure>

    func renderInitialFrame(
        _ frame: MindEyeCompositeFrameState
    ) async -> Result<MindEyeCompositeFrameReceipt, MindEyeFailure>

    func enqueueFrame(_ frame: MindEyeCompositeFrameState)
    func setFrameUpdatesPaused(_ paused: Bool, reason: String)
    func startKeepAlive(
        context: MindEyeKeepAliveContext
    ) -> Result<Void, MindEyeFailure>
    func stopKeepAlive(reason: String)
    func releaseResourceSnapshot() -> MindEyeVisualResourceSnapshot
    func detach(reason: String)
    func dispose(reason: String)
}

@MainActor
protocol MindEyePresentationVisualBuilding: AnyObject {
    func build(
        package: MindEyeAssetPackage
    ) async -> Result<any MindEyePresentationVisual, MindEyeFailure>
}
