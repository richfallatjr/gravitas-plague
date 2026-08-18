import Foundation

nonisolated struct StoryMemoryMusicLiveGapToken: Sendable, Equatable {
    let id: UUID
    let flowInstanceID: UUID
    let memoryMusicToken: StoryMemoryMusicActor.Token
}

nonisolated enum TuringLiveConversationInitialFillerToken: Sendable, Equatable {
    case dadPhoto(StoryMemoryMusicLiveGapToken)
    case crankRadio(ownerID: String)
    case hamReceiver(ownerID: String)
    case walkie(TuringWalkieSendingStaticToken)
}

nonisolated struct TuringLiveConversationInitialFillerRequest: Sendable {
    let ownerID: String
    let surface: StoryInteractionSurfaceID
    let seed: TuringLiveConversationSeed
}

@MainActor
final class TuringLiveConversationInitialFillerController {
    static let shared = TuringLiveConversationInitialFillerController()

    private init() {}

    func begin(
        request: TuringLiveConversationInitialFillerRequest
    ) async -> TuringLiveConversationInitialFillerToken? {
        switch request.surface {
        case .dadFrame:
            do {
                return .dadPhoto(
                    try await TuringFlowMediaCueCoordinator.shared
                        .retainForLiveConversationGap(
                            music: request.seed.backgroundMusic,
                            identity: request.seed.authoredIdentity
                        )
                )
            } catch {
                print("[TuringLiveConversation] Dad score filler unavailable error=\(error.localizedDescription)")
                return nil
            }
        case .crankRadio:
            await TuringCrankRadioTuningLoopActor.shared.beginGap(
                ownerID: request.ownerID,
                waitingForSegmentIndex: 0,
                reason: "liveConversationInitialGap"
            )
            return .crankRadio(ownerID: request.ownerID)
        case .hamReceiver:
            await TuringRandomTuningLoopActor.hamReceiver.beginGap(
                ownerID: request.ownerID,
                waitingForSegmentIndex: 0,
                reason: "liveConversationInitialGap"
            )
            return .hamReceiver(ownerID: request.ownerID)
        case .walkie:
            do {
                return .walkie(
                    try await TuringWalkieCommsFXController.shared
                        .beginLiveConversationSendingStatic(
                        ownerID: request.ownerID,
                        reason: "liveConversationInitialGap"
                    )
                )
            } catch {
                print("[TuringLiveConversation] walkie initial filler unavailable error=\(error.localizedDescription)")
                return nil
            }
        }
    }

    func end(
        _ token: TuringLiveConversationInitialFillerToken,
        reason: String
    ) async {
        switch token {
        case .dadPhoto(let token):
            await TuringFlowMediaCueCoordinator.shared
                .releaseLiveConversationGap(
                token: token,
                reason: reason
            )
        case .crankRadio(let ownerID):
            await TuringCrankRadioTuningLoopActor.shared.endGap(
                ownerID: ownerID,
                reason: reason
            )
        case .hamReceiver(let ownerID):
            await TuringRandomTuningLoopActor.hamReceiver.endGap(
                ownerID: ownerID,
                reason: reason
            )
        case .walkie(let token):
            await TuringWalkieCommsFXController.shared
                .endLiveConversationSendingStatic(
                token: token,
                reason: reason
            )
        }
    }
}
