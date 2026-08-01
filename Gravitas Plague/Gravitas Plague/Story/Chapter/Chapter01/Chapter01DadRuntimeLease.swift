import Foundation

@MainActor
final class Chapter01DadRuntimeLease {
    let chapterRunID: UUID
    private(set) var controller: JockRetargetTestController?

    private let corpsePresenter: BattleCorpsePresentationController
    private let heavyRuntimeRegistry: StoryHeavyRuntimeRegistry
    private var completedReport: Chapter01DadRuntimeReleaseReport?

    init(
        chapterRunID: UUID,
        controller: JockRetargetTestController,
        corpsePresenter: BattleCorpsePresentationController,
        heavyRuntimeRegistry: StoryHeavyRuntimeRegistry
    ) {
        self.chapterRunID = chapterRunID
        self.controller = controller
        self.corpsePresenter = corpsePresenter
        self.heavyRuntimeRegistry = heavyRuntimeRegistry
    }

    func release(reason: String) async throws -> Chapter01DadRuntimeReleaseReport {
        if let completedReport {
            return completedReport
        }
        guard let controller else {
            let report = Chapter01DadRuntimeReleaseReport(
                chapterRunID: chapterRunID,
                heavyRuntimeReleased: true,
                preparedClipCountReleased: 0,
                collisionCountReleased: 0,
                audioControllerCountReleased: 0
            )
            completedReport = report
            return report
        }

        controller.cancelScriptedClipCompletion()
        controller.stopScriptedLocomotion(reason: reason)
        let result = try await controller.releaseBattleRuntime(
            reason: .battleCompleted,
            retentionPolicy: .remove,
            corpsePresenter: corpsePresenter
        )
        self.controller = nil
        await heavyRuntimeRegistry.remove(.dad(chapterRunID))
        await Task.yield()
        await Task.yield()
        await Task.yield()

        let report = Chapter01DadRuntimeReleaseReport(
            chapterRunID: chapterRunID,
            heavyRuntimeReleased: result.heavyRuntimeReleased,
            preparedClipCountReleased: result.releasedPreparedClipCount,
            collisionCountReleased: result.releasedCollisionCount,
            audioControllerCountReleased: result.releasedAudioControllerCount
        )
        completedReport = report
        print(
            "[Chapter01Dad] runtime released chapterRunID=\(chapterRunID.uuidString) reason=\(reason) preparedClips=\(result.releasedPreparedClipCount)"
        )
        return report
    }
}
