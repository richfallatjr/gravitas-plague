import XCTest
@testable import Gravitas_Plague

final class Chapter03DefinitionAndCatalogTests: XCTestCase {
    func testProductionPickerExposesChapter03PlaceholderWithoutAdvancingChapter02() {
        XCTAssertFalse(
            TuringEpisodeCatalog.productionEpisodes.contains {
                $0.id == .chapter03
            }
        )
        let pickerEpisode = TuringEpisodeCatalog.productionPickerEpisodes.first {
            $0.id == .chapter03
        }
        XCTAssertEqual(pickerEpisode?.stripArtwork, .chapter03Strip)
        XCTAssertTrue(pickerEpisode?.isUnlocked == true)
        XCTAssertNil(TuringEpisodeCatalog.nextUnlockedEpisode(after: .chapter02))
        XCTAssertEqual(
            StoryTitleCardCatalog.chapter03LightTunnelTest.title,
            "Chapter 3"
        )
        XCTAssertEqual(
            StoryTitleCardCatalog.chapter03LightTunnelTest.subtitle,
            "Light at the End of the Tunnel"
        )
    }

    func testCircularPortalDefinitionAndSafetyBoundsValidate() throws {
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
                angelInsideOffsetMeters: 1,
                angelRootYOffsetMeters: -0.9,
                domeRadiusMeters: 12,
                domeCenterOffsetZMeters: -9
            ),
            angelPrerecording: nil,
            completion: .init(
                waitForMusicActualCompletion: true,
                waitForAngelPrerecordingIfStarted: true,
                destination: "endOfAvailableContent"
            )
        )
        XCTAssertNoThrow(try definition.validate())
        XCTAssertNil(definition.angelPrerecording)
    }

    func testPortalOutsideAuthoredDiameterIsRejected() {
        let visual = Chapter03LightTunnelVisualDefinition(
            portalDiameterMeters: 3,
            startDistanceMeters: 30.48,
            endDistanceMeters: 3.048,
            approachDurationSeconds: 60,
            angelInsideOffsetMeters: 1,
            angelRootYOffsetMeters: -0.9,
            domeRadiusMeters: 12,
            domeCenterOffsetZMeters: -9
        )
        XCTAssertThrowsError(try visual.validate())
    }
}
