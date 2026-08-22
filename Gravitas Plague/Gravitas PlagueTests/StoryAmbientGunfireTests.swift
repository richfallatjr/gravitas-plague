import XCTest
@testable import Gravitas_Plague

final class StoryAmbientGunfireTests: XCTestCase {
    func testProductionCatalogUsesRequestedFastTestPolicy() throws {
        let catalog = try StoryAmbientGunfireCatalogStore().catalog

        XCTAssertEqual(catalog.minimumGapSeconds, 5)
        XCTAssertEqual(catalog.maximumGapSeconds, 15)
        XCTAssertEqual(catalog.dryMinimumDistanceFeet, 50)
        XCTAssertEqual(catalog.dryMaximumDistanceFeet, 150)
        XCTAssertEqual(catalog.distantFixedDistanceFeet, 50)
        XCTAssertEqual(catalog.maximumActiveVoices, 1)
        XCTAssertEqual(catalog.assets.count, 26)
        XCTAssertTrue(
            catalog.assets.allSatisfy { $0.sourceGainDB == 0 }
        )
        XCTAssertTrue(
            catalog.assets
                .filter { $0.assetClass == .dryGunfire }
                .allSatisfy { $0.distanceRolloffFactor == 1 }
        )
        XCTAssertTrue(
            catalog.assets
                .filter { $0.assetClass == .distantAuthored }
                .allSatisfy { $0.distanceRolloffFactor == 0 }
        )
    }

    func testSamplerRespectsCadenceAndClassDistanceBounds() throws {
        let catalog = try StoryAmbientGunfireCatalogStore().catalog

        XCTAssertEqual(
            StoryAmbientGunfireSpatialSampler.gapSeconds(
                catalog: catalog,
                unit: 0
            ),
            5
        )
        XCTAssertEqual(
            StoryAmbientGunfireSpatialSampler.gapSeconds(
                catalog: catalog,
                unit: 1
            ),
            15,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            StoryAmbientGunfireSpatialSampler.radiusFeet(
                assetClass: .dryGunfire,
                catalog: catalog,
                unit: 0
            ),
            50,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            StoryAmbientGunfireSpatialSampler.radiusFeet(
                assetClass: .dryGunfire,
                catalog: catalog,
                unit: 1
            ),
            150,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            StoryAmbientGunfireSpatialSampler.radiusFeet(
                assetClass: .distantAuthored,
                catalog: catalog,
                unit: 0.9
            ),
            50
        )
    }

    func testTerminalAngelSequenceLatchNeverResumes() {
        var state = StoryAmbientGunfireLifecycleState()

        state.storyPropsDidCommit()
        XCTAssertTrue(state.shouldRun)

        state.setTitleCardActive(true)
        XCTAssertFalse(state.shouldRun)
        state.setTitleCardActive(false)
        XCTAssertTrue(state.shouldRun)

        state.deactivate(.operationModeTeardown)
        XCTAssertFalse(state.shouldRun)
        state.storyPropsDidCommit()
        XCTAssertTrue(state.shouldRun)

        state.beginTerminalAngelSequence()
        XCTAssertFalse(state.shouldRun)

        state.storyPropsDidCommit()
        state.setTitleCardActive(false)
        XCTAssertFalse(state.shouldRun)
        XCTAssertTrue(state.terminalAngelSequenceBegan)
    }
}
