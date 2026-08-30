import Foundation

public struct TuringQwenNativeLaneReleaseReceipt:
    Sendable,
    Equatable,
    Codable
{
    public let instanceID: String
    public let generation: TuringQwenNativeRecoveryGeneration
    public let mutableStateID: UUID?
    public let residentResourceID: UUID?
    public let weightStoreID: UUID?
    public let sharedOwnerID: UUID?
    public let engineReleased: Bool
    public let mutableStateReleased: Bool
    public let residencyReleased: Bool
    public let activeRenderCount: Int

    public var isComplete: Bool {
        engineReleased &&
            mutableStateReleased &&
            residencyReleased &&
            activeRenderCount == 0
    }
}

public struct TuringQwenNativeDecoderReleaseReceipt:
    Sendable,
    Equatable,
    Codable
{
    public let runID: String
    public let tokenID: UUID?
    public let generation: TuringQwenNativeRecoveryGeneration
    public let sessionReleased: Bool
    public let activeDecodeCount: Int
    public let activeStageCount: Int

    public var isComplete: Bool {
        sessionReleased && activeDecodeCount == 0 && activeStageCount == 0
    }

    public static func notStarted(
        runID: String,
        generation: TuringQwenNativeRecoveryGeneration
    ) -> Self {
        .init(
            runID: runID,
            tokenID: nil,
            generation: generation,
            sessionReleased: true,
            activeDecodeCount: 0,
            activeStageCount: 0
        )
    }
}

public struct TuringQwenNativeAdmissionReleaseReceipt:
    Sendable,
    Equatable,
    Codable
{
    public let generation: TuringQwenNativeRecoveryGeneration
    public let activeGenerationLeases: Int
    public let activeDecodeLeases: Int
    public let generationWaiters: Int
    public let decoderWaiters: Int

    public var isComplete: Bool {
        activeGenerationLeases == 0 &&
            activeDecodeLeases == 0 &&
            generationWaiters == 0 &&
            decoderWaiters == 0
    }

    public static func notStarted(
        generation: TuringQwenNativeRecoveryGeneration
    ) -> Self {
        .init(
            generation: generation,
            activeGenerationLeases: 0,
            activeDecodeLeases: 0,
            generationWaiters: 0,
            decoderWaiters: 0
        )
    }
}

public struct TuringQwenNativeSharedResidencyReleaseReceipt:
    Sendable,
    Equatable,
    Codable
{
    public let ownerID: UUID
    public let ownerGeneration: UInt64
    public let releasedLeaseCount: Int
    public let activeLeaseCountAfterRelease: Int
    public let ownerReleased: Bool

    public var isComplete: Bool {
        releasedLeaseCount == 2 &&
            activeLeaseCountAfterRelease == 0 &&
            ownerReleased
    }
}

public struct TuringQwenNativeRecoverySchedulerEvidence:
    Sendable,
    Equatable
{
    public let decoderReceipt: TuringQwenNativeDecoderReleaseReceipt
    public let admissionReceipt: TuringQwenNativeAdmissionReleaseReceipt
    public let queueCancelled: Bool
    public let releaseLedgerCleared: Bool
}

public struct TuringQwenNativeRecoveryReleaseReceipt:
    Sendable,
    Equatable,
    Codable
{
    public let sessionID: UUID
    public let runID: String
    public let generation: TuringQwenNativeRecoveryGeneration
    public let poolID: UUID
    public let laneReceipts: [TuringQwenNativeLaneReleaseReceipt]
    public let decoderReceipt: TuringQwenNativeDecoderReleaseReceipt
    public let admissionReceipt: TuringQwenNativeAdmissionReleaseReceipt
    public let sharedResidencyReceipt:
        TuringQwenNativeSharedResidencyReleaseReceipt?
    public let queueCancelled: Bool
    public let releaseLedgerCleared: Bool
    public let MLXActiveBytesAfterRelease: UInt64
    public let MLXCacheBytesAfterRelease: UInt64

    public var activeGenerationLeases: Int {
        admissionReceipt.activeGenerationLeases
    }

    public var activeDecodeLeases: Int {
        admissionReceipt.activeDecodeLeases
    }

    public var admissionWaiterCount: Int {
        admissionReceipt.generationWaiters + admissionReceipt.decoderWaiters
    }

    public var isComplete: Bool {
        laneReceipts.count == 2 &&
            laneReceipts.allSatisfy(\.isComplete) &&
            decoderReceipt.isComplete &&
            admissionReceipt.isComplete &&
            queueCancelled &&
            releaseLedgerCleared &&
            (sharedResidencyReceipt?.isComplete ?? true)
    }
}
