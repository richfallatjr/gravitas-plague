import XCTest

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

    func testEpisodeStartStopsMenuMusicOnAcceptance() {
        let request = StoryTitleCardTransitionRequest(
            requestID: UUID(),
            source: .episodePickerStart,
            descriptor: StoryTitleCardCatalog.prologue,
            destination: .start(.prologue),
            menuMusicPolicy: .stopOnAcceptance
        )

        XCTAssertEqual(request.menuMusicPolicy, .stopOnAcceptance)
    }

    func testChapterOneIsTheOnlyUnlockedSuccessorToPrologue() {
        XCTAssertEqual(
            TuringEpisodeCatalog.nextUnlockedEpisode(after: .prologue),
            .chapter01
        )
        XCTAssertNil(TuringEpisodeCatalog.nextUnlockedEpisode(after: .chapter01))
    }
}
