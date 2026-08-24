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
        XCTAssertEqual(StoryTitleCardCatalog.chapter02.title, "Chapter 2")
        XCTAssertEqual(
            StoryTitleCardCatalog.chapter02.subtitle,
            "The Night the Lights Went Out"
        )
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
            StoryTitleCardCatalog.chapter02.holdSeconds,
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

    func testUnlockedEpisodeSuccessorsFollowTheAuthoredChapterOrder() {
        XCTAssertEqual(
            TuringEpisodeCatalog.nextUnlockedEpisode(after: .prologue),
            .chapter01
        )
        XCTAssertEqual(
            TuringEpisodeCatalog.nextUnlockedEpisode(after: .chapter01),
            .chapter02
        )
        XCTAssertNil(TuringEpisodeCatalog.nextUnlockedEpisode(after: .chapter02))
    }

    func testChapterOneCardStopsPrologueAftermathOnlyAfterFade() {
        XCTAssertTrue(
            StoryTitleCardDestination.advance(
                from: .prologue,
                to: .chapter01
            ).stopsPrologueAftermathAfterFade
        )
        XCTAssertTrue(
            StoryTitleCardDestination.start(.chapter01)
                .stopsPrologueAftermathAfterFade
        )
        XCTAssertFalse(
            StoryTitleCardDestination.start(.prologue)
                .stopsPrologueAftermathAfterFade
        )
    }

    func testTerminalCardStopsChapterTwoBattleMusicOnlyAfterFade() {
        XCTAssertTrue(
            StoryTitleCardDestination.endOfAvailableContent(
                completedEpisode: .chapter02
            ).stopsChapter02BattleMusicAfterFade
        )
        XCTAssertFalse(
            StoryTitleCardDestination.start(.chapter02)
                .stopsChapter02BattleMusicAfterFade
        )
    }

    func testOnlyTerminalDestinationsReturnToOperationMenu() {
        XCTAssertTrue(
            StoryTitleCardDestination.endOfAvailableContent(
                completedEpisode: .chapter03
            ).returnsToOperationMenuAfterCompletion
        )
        XCTAssertFalse(
            StoryTitleCardDestination.start(.chapter03)
                .returnsToOperationMenuAfterCompletion
        )
        XCTAssertFalse(
            StoryTitleCardDestination.advance(
                from: .chapter02,
                to: .chapter03
            ).returnsToOperationMenuAfterCompletion
        )
    }
}
