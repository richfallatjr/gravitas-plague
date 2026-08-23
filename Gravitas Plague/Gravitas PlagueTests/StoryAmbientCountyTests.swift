import XCTest
@testable import Gravitas_Plague

final class StoryAmbientCountyTests: XCTestCase {
    func testProductionCatalogUsesCountyDistantPolicy() throws {
        let catalog = try StoryAmbientCountyCatalogStore().catalog

        XCTAssertEqual(catalog.minimumGapSeconds, 5)
        XCTAssertEqual(catalog.maximumGapSeconds, 15)
        XCTAssertEqual(catalog.distantFixedDistanceFeet, 50)
        XCTAssertEqual(catalog.maximumActiveVoices, 1)
        XCTAssertTrue(catalog.avoidImmediateRepeat)
        XCTAssertEqual(catalog.assets.count, 31)
        XCTAssertEqual(Set(catalog.assets.map(\.id)).count, 31)
        XCTAssertTrue(
            catalog.assets.allSatisfy {
                $0.fileName.contains("county") &&
                    $0.assetClass == .distantAuthored &&
                    $0.sourceGainDB == 0 &&
                    $0.distanceRolloffFactor == 0
            }
        )
    }

    func testCountySamplerUsesGunfireCadenceAndDistantRadius() throws {
        let catalog = try StoryAmbientCountyCatalogStore().catalog

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
                assetClass: .distantAuthored,
                catalog: catalog,
                unit: 0.5
            ),
            50
        )
    }

    func testGunfireAndCountyUseDifferentRepeatableRandomStreams() async {
        XCTAssertNotEqual(
            StoryAmbientRandomSeed.gunfire,
            StoryAmbientRandomSeed.county
        )

        let firstGunfire = SeededStoryAmbientRandomSource(
            seed: StoryAmbientRandomSeed.gunfire
        )
        let secondGunfire = SeededStoryAmbientRandomSource(
            seed: StoryAmbientRandomSeed.gunfire
        )
        let county = SeededStoryAmbientRandomSource(
            seed: StoryAmbientRandomSeed.county
        )
        var firstGunfireValues = [Double]()
        var secondGunfireValues = [Double]()
        var countyValues = [Double]()

        for _ in 0..<8 {
            firstGunfireValues.append(await firstGunfire.nextUnitInterval())
            secondGunfireValues.append(await secondGunfire.nextUnitInterval())
            countyValues.append(await county.nextUnitInterval())
        }

        XCTAssertEqual(firstGunfireValues, secondGunfireValues)
        XCTAssertNotEqual(firstGunfireValues, countyValues)
        XCTAssertTrue(
            (firstGunfireValues + countyValues).allSatisfy {
                $0 >= 0 && $0 < 1
            }
        )
    }
}
