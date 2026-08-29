import XCTest

@testable import Gravitas_Plague

@MainActor
final class MindEyeAuthoredFramePlaybackRegistryTests: XCTestCase {
    private final class Sink: MindEyeAuthoredMouthPlaybackSink {
        var updates: [MindEyeAuthoredMouthUpdate] = []
        var failures: [MindEyeFailure] = []
        func receiveMindEyeAuthoredMouthUpdate(_ update: MindEyeAuthoredMouthUpdate) {
            updates.append(update)
        }
        func receiveMindEyeAuthoredMouthFailure(_ failure: MindEyeFailure) {
            failures.append(failure)
        }
    }

    func testRegisterPauseResumeAndUnregister() throws {
        let registry = MindEyeAuthoredFramePlaybackRegistry.shared
        registry.removeAll(reason: "testStart")
        let track = try MindEyePhase8TestFixtures.track()
        let origin = ContinuousClock.now
        let sink = Sink()
        let registration = try registry.register(
            sink: sink,
            context: .init(
                presentationKey: MindEyePhase8TestFixtures.key,
                track: track,
                clock: .init(origin: origin),
                rootSeed: 22,
                explicitTestSeed: 22
            ),
            counts: .init(rest: 2, small: 2, wide: 2, round: 2, teeth: 2),
            now: origin
        ).get()
        XCTAssertEqual(registry.entryCount, 1)
        XCTAssertEqual(
            registry.updateClock(
                token: registration.token,
                clock: .init(origin: origin),
                isPaused: true
            ),
            .unchanged
        )
        XCTAssertEqual(
            registry.advance(token: registration.token, now: origin.advanced(by: .seconds(1))),
            .unchanged
        )
        registry.unregister(token: registration.token, reason: "test")
        XCTAssertEqual(registry.entryCount, 0)
    }
}
