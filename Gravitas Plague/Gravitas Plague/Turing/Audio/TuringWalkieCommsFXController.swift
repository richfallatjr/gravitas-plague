import Foundation

nonisolated struct TuringWalkieSendingStaticToken:
    Sendable,
    Equatable,
    Hashable
{
    let id: UUID
    let ownerID: String
    let handle: TuringAudioPlaybackHandle
}

@MainActor
final class TuringWalkieCommsFXController {
    static let shared = TuringWalkieCommsFXController()

    private let worker = TuringWalkieCommsFXActor()

    private init() {}

    func playOpenCommBeforeRecording(reason: String) async {
        guard await installEndpointIfAvailable() else { return }
        await worker.playOpenCommBeforeRecording(reason: reason)
    }

    func playScriptedOpenComm(reason: String) async throws {
        try await requireEndpoint()
        try await worker.playScriptedOpenComm(reason: reason)
    }

    func playScriptedSendComm(reason: String) async throws {
        try await requireEndpoint()
        try await worker.playScriptedSendComm(reason: reason)
    }

    func playSendCommAndStartSendingLeadIn(reason: String) async {
        guard await installEndpointIfAvailable() else { return }
        await worker.playSendCommAndStartSendingLeadIn(reason: reason)
        await startAmbientWalkieStatic(reason: "conversationVoice.\(reason)")
        await startSendingLeadIn(reason: reason)
    }

    func runFixedResponseLeadInAfterExternalSend(
        reason: String,
        durationSeconds: TimeInterval
    ) async {
        guard await installEndpointIfAvailable() else { return }
        await startAmbientWalkieStatic(reason: "externalSend.\(reason)")
        await startSendingLeadIn(reason: "externalSend.\(reason)")
        let completed = await worker.runFixedDelay(seconds: durationSeconds)
        await stopSendingLeadIn(
            reason: completed
                ? "fixedResponseLeadInCompleted.\(reason)"
                : "fixedResponseLeadInCancelled.\(reason)"
        )
    }

    func stopSendingLeadIn(reason: String) async {
        await worker.stopSendingLeadIn(reason: reason)
        await TuringStoryWalkieAudioRoute.stopSendingStaticLoop(reason: reason)
    }

    func beginLiveConversationSendingStatic(
        ownerID: String,
        reason: String
    ) async throws -> TuringWalkieSendingStaticToken {
        let token = try await beginRetainedSendingStatic(
            ownerID: ownerID,
            reason: reason
        )
        let ambientRetained = await retainAmbientWalkieStatic(
            ownerID: ownerID,
            reason: "liveConversation.\(reason)"
        )
        await worker.playSendCommAndStartSendingLeadIn(reason: reason)
        await worker.beginSendingLeadIn(reason: reason)
        print("[TuringWalkieComms] live send cover started ownerID=\(ownerID) sendComm=true ambient=\(ambientRetained) randomBursts=true reason=\(reason)")
        return token
    }

    func endLiveConversationSendingStatic(
        token: TuringWalkieSendingStaticToken,
        reason: String
    ) async {
        await endLiveConversationSendingCover(
            token: token,
            reason: reason
        )
        await releaseAmbientWalkieStatic(
            ownerID: token.ownerID,
            reason: reason
        )
        print("[TuringWalkieComms] live ambient released ownerID=\(token.ownerID) reason=\(reason)")
    }

    func endLiveConversationSendingCover(
        token: TuringWalkieSendingStaticToken,
        reason: String
    ) async {
        await worker.stopSendingLeadIn(reason: reason)
        await endRetainedSendingStatic(token: token, reason: reason)
        print("[TuringWalkieComms] live send cover stopped ownerID=\(token.ownerID) ambientRetained=true reason=\(reason)")
    }

    func beginPrerecordingOrientationSendingStatic(
        ownerID: String,
        reason: String
    ) async throws -> TuringWalkieSendingStaticToken {
        try await beginRetainedSendingStatic(
            ownerID: ownerID,
            reason: reason
        )
    }

    func endPrerecordingOrientationSendingStatic(
        token: TuringWalkieSendingStaticToken,
        reason: String
    ) async {
        await endRetainedSendingStatic(token: token, reason: reason)
    }

    private func beginRetainedSendingStatic(
        ownerID: String,
        reason: String
    ) async throws -> TuringWalkieSendingStaticToken {
        guard await installEndpointIfAvailable() else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }
        let url = try await worker.sendingStaticURL()
        let handle = try await TuringStoryWalkieAudioRoute
            .startRetainedSendingStaticLoop(
                fileURL: url,
                ownerID: ownerID,
                reason: reason
            )
        return TuringWalkieSendingStaticToken(
            id: UUID(),
            ownerID: ownerID,
            handle: handle
        )
    }

    private func endRetainedSendingStatic(
        token: TuringWalkieSendingStaticToken,
        reason: String
    ) async {
        await TuringStoryWalkieAudioRoute.stopRetainedSendingStaticLoop(
            ownerID: token.ownerID,
            handle: token.handle,
            reason: reason
        )
    }

    func startAmbientWalkieStatic(reason: String) async {
        guard let url = try? await worker.ambientStaticURL() else { return }
        _ = await TuringStoryWalkieAudioRoute.startAmbientWalkieStaticLoop(
            fileURL: url,
            reason: reason
        )
    }

    @discardableResult
    func retainAmbientWalkieStatic(
        ownerID: String,
        reason: String
    ) async -> Bool {
        guard let url = try? await worker.ambientStaticURL() else { return false }
        return await TuringStoryWalkieAudioRoute
            .retainAmbientWalkieStaticLoop(
                fileURL: url,
                ownerID: ownerID,
                reason: reason
            )
    }

    func stopAmbientWalkieStatic(reason: String) async {
        await TuringStoryWalkieAudioRoute.stopAmbientWalkieStaticLoop(
            reason: reason
        )
    }

    func releaseAmbientWalkieStatic(
        ownerID: String,
        reason: String
    ) async {
        await TuringStoryWalkieAudioRoute
            .releaseAmbientWalkieStaticLoop(
                ownerID: ownerID,
                reason: reason
            )
    }

    func stopAll(reason: String) async {
        await worker.stopAll(reason: reason)
        await TuringStoryWalkieAudioRoute.stopSendingStaticLoop(reason: reason)
        await TuringStoryWalkieAudioRoute.stopAmbientWalkieStaticLoop(
            reason: reason
        )
    }

    private func startSendingLeadIn(reason: String) async {
        guard let url = try? await worker.sendingStaticURL() else { return }
        let started = await TuringStoryWalkieAudioRoute.startSendingStaticLoop(
            fileURL: url,
            reason: reason
        )
        guard started else { return }
        await worker.beginSendingLeadIn(reason: reason)
    }

    private func installEndpointIfAvailable() async -> Bool {
        guard let endpoint = TuringStoryWalkieAudioRoute
            .makeActiveEndpoint() else { return false }
        await worker.install(endpoint: endpoint)
        return true
    }

    private func requireEndpoint() async throws {
        guard await installEndpointIfAvailable() else {
            throw TuringWalkieAudioError.missingWalkieEmitter
        }
    }
}
