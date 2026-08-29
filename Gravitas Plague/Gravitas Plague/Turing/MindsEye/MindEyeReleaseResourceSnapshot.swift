import Foundation

nonisolated struct MindEyeVisualResourceSnapshot: Sendable, Equatable {
    let outputTextureCount: Int
    let outputTextureAllocatedBytes: UInt64
    let activeCardCount: Int
    let orphanCardCount: Int
    let compositorInFlightCount: Int
    let compositorPendingFrameCount: Int
    let cropClampCount: UInt64
    let coalescedFrameCount: UInt64
    let authoredCompactFrameBytes: Int
    let generatedCompactFrameBytes: Int

    static let empty = MindEyeVisualResourceSnapshot(
        outputTextureCount: 0,
        outputTextureAllocatedBytes: 0,
        activeCardCount: 0,
        orphanCardCount: 0,
        compositorInFlightCount: 0,
        compositorPendingFrameCount: 0,
        cropClampCount: 0,
        coalescedFrameCount: 0,
        authoredCompactFrameBytes: 0,
        generatedCompactFrameBytes: 0
    )
}

nonisolated struct MindEyeReleaseResourceSnapshot:
    Sendable, Codable, Equatable
{
    let process: TuringMemoryBudgetSnapshot
    let vignetteID: String?
    let sourceTextureCount: Int
    let sourceTextureAllocatedBytes: UInt64
    let outputTextureCount: Int
    let outputTextureAllocatedBytes: UInt64
    let activeAssetPackageCount: Int
    let inactiveAssetPackageCount: Int
    let cachedAuthoredTrackCount: Int
    let activeAuthoredTrackLeaseCount: Int
    let motionRegistryCount: Int
    let authoredRegistryCount: Int
    let generatedRegistryCount: Int
    let activeCardCount: Int
    let orphanCardCount: Int
    let compositorInFlightCount: Int
    let compositorPendingFrameCount: Int
    let cropClampCount: UInt64
    let coalescedFrameCount: UInt64
    let authoredCompactFrameBytes: Int
    let generatedCompactFrameBytes: Int

    var hasReleasedRuntimeOwnership: Bool {
        activeAssetPackageCount == 0 &&
            activeAuthoredTrackLeaseCount == 0 &&
            motionRegistryCount == 0 &&
            authoredRegistryCount == 0 &&
            generatedRegistryCount == 0 &&
            activeCardCount == 0 &&
            orphanCardCount == 0
    }

    var containsOnlyNonnegativeCounts: Bool {
        [
            sourceTextureCount,
            outputTextureCount,
            activeAssetPackageCount,
            inactiveAssetPackageCount,
            cachedAuthoredTrackCount,
            activeAuthoredTrackLeaseCount,
            motionRegistryCount,
            authoredRegistryCount,
            generatedRegistryCount,
            activeCardCount,
            orphanCardCount,
            compositorInFlightCount,
            compositorPendingFrameCount,
            authoredCompactFrameBytes,
            generatedCompactFrameBytes
        ].allSatisfy { $0 >= 0 }
    }

    @MainActor
    static func empty() -> Self {
        empty(process: TuringMemoryBudgetProbe.snapshot())
    }

    static func empty(process: TuringMemoryBudgetSnapshot) -> Self {
        Self(
            process: process,
            vignetteID: nil,
            sourceTextureCount: 0,
            sourceTextureAllocatedBytes: 0,
            outputTextureCount: 0,
            outputTextureAllocatedBytes: 0,
            activeAssetPackageCount: 0,
            inactiveAssetPackageCount: 0,
            cachedAuthoredTrackCount: 0,
            activeAuthoredTrackLeaseCount: 0,
            motionRegistryCount: 0,
            authoredRegistryCount: 0,
            generatedRegistryCount: 0,
            activeCardCount: 0,
            orphanCardCount: 0,
            compositorInFlightCount: 0,
            compositorPendingFrameCount: 0,
            cropClampCount: 0,
            coalescedFrameCount: 0,
            authoredCompactFrameBytes: 0,
            generatedCompactFrameBytes: 0
        )
    }
}
