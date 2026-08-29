import XCTest

@testable import Gravitas_Plague

final class MindEyeDescriptorTests: XCTestCase {
    func testLockedDimensionsAndCenteredCrop() {
        XCTAssertEqual(.source, MindEyePixelSize(width: 2_304, height: 1_296))
        XCTAssertEqual(.viewport, MindEyePixelSize(width: 1_920, height: 1_080))
        XCTAssertEqual(
            .centeredViewport,
            MindEyePixelRect(
                origin: MindEyePixelPoint(x: 192, y: 108),
                size: .viewport
            )
        )
    }

    func testMouthPoseVocabularyIsStableAndRequiresTeeth() {
        XCTAssertEqual(
            MindEyeMouthPose.allCases,
            [.rest, .small, .wide, .round, .teeth]
        )
        XCTAssertEqual(
            MindEyeDescriptorConstants.requiredMouthPoses,
            Set(MindEyeMouthPose.allCases)
        )
        XCTAssertTrue(MindEyeDescriptorConstants.requiredMouthPoses.contains(.teeth))
    }

    func testPixelCountUsesCheckedMultiplication() {
        XCTAssertEqual(MindEyePixelSize.source.pixelCount, 2_985_984)
        XCTAssertNil(MindEyePixelSize(width: .max, height: 2).pixelCount)
        XCTAssertFalse(MindEyePixelSize(width: 0, height: 1).isPositive)
    }
}
