import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredFrameTrackTests: XCTestCase {
    func testCompactedRunsCoverBitsAndPreserveTeeth() throws {
        let track = try MindEyePhase8TestFixtures.track()
        XCTAssertEqual(track.compactPoseByteCount, track.descriptor.frameCount)
        XCTAssertEqual(track.poseRuns.first?.startFrame, 0)
        XCTAssertEqual(track.poseRuns.last?.endFrameExclusive, track.descriptor.frameCount)
        XCTAssertEqual(track.pose(atFrame: 3), .teeth)
        XCTAssertEqual(track.runIndex(containingFrame: 0), 0)
        XCTAssertEqual(track.runIndex(containingFrame: 5), track.poseRuns.count - 1)
    }

    func testUnknownBitAndRunGapReject() throws {
        let descriptor = try MindEyePhase8TestFixtures.track().descriptor
        XCTAssertThrowsError(try MindEyeAuthoredFrameTrack(
            descriptor: descriptor,
            poseBits: [1, 2, 2, 16, 4, 32],
            poseRuns: [.init(startFrame: 0, endFrameExclusive: 6, pose: .rest)]
        ))
        XCTAssertThrowsError(try MindEyeAuthoredFrameTrack(
            descriptor: descriptor,
            poseBits: [1, 2, 2, 16, 4, 8],
            poseRuns: [
                .init(startFrame: 0, endFrameExclusive: 1, pose: .rest),
                .init(startFrame: 2, endFrameExclusive: 6, pose: .small)
            ]
        ))
    }
}
