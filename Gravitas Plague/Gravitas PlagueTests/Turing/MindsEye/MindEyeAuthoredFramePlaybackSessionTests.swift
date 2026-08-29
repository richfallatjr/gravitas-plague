import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredFramePlaybackSessionTests: XCTestCase {
    func testSessionEmitsOnlyRunChangesAndTailRestOnce() throws {
        let track = try MindEyePhase8TestFixtures.track()
        let origin = ContinuousClock.now
        var session = MindEyeAuthoredFramePlaybackSession(
            presentationKey: MindEyePhase8TestFixtures.key,
            track: track,
            clock: .init(origin: origin),
            variantPlan: try MindEyeAuthoredMouthVariantPlanBuilder.build(
                track: track,
                counts: .init(rest: 2, small: 2, wide: 2, round: 2, teeth: 2),
                rootSeed: 31
            ).get()
        )
        XCTAssertNotNil(try session.sample(at: origin).get())
        XCTAssertNil(try session.sample(at: origin.advanced(by: .milliseconds(1))).get())
        XCTAssertNotNil(try session.sample(at: origin.advanced(by: .milliseconds(20))).get())
        let end = origin.advanced(by: .milliseconds(100))
        XCTAssertEqual((try session.sample(at: end).get())?.selection.pose, .rest)
        XCTAssertNil(try session.sample(at: end.advanced(by: .seconds(1))).get())
    }
}
