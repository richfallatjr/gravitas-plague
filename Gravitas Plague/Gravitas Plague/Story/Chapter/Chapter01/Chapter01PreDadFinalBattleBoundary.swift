import Foundation

struct Chapter01PreDadFinalBattleReadyEvent: Sendable, Equatable {
    let chapterRunID: UUID
    let checkpointRevision: Int
    let sourceEventID: UUID
    let completedBranches: Set<Chapter01PostRobotBranch>
}

@MainActor
protocol Chapter01PreDadFinalBattleReadySink: AnyObject {
    func preDadFinalBattleBecameReady(
        _ event: Chapter01PreDadFinalBattleReadyEvent
    ) async
}

@MainActor
final class Chapter01PreDadFinalBattleBoundary {
    weak var sink: (any Chapter01PreDadFinalBattleReadySink)?
    private var lastPublishedRevision: Int?

    func publishIfNeeded(
        _ event: Chapter01PreDadFinalBattleReadyEvent
    ) async {
        guard event.completedBranches == Set(Chapter01PostRobotBranch.allCases),
              lastPublishedRevision != event.checkpointRevision else {
            return
        }
        lastPublishedRevision = event.checkpointRevision
        print("""
        [Chapter01] pre-Dad final battle ready
          chapterRunID: \(event.chapterRunID.uuidString)
          checkpointRevision: \(event.checkpointRevision)
          sourceEventID: \(event.sourceEventID.uuidString)
          completedBranches: \(event.completedBranches)
          finalBattleImplemented: false
        """)
        await sink?.preDadFinalBattleBecameReady(event)
    }

    func resetTransientPublicationState() {
        lastPublishedRevision = nil
    }
}
