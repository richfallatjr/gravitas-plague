import Foundation

nonisolated struct TuringFlowMediaCueOrientationToken: Sendable, Equatable {
    let id: UUID
    let flowInstanceID: UUID
    let memoryMusicToken: StoryMemoryMusicActor.Token
}

nonisolated struct TuringPrerecordingOrientationRequest: Sendable {
    let flowIdentity: TuringFlowIdentity
    let descriptor: TuringFlowDescriptor
    let mediaItemID: String
    let mediaRole: TuringAuthoredMediaItem.Role
    let interactionSurface: StoryInteractionSurfaceID
}

nonisolated enum TuringPrerecordingOrientationFillerToken: Sendable, Equatable {
    case dadPhoto(TuringFlowMediaCueOrientationToken)
    case crankRadio(TuringCrankRadioOrientationToken)
    case hamReceiver(TuringRandomTuningOrientationToken)
    case walkie(TuringWalkieSendingStaticToken)
}

nonisolated struct TuringPrerecordingOrientationReport: Sendable, Equatable {
    let flowInstanceID: UUID
    let mediaItemID: String
    let surface: StoryInteractionSurfaceID
    let sampledSeconds: Double
    let fillerStarted: Bool
    let fillerDescription: String
    let fillerStoppedBeforePR: Bool
}

actor TuringPrerecordingOrientationCoordinator {
    static let shared = TuringPrerecordingOrientationCoordinator()

    private let durationSampler: any TuringPrerecordingOrientationDurationSampling
    private let clock: any BattleClock
    private var activeByFlowID:
        [UUID: TuringPrerecordingOrientationFillerToken] = [:]

    init(
        durationSampler: any TuringPrerecordingOrientationDurationSampling =
            TuringSystemPrerecordingOrientationDurationSampler(),
        clock: any BattleClock = ProductionBattleClock()
    ) {
        self.durationSampler = durationSampler
        self.clock = clock
    }

    func run(
        _ request: TuringPrerecordingOrientationRequest
    ) async throws -> TuringPrerecordingOrientationReport {
        guard TuringPrerecordingOrientationEligibility.permits(
            descriptor: request.descriptor,
            role: request.mediaRole
        ) else {
            throw TuringRuntimeError.invalidConfig(
                "Only a non-battle device PR or authored device bridge may run orientation."
            )
        }
        let seconds = durationSampler.sampleSeconds()
        guard seconds.isFinite, (2.0...5.0).contains(seconds) else {
            throw TuringRuntimeError.invalidConfig(
                "PR orientation duration must be between two and five seconds."
            )
        }

        let ownerID = request.flowIdentity.playbackRunID
        let token: TuringPrerecordingOrientationFillerToken
        do {
            switch request.interactionSurface {
            case .dadFrame:
                token = .dadPhoto(
                    try await TuringFlowMediaCueCoordinator.shared
                        .retainForPrerecordingOrientation(
                            descriptor: request.descriptor,
                            identity: request.flowIdentity,
                            mediaItemID: request.mediaItemID
                        )
                )
            case .crankRadio:
                token = .crankRadio(
                    try await TuringCrankRadioTuningLoopActor.shared
                        .beginPrerecordingOrientation(
                            ownerID: ownerID,
                            reason: "prOrientation"
                        )
                )
            case .hamReceiver:
                token = .hamReceiver(
                    try await TuringRandomTuningLoopActor.hamReceiver
                        .beginPrerecordingOrientation(
                            ownerID: ownerID,
                            reason: "prOrientation"
                        )
                )
            case .walkie:
                token = .walkie(
                    try await TuringWalkieCommsFXController.shared
                        .beginPrerecordingOrientationSendingStatic(
                            ownerID: ownerID,
                            reason: "prOrientation"
                        )
                )
            }
        } catch {
            print("[TuringPROrientation] degraded itemID=\(request.mediaItemID) surface=\(request.interactionSurface.rawValue) error=\(error.localizedDescription)")
            return TuringPrerecordingOrientationReport(
                flowInstanceID: request.flowIdentity.flowInstanceID,
                mediaItemID: request.mediaItemID,
                surface: request.interactionSurface,
                sampledSeconds: seconds,
                fillerStarted: false,
                fillerDescription: "unavailable",
                fillerStoppedBeforePR: true
            )
        }

        activeByFlowID[request.flowIdentity.flowInstanceID] = token
        do {
            try await clock.sleep(for: .seconds(seconds))
            await stop(
                token,
                flowInstanceID: request.flowIdentity.flowInstanceID,
                reason: "orientationCompleted"
            )
        } catch {
            await stop(
                token,
                flowInstanceID: request.flowIdentity.flowInstanceID,
                reason: "orientationCancelled"
            )
            throw error
        }

        return TuringPrerecordingOrientationReport(
            flowInstanceID: request.flowIdentity.flowInstanceID,
            mediaItemID: request.mediaItemID,
            surface: request.interactionSurface,
            sampledSeconds: seconds,
            fillerStarted: true,
            fillerDescription: String(describing: token),
            fillerStoppedBeforePR: true
        )
    }

    func cancel(flowInstanceID: UUID, reason: String) async {
        guard let token = activeByFlowID[flowInstanceID] else { return }
        await stop(token, flowInstanceID: flowInstanceID, reason: reason)
    }

    private func stop(
        _ token: TuringPrerecordingOrientationFillerToken,
        flowInstanceID: UUID,
        reason: String
    ) async {
        guard activeByFlowID.removeValue(forKey: flowInstanceID) == token else {
            return
        }
        switch token {
        case .dadPhoto(let value):
            await TuringFlowMediaCueCoordinator.shared
                .releasePrerecordingOrientation(token: value, reason: reason)
        case .crankRadio(let value):
            await TuringCrankRadioTuningLoopActor.shared
                .endPrerecordingOrientation(value, reason: reason)
        case .hamReceiver(let value):
            await TuringRandomTuningLoopActor.hamReceiver
                .endPrerecordingOrientation(value, reason: reason)
        case .walkie(let value):
            await TuringWalkieCommsFXController.shared
                .endPrerecordingOrientationSendingStatic(
                    token: value,
                    reason: reason
                )
        }
    }
}
