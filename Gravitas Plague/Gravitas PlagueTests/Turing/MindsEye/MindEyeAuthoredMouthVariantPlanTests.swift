import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredMouthVariantPlanTests: XCTestCase {
    func testPlanIsDeterministicBoundedAndOneChoicePerRun() throws {
        let track = try MindEyePhase8TestFixtures.track(
            poses: [.rest, .small, .rest, .small, .teeth, .rest]
        )
        let counts = MindEyeMouthVariantCounts(
            rest: 2, small: 2, wide: 1, round: 1, teeth: 2
        )
        let first = try MindEyeAuthoredMouthVariantPlanBuilder.build(
            track: track, counts: counts, rootSeed: 77
        ).get()
        let second = try MindEyeAuthoredMouthVariantPlanBuilder.build(
            track: track, counts: counts, rootSeed: 77
        ).get()
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.variantIndexByRun.count, track.poseRuns.count)
        for index in track.poseRuns.indices {
            let selection = try XCTUnwrap(first.selection(forRun: index, track: track))
            XCTAssertTrue((0..<counts.count(for: selection.pose)).contains(selection.variantIndex))
        }
        let restSelections = track.poseRuns.indices.compactMap { index -> Int? in
            guard track.poseRuns[index].pose == .rest else { return nil }
            return first.variantIndexByRun[index]
        }
        XCTAssertTrue(
            zip(restSelections, restSelections.dropFirst()).allSatisfy {
                $0.0 != $0.1
            }
        )
    }

    func testSingleVariantsAlwaysUseZero() throws {
        let track = try MindEyePhase8TestFixtures.track()
        let plan = try MindEyeAuthoredMouthVariantPlanBuilder.build(
            track: track,
            counts: .init(rest: 1, small: 1, wide: 1, round: 1, teeth: 1),
            rootSeed: 9
        ).get()
        XCTAssertTrue(plan.variantIndexByRun.allSatisfy { $0 == 0 })
        XCTAssertEqual(plan.tailRestVariantIndex, 0)
    }
}
