import XCTest
@testable import Gravitas_Plague

final class Chapter03DefinitionAndCatalogTests: XCTestCase {
    func testProductionCatalogAdvancesChapter02IntoAuthoredChapter03() {
        XCTAssertTrue(
            TuringEpisodeCatalog.productionEpisodes.contains {
                $0.id == .chapter03
            }
        )
        let pickerEpisode = TuringEpisodeCatalog.productionPickerEpisodes.first {
            $0.id == .chapter03
        }
        XCTAssertEqual(pickerEpisode?.stripArtwork, .chapter03Strip)
        XCTAssertTrue(pickerEpisode?.isUnlocked == true)
        XCTAssertEqual(
            TuringEpisodeCatalog.nextUnlockedEpisode(after: .chapter02),
            .chapter03
        )
        XCTAssertEqual(Chapter03RootPlan.current, .authoredOpening)
        XCTAssertEqual(
            StoryTitleCardCatalog.chapter03LightTunnelTest.title,
            "Chapter 3"
        )
        XCTAssertEqual(
            StoryTitleCardCatalog.chapter03LightTunnelTest.subtitle,
            "Light at the End of the Tunnel"
        )
    }

    func testChapter03BattleDefinitionsUseOneShotMinusSevenDBMusic() throws {
        let store = Chapter03BattleDefinitionStore()
        let biker = try store.load(.biker)
        let mike = try store.load(.mike)

        XCTAssertEqual(biker.playerConfirmedHitsToKill, 10)
        XCTAssertEqual(mike.playerConfirmedHitsToKill, 10)
        XCTAssertEqual(biker.music.map(\.gainDB), [-7])
        XCTAssertEqual(mike.music.map(\.gainDB), [-7, -7])
        XCTAssertTrue((biker.music + mike.music).allSatisfy { !$0.loop })
        XCTAssertEqual(mike.enemy.acceptedCapacityNumerator, 4)
        XCTAssertEqual(mike.enemy.acceptedCapacityDenominator, 3)
        XCTAssertEqual(mike.postSurrenderPrerecordingBeatSeconds, 1)
        XCTAssertEqual(mike.fadeToBlackSeconds, 1.5)
    }

    func testMikeCapacityIsCeilingThirtyThreePercentAboveDadEquivalent() {
        XCTAssertEqual(
            Chapter03BattleEnemyFactory.mikeAcceptedHitCapacity(
                dadEquivalentCapacity: 9,
                numerator: 4,
                denominator: 3
            ),
            12
        )
        XCTAssertEqual(
            Chapter03BattleEnemyFactory.mikeAcceptedHitCapacity(
                dadEquivalentCapacity: 10,
                numerator: 4,
                denominator: 3
            ),
            14
        )
    }

    func testCircularPortalAndPortalArrivalAngelDefinitionValidate() throws {
        let definition = Chapter03LightTunnelDefinition(
            schemaVersion: 1,
            sequenceID: "chapter03.cinematic.lightTunnel.001",
            contentRevision: "chapter03.lightTunnelTest.v2",
            music: .init(
                resourcePath: "Turing/Audio/chapter03/chapter03-light-at-the-end-of-the-tunnel.mp3",
                minimumDurationSeconds: 180,
                maximumDurationSeconds: 240,
                loop: false,
                gainDB: -15,
                fadeInSeconds: 1.5,
                fadeOutSeconds: 1.5
            ),
            visual: .init(
                portalDiameterMeters: 2.286,
                startDistanceMeters: 30.48,
                endDistanceMeters: 3.048,
                approachDurationSeconds: 60,
                postApproachTravelMeters: 0.9144,
                angelInsideOffsetMeters: 1,
                angelRootYOffsetMeters: -0.9,
                domeRadiusMeters: 12,
                domeCenterOffsetZMeters: -9
            ),
            angelPrerecording: .init(
                descriptorResourcePath:
                    "Turing/Cinematics/Chapter03/pr_angel_01.json",
                trigger: .atPortalArrival,
                musicDuckGainDB: -23,
                duckAttackSeconds: 0.75,
                duckReleaseSeconds: 0.75
            ),
            completion: .init(
                waitForMusicActualCompletion: true,
                waitForAngelPrerecordingIfStarted: true,
                destination: "endOfAvailableContent"
            )
        )
        XCTAssertNoThrow(try definition.validate())
        XCTAssertEqual(
            definition.angelPrerecording?.musicDuckGainDB,
            -23
        )
    }

    func testAngelPrerecordingStartsAtTenFootPortalArrival() throws {
        let start = try Chapter03LightTunnelDefinitionStore
            .portalArrivalStartMediaTime(
                musicDurationSeconds: 240.039167,
                portalArrivalMediaTimeSeconds: 60,
                prerecordingDurationSeconds: 145.763250
            )
        XCTAssertEqual(start, 60, accuracy: 0.000001)
    }

    func testPortalOutsideAuthoredDiameterIsRejected() {
        let visual = Chapter03LightTunnelVisualDefinition(
            portalDiameterMeters: 3,
            startDistanceMeters: 30.48,
            endDistanceMeters: 3.048,
            approachDurationSeconds: 60,
            postApproachTravelMeters: 0.9144,
            angelInsideOffsetMeters: 1,
            angelRootYOffsetMeters: -0.9,
            domeRadiusMeters: 12,
            domeCenterOffsetZMeters: -9
        )
        XCTAssertThrowsError(try visual.validate())
    }
}
