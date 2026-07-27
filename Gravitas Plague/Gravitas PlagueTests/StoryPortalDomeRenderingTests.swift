import XCTest

@testable import Gravitas_Plague

final class StoryPortalDomeRenderingTests: XCTestCase {
    func testAuthoredStoryPlacementIsTwelveMetersAtNegativeNine() {
        XCTAssertEqual(
            PortalHDRIDomePlacement.storyOpening.radiusMeters,
            12,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PortalHDRIDomePlacement.storyOpening.centerOffsetZ,
            -9,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PortalHDRIDomePlacement.storyOpening.nearestShellDistanceMeters,
            3,
            accuracy: 0.0001
        )
    }

    func testStoryOrientationUsesNativeUVAndLegacyIsIsolated() {
        XCTAssertEqual(
            PortalHDRIPanoramaOrientation.story.horizontalUVMode,
            .native
        )
        XCTAssertEqual(
            PortalHDRIDomeSurfaceContract.storyInteriorOnly
                .expectedFaceCullingLabel,
            "front"
        )
        XCTAssertEqual(
            PortalHDRIDomeSurfaceContract.legacyPreserveCurrentBehavior
                .expectedFaceCullingLabel,
            "back_with_negative_x_scale"
        )
    }
}
