import XCTest
import simd

@testable import Gravitas_Plague

final class StoryTitleCardFlowTests: XCTestCase {
    func testProductionCardCopyIsExact() {
        XCTAssertEqual(StoryTitleCardCatalog.prologue.title, "Prologue")
        XCTAssertEqual(
            StoryTitleCardCatalog.prologue.subtitle,
            "They are not human they are monsters"
        )
        XCTAssertEqual(StoryTitleCardCatalog.chapter01.title, "Chapter 1")
        XCTAssertEqual(StoryTitleCardCatalog.chapter01.subtitle, "Dad?")
        XCTAssertEqual(
            StoryTitleCardCatalog.endOfAvailableContent.title,
            "Gravitas Plague"
        )
        XCTAssertNil(StoryTitleCardCatalog.endOfAvailableContent.subtitle)
    }

    func testTitleCardsUseExtendedHoldDurations() {
        XCTAssertEqual(
            StoryTitleCardCatalog.prologue.holdSeconds,
            .milliseconds(7_500)
        )
        XCTAssertEqual(
            StoryTitleCardCatalog.chapter01.holdSeconds,
            .milliseconds(7_500)
        )
        XCTAssertEqual(
            StoryTitleCardCatalog.endOfAvailableContent.holdSeconds,
            .milliseconds(9_000)
        )
    }

    func testTitleCardsAreLowerThanYouDiedCard() {
        XCTAssertLessThan(
            CinematicWorldCardTransform.titleWorldYLiftMeters,
            CinematicWorldCardTransform.worldYLiftMeters
        )
        XCTAssertEqual(
            CinematicWorldCardTransform.titleWorldYLiftMeters,
            -0.1524,
            accuracy: 0.0001
        )
    }

    func testTitleCardTransformHasNoXPitch() {
        let transform = CinematicWorldCardTransform.worldTransform(
            originFromDevice: matrix_identity_float4x4,
            verticalLiftMeters:
                CinematicWorldCardTransform.titleWorldYLiftMeters,
            xRotationDegrees: 0
        )

        XCTAssertEqual(transform.columns.1.z, 0, accuracy: 0.0001)
        XCTAssertEqual(transform.columns.2.y, 0, accuracy: 0.0001)
    }

    func testContinueKeepsMenuMusicThroughCard() {
        let request = StoryTitleCardTransitionRequest(
            requestID: UUID(),
            source: .episodePickerContinue,
            descriptor: StoryTitleCardCatalog.chapter01,
            destination: .endOfAvailableContent(completedEpisode: .chapter01),
            menuMusicPolicy: .playThroughCard
        )

        XCTAssertEqual(request.menuMusicPolicy, .playThroughCard)
    }

    func testEpisodeStartKeepsMenuMusicThroughCard() {
        let request = StoryTitleCardTransitionRequest(
            requestID: UUID(),
            source: .episodePickerStart,
            descriptor: StoryTitleCardCatalog.prologue,
            destination: .start(.prologue),
            menuMusicPolicy: .playThroughCard
        )

        XCTAssertEqual(request.menuMusicPolicy, .playThroughCard)
    }

    func testChapterOneIsTheOnlyUnlockedSuccessorToPrologue() {
        XCTAssertEqual(
            TuringEpisodeCatalog.nextUnlockedEpisode(after: .prologue),
            .chapter01
        )
        XCTAssertNil(TuringEpisodeCatalog.nextUnlockedEpisode(after: .chapter01))
    }
}
