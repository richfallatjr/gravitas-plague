import XCTest
import simd

@testable import Gravitas_Plague

final class MindEyePlacementResolverTests: XCTestCase {
    func testDefaultPlacementUsesBoundsCenterLiftAndFrontOffset() throws {
        let placement = try resolve(
            centering: bounds(min: [-1, 0, -0.2], max: [1, 2, 0.2])
        )
        assertEqual(placement.localPosition, [0, 1.10, 0.0381])
        XCTAssertFalse(placement.usedFallbackCenter)
    }

    func testShelfClampsCanApplyTogether() throws {
        let placement = try resolve(
            centering: bounds(min: [-0.5, 0, -0.2], max: [0.5, 0.2, 0.2]),
            obstruction: bounds(min: [-1, 0, -0.1], max: [1, 0.5, 0.4])
        )
        XCTAssertTrue(placement.verticalClampApplied)
        XCTAssertTrue(placement.forwardClampApplied)
        XCTAssertEqual(placement.localPosition.y, 0.74895, accuracy: 0.0001)
        XCTAssertEqual(placement.localPosition.z, 0.4127, accuracy: 0.0001)
    }

    func testInvalidBoundsUseFallbackCenter() throws {
        let placement = try resolve(
            centering: bounds(min: [1, 1, 1], max: [0, 0, 0]),
            fallback: [2, 3, 4]
        )
        XCTAssertTrue(placement.usedFallbackCenter)
        assertEqual(placement.localPosition, [2, 3.1, 4.0381])
    }

    func testIconRelativePlacementUsesBottomEdgeClearanceAndOwnDepth() throws {
        let placement = try MindEyePlacementResolver.resolve(
            geometry: geometry(
                iconRelativePlacement: MindEyeIconRelativePlacement(
                    iconTopCenter: [1, 2, 3],
                    bottomEdgeClearanceMeters: 0.0635,
                    forwardOffsetMeters: 0.1016
                )
            ),
            tuning: .phaseThreeDefault
        ).get()

        assertEqual(placement.localPosition, [1, 2.29975, 3.1016])
        XCTAssertFalse(placement.usedFallbackCenter)
        XCTAssertFalse(placement.verticalClampApplied)
        XCTAssertFalse(placement.forwardClampApplied)
    }

    func testIconRelativePlacementCentersHorizontallyOnProvidedBounds() throws {
        let placement = try MindEyePlacementResolver.resolve(
            geometry: geometry(
                centering: bounds(
                    min: [7, -4, -2],
                    max: [9, 6, 2]
                ),
                iconRelativePlacement: MindEyeIconRelativePlacement(
                    iconTopCenter: [1, 2, 3],
                    bottomEdgeClearanceMeters: 0.0508,
                    forwardOffsetMeters: 0.0381
                )
            ),
            tuning: .phaseThreeDefault
        ).get()

        // Shelf bounds own X. The icon still owns bottom-edge Y and depth Z.
        assertEqual(placement.localPosition, [8, 2.28705, 3.0381])
        XCTAssertFalse(placement.usedFallbackCenter)
    }

    func testRequestedIconOffsetsPreserveIndependentShelfAndBenchHeights() {
        XCTAssertEqual(
            MindEyeIconPlacementDefaults.shelfBottomEdgeClearanceMeters,
            0.0508,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MindEyeIconPlacementDefaults.shelfVisibleEdgeCorrectionMeters,
            -0.0762,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MindEyeIconPlacementDefaults.rollingBenchBottomEdgeClearanceMeters,
            0.0635,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MindEyeIconPlacementDefaults.walkieForwardOffsetMeters,
            0.0381,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            MindEyeIconPlacementDefaults.rollingBenchForwardOffsetMeters,
            0.1016,
            accuracy: 0.0001
        )
    }

    func testInvalidBoundsAndFallbackFail() {
        let result = MindEyePlacementResolver.resolve(
            geometry: geometry(
                centering: nil,
                fallback: [.nan, 0, 0]
            ),
            tuning: .phaseThreeDefault
        )
        guard case .failure(let failure) = result else {
            return XCTFail("Expected invalid placement failure")
        }
        XCTAssertEqual(failure.code, .placementInvalid)
    }

