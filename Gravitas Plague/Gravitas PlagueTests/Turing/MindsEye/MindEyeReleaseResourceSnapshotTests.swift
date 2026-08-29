import XCTest

@testable import Gravitas_Plague

final class MindEyeReleaseResourceSnapshotTests: XCTestCase {
    func testEmptySnapshotHasNonnegativeCountsAndReleasedOwnership() {
        let snapshot = MindEyePhase11TestFixture.resource()
        let counts = [
            snapshot.sourceTextureCount,
            snapshot.outputTextureCount,
            snapshot.activeAssetPackageCount,
            snapshot.inactiveAssetPackageCount,
            snapshot.cachedAuthoredTrackCount,
            snapshot.activeAuthoredTrackLeaseCount,
            snapshot.motionRegistryCount,
            snapshot.authoredRegistryCount,
            snapshot.generatedRegistryCount,
            snapshot.activeCardCount,
            snapshot.orphanCardCount,
            snapshot.compositorInFlightCount,
            snapshot.compositorPendingFrameCount
        ]
        XCTAssertTrue(counts.allSatisfy { $0 >= 0 })
        XCTAssertTrue(snapshot.hasReleasedRuntimeOwnership)
    }
}
