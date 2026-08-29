import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredFrameClockMapperTests: XCTestCase {
    func testExactIntegerFrameBoundariesAndPastEnd() throws {
        let track = try MindEyePhase8TestFixtures.track()
        XCTAssertEqual(position(.zero, track), .frame(index: 0))
        XCTAssertEqual(position(.nanoseconds(1), track), .frame(index: 0))
        XCTAssertEqual(position(.nanoseconds(16_666_666), track), .frame(index: 0))
        XCTAssertEqual(position(.nanoseconds(16_666_667), track), .frame(index: 1))
        XCTAssertEqual(position(.nanoseconds(33_333_334), track), .frame(index: 2))
        XCTAssertEqual(position(.nanoseconds(99_999_999), track), .frame(index: 5))
        XCTAssertEqual(position(.nanoseconds(100_000_000), track), .pastEnd)
    }

    func testPauseAwareClockFreezesAndResumes() throws {
        let track = try MindEyePhase8TestFixtures.track()
        let origin = ContinuousClock.now
        var clock = TuringPauseAwarePlaybackClock(origin: origin)
        clock.pause(at: origin.advanced(by: .nanoseconds(33_333_334)))
        XCTAssertEqual(
            try MindEyeAuthoredFrameClockMapper.position(
                clock: clock,
                at: origin.advanced(by: .seconds(2)),
                track: track
            ).get(),
            .frame(index: 2)
        )
        clock.resume(at: origin.advanced(by: .seconds(1)))
        XCTAssertEqual(
            try MindEyeAuthoredFrameClockMapper.position(
                clock: clock,
                at: origin.advanced(by: .seconds(1) + .nanoseconds(50_000_001)),
                track: track
            ).get(),
            .frame(index: 5)
        )
    }

    private func position(
        _ elapsed: Duration,
        _ track: MindEyeAuthoredFrameTrack
    ) -> MindEyeAuthoredFramePosition {
        try! MindEyeAuthoredFrameClockMapper.position(elapsed: elapsed, track: track).get()
    }
}
