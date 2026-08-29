import XCTest

@testable import Gravitas_Plague

@MainActor
final class MindEyeMotionFrameRegistryTests: XCTestCase {
    private final class Sink: MindEyeMotionFrameSink {
        var samples: [MindEyeMotionRenderSample] = []
        var failures: [MindEyeFailure] = []

        func receiveMindEyeMotionSample(_ sample: MindEyeMotionRenderSample) {
            samples.append(sample)
        }

        func receiveMindEyeMotionFailure(_ failure: MindEyeFailure) {
            failures.append(failure)
        }
    }

    func testPublishUsesExactTokenAndUnregisterStopsDelivery() {
        let registry = MindEyeMotionFrameRegistry.shared
        let sink = Sink()
        let token = UUID()
        _ = registry.register(sink, token: token)
        XCTAssertFalse(registry.publish(.resting, token: UUID()))
        XCTAssertTrue(registry.publish(.resting, token: token))
        XCTAssertEqual(sink.samples.count, 1)
        registry.unregister(token: token, reason: "test")
        XCTAssertFalse(registry.publish(.resting, token: token))
    }

    func testRegistryDoesNotRetainSink() {
        let registry = MindEyeMotionFrameRegistry.shared
        let token = UUID()
        weak var weakSink: Sink?
        do {
            let sink = Sink()
            weakSink = sink
            _ = registry.register(sink, token: token)
        }
        XCTAssertNil(weakSink)
        XCTAssertFalse(registry.publish(.resting, token: token))
    }
}
