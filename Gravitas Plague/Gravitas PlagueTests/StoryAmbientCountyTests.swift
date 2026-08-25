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
        XCTAssertEqual(catalog.assets.count, 30)
        XCTAssertEqual(Set(catalog.assets.map(\.id)).count, 30)
        XCTAssertTrue(
            catalog.assets.allSatisfy {
                $0.fileName.contains("county") &&
                    StoryAmbientCountyFileNaming.selectionWeight(
                        from: $0.fileName
                    ) == Int($0.selectionWeight) &&
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

    func testCountyFilenameWeightsAreTheProductionSelectionWeights() throws {
        let catalog = try StoryAmbientCountyCatalogStore().catalog
        let assetsByWeight = Dictionary(
            grouping: catalog.assets,
            by: \.selectionWeight
        )

        XCTAssertEqual(assetsByWeight[1]?.count, 8)
        XCTAssertEqual(assetsByWeight[5]?.count, 3)
        XCTAssertEqual(assetsByWeight[7]?.count, 3)
        XCTAssertEqual(assetsByWeight[10]?.count, 16)
        XCTAssertEqual(Set(assetsByWeight.keys), Set([1, 5, 7, 10]))
        XCTAssertEqual(
            Int(catalog.assets.reduce(0) { $0 + $1.selectionWeight }),
            204
        )
    }

    func testWeightedSelectorAllocatesSlotsFromFilenameWeights() throws {
        let assets = try StoryAmbientCountyCatalogStore().catalog.assets
        let totalWeight = Int(
            assets.reduce(0) { $0 + $1.selectionWeight }
        )
        var selectionCounts = [String: Int]()

        for slot in 0..<totalWeight {
            let unit = (Double(slot) + 0.5) / Double(totalWeight)
            guard let selected = StoryAmbientGunfireWeightedSelector.select(
                from: assets,
                unit: unit
            ) else {
                XCTFail("Weighted county selection unexpectedly returned nil")
                return
            }
            selectionCounts[selected.id, default: 0] += 1
        }

        for asset in assets {
            XCTAssertEqual(
                selectionCounts[asset.id],
                Int(asset.selectionWeight),
                "Incorrect weighted slot count for \(asset.fileName)"
            )
        }
    }

    func testCountyWeightNamingRejectsOldAndOutOfRangeNames() {
        XCTAssertNil(
            StoryAmbientCountyFileNaming.selectionWeight(
                from: "dog-01-county.wav"
            )
        )
        XCTAssertNil(
            StoryAmbientCountyFileNaming.selectionWeight(
                from: "dog-01-county-11.wav"
            )
        )
        XCTAssertEqual(
            StoryAmbientCountyFileNaming.selectionWeight(
                from: "dog-01-county-10.wav"
            ),
            10
        )
        XCTAssertEqual(
            StoryAmbientCountyFileNaming.selectionWeight(
                from: "thunder-01-county-10.mp3"
            ),
            10
        )
    }

    func testGunfireAndCountyUseDifferentRepeatableRandomStreams() async {
        XCTAssertEqual(
            Set([
                StoryAmbientRandomSeed.gunfire,
                StoryAmbientRandomSeed.county,
                StoryAmbientRandomSeed.countySecondary
            ]).count,
            3
        )
        XCTAssertEqual(
            StoryAmbientGroundChannel.county.resourceDirectory,
            StoryAmbientGroundChannel.countySecondary.resourceDirectory
        )
        XCTAssertNotEqual(
            StoryAmbientGroundChannel.county.logName,
            StoryAmbientGroundChannel.countySecondary.logName
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
        let countySecondary = SeededStoryAmbientRandomSource(
            seed: StoryAmbientRandomSeed.countySecondary
        )
        var firstGunfireValues = [Double]()
        var secondGunfireValues = [Double]()
        var countyValues = [Double]()
        var countySecondaryValues = [Double]()

        for _ in 0..<8 {
            firstGunfireValues.append(await firstGunfire.nextUnitInterval())
            secondGunfireValues.append(await secondGunfire.nextUnitInterval())
            countyValues.append(await county.nextUnitInterval())
            countySecondaryValues.append(
                await countySecondary.nextUnitInterval()
            )
        }

        XCTAssertEqual(firstGunfireValues, secondGunfireValues)
        XCTAssertNotEqual(firstGunfireValues, countyValues)
        XCTAssertNotEqual(firstGunfireValues, countySecondaryValues)
        XCTAssertNotEqual(countyValues, countySecondaryValues)
        XCTAssertTrue(
            (
                firstGunfireValues +
                    countyValues +
                    countySecondaryValues
            ).allSatisfy {
                $0 >= 0 && $0 < 1
            }
        )
    }
}
