import XCTest

@testable import Gravitas_Plague

final class HordePortalBlendShapeWeightGroupParityTests: XCTestCase {
    func testMatchingGroupNamesAndWeightShapesPass() {
        let mismatch = HordePortalBlendShapeWeightGroupParity.mismatch(
            sourceNames: [["jawClose", "blink"], ["brow"]],
            sourceWeights: [[0.75, 0.1], [0.25]],
            mirrorNames: [["jawClose", "blink"], ["brow"]],
            mirrorWeights: [[0, 0], [0]]
        )

        XCTAssertNil(mismatch)
    }

    func testReorderedWeightNamesFailStrictParity() {
        let mismatch = HordePortalBlendShapeWeightGroupParity.mismatch(
            sourceNames: [["jawClose", "blink"]],
            sourceWeights: [[0.75, 0.1]],
            mirrorNames: [["blink", "jawClose"]],
            mirrorWeights: [[0, 0]]
        )

        XCTAssertEqual(mismatch, .weightNames(groupIndex: 0))
    }

    func testMalformedSourceGroupFailsBeforeCopy() {
        let mismatch = HordePortalBlendShapeWeightGroupParity.mismatch(
            sourceNames: [["jawClose"]],
            sourceWeights: [[0.75, 0.1]],
            mirrorNames: [["jawClose"]],
            mirrorWeights: [[0]]
        )

        XCTAssertEqual(
            mismatch,
            .sourceGroupShape(groupIndex: 0, names: 1, weights: 2)
        )
    }

    func testMirrorGroupCountMismatchFailsBeforeCopy() {
        let mismatch = HordePortalBlendShapeWeightGroupParity.mismatch(
            sourceNames: [["jawClose"]],
            sourceWeights: [[0.75]],
            mirrorNames: [],
            mirrorWeights: []
        )

        XCTAssertEqual(mismatch, .groupCount(source: 1, mirror: 0))
    }
}
