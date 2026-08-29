import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringPauseAwarePlaybackClockTests: XCTestCase {
    func testElapsedSubtractsAccumulatedPause() {
        let origin = ContinuousClock.now
        var clock = TuringPauseAwarePlaybackClock(origin: origin)

        clock.pause(at: origin.advanced(by: .seconds(2)))
        clock.resume(at: origin.advanced(by: .seconds(5)))

        XCTAssertEqual(
            clock.elapsed(at: origin.advanced(by: .seconds(10))),
            .seconds(7)
        )
    }

    func testElapsedFreezesWhilePaused() {
        let origin = ContinuousClock.now
        var clock = TuringPauseAwarePlaybackClock(origin: origin)
        clock.pause(at: origin.advanced(by: .seconds(3)))

        XCTAssertEqual(
            clock.elapsed(at: origin.advanced(by: .seconds(20))),
            .seconds(3)
        )
    }

    func testDuplicatePauseAndResumeAreIdempotent() {
        let origin = ContinuousClock.now
        var clock = TuringPauseAwarePlaybackClock(origin: origin)
        clock.pause(at: origin.advanced(by: .seconds(2)))
        clock.pause(at: origin.advanced(by: .seconds(3)))
        clock.resume(at: origin.advanced(by: .seconds(5)))
        clock.resume(at: origin.advanced(by: .seconds(8)))

        XCTAssertEqual(clock.accumulatedPausedDuration, .seconds(3))
    }

    func testElapsedClampsBeforeOriginToZero() {
        let origin = ContinuousClock.now
        let clock = TuringPauseAwarePlaybackClock(origin: origin)

        XCTAssertEqual(
            clock.elapsed(at: origin.advanced(by: .seconds(-1))),
            .zero
        )
    }
}
