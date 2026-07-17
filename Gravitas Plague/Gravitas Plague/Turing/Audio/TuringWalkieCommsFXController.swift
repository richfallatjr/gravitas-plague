import Foundation

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

    func startAmbientWalkieStatic(reason: String) async {
        guard let url = try? await worker.ambientStaticURL() else { return }
        _ = await TuringStoryWalkieAudioRoute.startAmbientWalkieStaticLoop(
            fileURL: url,
            reason: reason
        )
    }

    func stopAmbientWalkieStatic(reason: String) async {
        await TuringStoryWalkieAudioRoute.stopAmbientWalkieStaticLoop(
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