    func testNonfiniteTuningAndNonpositiveCardDimensionsFail() {
        for tuning in [
            MindEyePlacementTuning(
                cardWidthMeters: .nan,
                cardHeightMeters: 0.315,
                verticalLiftMeters: 0.10,
                forwardOffsetMeters: 0.0381,
                shelfClearanceMeters: 0.0127
            ),
            MindEyePlacementTuning(
                cardWidthMeters: 0,
                cardHeightMeters: 0.315,
                verticalLiftMeters: 0.10,
                forwardOffsetMeters: 0.0381,
                shelfClearanceMeters: 0.0127
            )
        ] {
            guard case .failure(let failure) = MindEyePlacementResolver.resolve(
                geometry: geometry(),
                tuning: tuning
            ) else {
                XCTFail("Expected invalid tuning failure")
                continue
            }
            XCTAssertEqual(failure.code, .placementInvalid)
        }
    }

    func testDefaultValuesAreLocked() {
        let tuning = MindEyePlacementTuning.phaseThreeDefault
        XCTAssertEqual(tuning.cardWidthMeters, 0.84, accuracy: 0.0001)
        XCTAssertEqual(tuning.cardHeightMeters, 0.4725, accuracy: 0.0001)
        XCTAssertEqual(tuning.verticalLiftMeters, 0.10, accuracy: 0.0001)
        XCTAssertEqual(tuning.forwardOffsetMeters, 0.0381, accuracy: 0.0001)
    }

    func testLargerIconRelativeCardKeepsItsBottomEdgeAnchored() throws {
        let iconTopY: Float = 0.8
        let clearance = MindEyeIconPlacementDefaults
            .rollingBenchBottomEdgeClearanceMeters
        let tuning = MindEyePlacementTuning.phaseThreeDefault
        let placement = try MindEyePlacementResolver.resolve(
            geometry: geometry(
                iconRelativePlacement: MindEyeIconRelativePlacement(
                    iconTopCenter: [0, iconTopY, 0],
                    bottomEdgeClearanceMeters: clearance,
                    forwardOffsetMeters: 0.1016
                )
            ),
            tuning: tuning
        ).get()

        let resolvedBottomEdge = placement.localPosition.y -
            tuning.cardHeightMeters * 0.5
        XCTAssertEqual(
            resolvedBottomEdge,
            iconTopY + clearance,
            accuracy: 0.0001
        )
    }

    private func resolve(
        centering: MindEyeLocalBounds?,
        obstruction: MindEyeLocalBounds? = nil,
        fallback: SIMD3<Float> = .zero
    ) throws -> MindEyeResolvedPlacement {
        try MindEyePlacementResolver.resolve(
            geometry: geometry(
                centering: centering,
                obstruction: obstruction,
                fallback: fallback
            ),
            tuning: .phaseThreeDefault
        ).get()
    }

    private func geometry(
        centering: MindEyeLocalBounds? = nil,
        obstruction: MindEyeLocalBounds? = nil,
        fallback: SIMD3<Float> = .zero,
        iconRelativePlacement: MindEyeIconRelativePlacement? = nil
    ) -> MindEyePlacementGeometry {
        MindEyePlacementGeometry(
            providerID: "test",
            revision: 7,
            centeringBounds: centering,
            obstructionBounds: obstruction,
            fallbackCenter: fallback,
            iconRelativePlacement: iconRelativePlacement
        )
    }

    private func bounds(
        min: SIMD3<Float>,
        max: SIMD3<Float>
    ) -> MindEyeLocalBounds {
        MindEyeLocalBounds(min: min, max: max)
    }

    private func assertEqual(
        _ value: SIMD3<Float>,
        _ expected: SIMD3<Float>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(value.x, expected.x, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(value.y, expected.y, accuracy: 0.0001, file: file, line: line)
        XCTAssertEqual(value.z, expected.z, accuracy: 0.0001, file: file, line: line)
    }
}
