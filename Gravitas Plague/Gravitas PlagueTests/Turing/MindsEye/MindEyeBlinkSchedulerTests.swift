import XCTest

@testable import Gravitas_Plague

final class MindEyeBlinkSchedulerTests: XCTestCase {
    func testMissingClosedVariantDisablesBlinking() {
        let tuning = makePhaseFiveTestTuning()
        var streams = MindEyeMotionRandomStreams(rootSeed: 1)
        var scheduler = MindEyeBlinkScheduler(
            tuning: tuning.blink,
            openVariantCount: 2,
            closedVariantCount: 0,
            streams: &streams
        )
        for _ in 0..<600 {
            scheduler.advance(
                deltaTime: 1 / 60,
                tuning: tuning.blink,
                openVariantCount: 2,
                closedVariantCount: 0,
                streams: &streams
            )
        }
        XCTAssertEqual(scheduler.blinkCount, 0)
        guard case .open = scheduler.eyeSelection else {
            return XCTFail("Blink-disabled scheduler must remain open")
        }
    }

    func testFixedSeedProducesDeterministicBlinkTrace() {
        let left = blinkTrace(seed: 55)
        let right = blinkTrace(seed: 55)
        XCTAssertEqual(left, right)
        XCTAssertGreaterThan(left.filter { $0.isClosed }.count, 0)
    }

    func testVariantSelectorAvoidsImmediateRepeat() {
        var random = MindEyeDeterministicRandom(seed: 2)
        for previous in 0..<4 {
            for _ in 0..<20 {
                XCTAssertNotEqual(
                    MindEyeVariantIndexSelector.select(
                        count: 4,
                        avoiding: previous,
                        random: &random
                    ),
                    previous
                )
            }
        }
        XCTAssertEqual(
            MindEyeVariantIndexSelector.select(
                count: 1,
                avoiding: 0,
                random: &random
            ),
            0
        )
    }

    private func blinkTrace(seed: UInt64) -> [EyeTraceValue] {
        let tuning = makePhaseFiveTestTuning()
        var streams = MindEyeMotionRandomStreams(rootSeed: seed)
        var scheduler = MindEyeBlinkScheduler(
            tuning: tuning.blink,
            openVariantCount: 3,
            closedVariantCount: 2,
            streams: &streams
        )
        return (0..<1_800).map { _ in
            scheduler.advance(
                deltaTime: 1 / 60,
                tuning: tuning.blink,
                openVariantCount: 3,
                closedVariantCount: 2,
                streams: &streams
            )
            switch scheduler.eyeSelection {
            case .open(let index): return EyeTraceValue(isClosed: false, index: index)
            case .closed(let index): return EyeTraceValue(isClosed: true, index: index)
            }
        }
    }
}

private struct EyeTraceValue: Equatable {
    let isClosed: Bool
    let index: Int
}
