import XCTest
@testable import Gravitas_Plague

final class StoryAmbientAircraftTests: XCTestCase {
    func testProductionCatalogUsesAuthoredOverheadPolicy() throws {
        let catalog = try StoryAmbientAircraftCatalogStore().catalog

        XCTAssertEqual(catalog.minimumGapSeconds, 10)
        XCTAssertEqual(catalog.maximumGapSeconds, 30)
        XCTAssertEqual(catalog.minimumHeightFeet, 10)
        XCTAssertEqual(catalog.maximumHeightFeet, 15)
        XCTAssertEqual(catalog.sourceGainDB, 0)
        XCTAssertEqual(catalog.distanceRolloffFactor, 0)
        XCTAssertEqual(catalog.maximumActiveVoices, 1)
        XCTAssertEqual(
            Set(catalog.assets.map(\.fileName)),
            [
                "helicopter-overhead-02.wav",
                "helicopter-overhead-03.wav",
                "jet-overhead-02.wav"
            ]
        )
    }

    func testSamplerAnchorsOnlyAboveWorldOrigin() throws {
        let catalog = try StoryAmbientAircraftCatalogStore().catalog

        XCTAssertEqual(
            StoryAmbientAircraftSampler.gapSeconds(
                catalog: catalog,
                unit: 0
            ),
            10
        )
        XCTAssertEqual(
            StoryAmbientAircraftSampler.gapSeconds(
                catalog: catalog,
                unit: 1
            ),
            30,
            accuracy: 0.000_001
        )

        let low = StoryAmbientAircraftSampler.worldPosition(
            heightFeet: StoryAmbientAircraftSampler.heightFeet(
                catalog: catalog,
                unit: 0
            )
        )
        let high = StoryAmbientAircraftSampler.worldPosition(
            heightFeet: StoryAmbientAircraftSampler.heightFeet(
                catalog: catalog,
                unit: 1
            )
        )

        XCTAssertEqual(low.x, 0)
        XCTAssertEqual(low.z, 0)
        XCTAssertEqual(low.y, 3.048, accuracy: 0.000_001)
        XCTAssertEqual(high.x, 0)
        XCTAssertEqual(high.z, 0)
        XCTAssertEqual(high.y, 4.572, accuracy: 0.000_001)
    }

    func testTerminalAngelSequenceLatchNeverResumes() {
        var state = StoryAmbientAircraftLifecycleState()

        state.storyPropsDidCommit()
        XCTAssertTrue(state.shouldRun)

        state.setTitleCardActive(true)
        XCTAssertFalse(state.shouldRun)
        state.setTitleCardActive(false)
        XCTAssertTrue(state.shouldRun)

        state.beginTerminalAngelSequence()
        XCTAssertFalse(state.shouldRun)
        state.storyPropsDidCommit()
        XCTAssertFalse(state.shouldRun)
    }
}
