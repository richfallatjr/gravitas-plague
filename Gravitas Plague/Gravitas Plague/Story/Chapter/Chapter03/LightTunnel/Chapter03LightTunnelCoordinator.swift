import Foundation
import simd

@MainActor
final class Chapter03LightTunnelCoordinator {
    private let presenter: Chapter03LightTunnelPresenter
    private let music: Chapter03LightTunnelMusicController
    private let angelPrerecording: StorySpatialPrerecordingPlayer
    private let cinematicWorld: CinematicWorldPresentationCoordinator
    private let deviceTransformProvider: () -> simd_float4x4?
    private weak var blackout: ImmersiveBlackoutController?

    private(set) var state: Chapter03State = .idle
    private var activeRequest: Chapter03LightTunnelRequest?
    private var eventTask: Task<Void, Never>?
    private var portalArrivalLogged = false
    private var musicActuallyCompleted = false
    private var angelPrerecordingStarted = false
    private var angelPrerecordingActuallyCompleted = false
    private var isFinishing = false

    var onCompleted: ((Chapter03LightTunnelCompletedEvent) async -> Void)?
    var onFailed: ((UUID, Error) async -> Void)?

    init(
        presenter: Chapter03LightTunnelPresenter,
        music: Chapter03LightTunnelMusicController,
        angelPrerecording: StorySpatialPrerecordingPlayer,
        cinematicWorld: CinematicWorldPresentationCoordinator,
        deviceTransformProvider: @escaping () -> simd_float4x4?
    ) {
        self.presenter = presenter
        self.music = music
        self.angelPrerecording = angelPrerecording
        self.cinematicWorld = cinematicWorld
        self.deviceTransformProvider = deviceTransformProvider
        angelPrerecording.onCompleted = { [weak self] runID, succeeded in
            Task { @MainActor in
                await self?.angelPrerecordingCompleted(
                    runID: runID,
                    succeeded: succeeded
                )
            }
        }
    }

    func bind(blackout: ImmersiveBlackoutController) {
        self.blackout = blackout
    }

    func update(deltaTime: TimeInterval) {
        presenter.updateAngelFloatMotion(deltaTime: deltaTime)
    }

    func start(_ request: Chapter03LightTunnelRequest) async throws {
        await cancel(reason: "replacement", releasePresentation: true)
        guard let blackout else {
            throw StoryTitleCardError.missingPresentationOwner
        }
        try await StoryInteractionArbiter.shared.requireCurrent(
            request.interactionLease
        )
        try blackout.requireFullBlackOwnership(
            requestID: request.blackoutRequestID
        )
        guard let originFromDevice = deviceTransformProvider() else {
            throw Chapter03Error.trackedDeviceUnavailable
        }
        let definition = request.resolvedDefinition.definition
        try definition.validate()

        state = .preparingTunnel(request.chapterRunID)
        do {
            try await presenter.prepare(
                runID: request.chapterRunID,
                originFromDevice: originFromDevice,
                definition: definition.visual
            )
            if let resolvedAngel = request.resolvedDefinition.angelPrerecording {
                guard let emitter = presenter.angelAudioEmitter else {
                    throw Chapter03Error.angelPrerecordingInvalid(
                        "portal Angel emitter was not installed"
                    )
                }
                try await angelPrerecording.prepare(
                    runID: request.chapterRunID,
                    audioURL: resolvedAngel.audioURL,
                    emitter: emitter,
                    gainDB: resolvedAngel.descriptor.gainDB
                )
            }
            let stream = try await music.prepareAndPlay(
                runID: request.chapterRunID,
                resourceURL: request.resolvedDefinition.musicURL,
                definition: definition.music
            )
            activeRequest = request
            portalArrivalLogged = false
            musicActuallyCompleted = false
            angelPrerecordingStarted = false
            angelPrerecordingActuallyCompleted = false
            isFinishing = false
            state = .portalApproaching(request.chapterRunID)
            eventTask = Task { @MainActor [weak self] in
                do {
                    for try await event in stream {
                        try await self?.handle(event, request: request)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    await self?.fail(error, runID: request.chapterRunID)
                }
            }
            print(
                "[Chapter03LightTunnel] started runID=\(request.chapterRunID.uuidString) " +
                    "blackoutRequestID=\(request.blackoutRequestID.uuidString) " +
                    "originColumnW=\(originFromDevice.columns.3)"
            )
        } catch {
            angelPrerecording.stop(reason: "chapter03PreparationFailed")
            presenter.remove(
                runID: request.chapterRunID,
                reason: "musicPreparationFailed"
            )
            throw error
        }
    }

    func cancel(reason: String, releasePresentation: Bool = true) async {
        eventTask?.cancel()
        eventTask = nil
        guard let request = activeRequest else {
            angelPrerecording.stop(reason: reason)
            isFinishing = false
            if releasePresentation {
                presenter.remove(runID: nil, reason: reason)
            }
            state = .cancelled
            return
        }
        activeRequest = nil
        isFinishing = false
        angelPrerecording.stop(reason: reason)
        await music.stop(runID: request.chapterRunID, reason: reason)
        if releasePresentation {
            presenter.remove(runID: request.chapterRunID, reason: reason)
        }
        state = .cancelled
    }

    func releaseReport() async -> Chapter03LightTunnelReleaseReport {
        let musicPlayers = await music.activePlayerCount
        let musicObservers = await music.activeTimeObserverCount
        let cinematicReleased: Bool
        if case .chapter03LightTunnel = cinematicWorld.owner {
            cinematicReleased = false
        } else {
            cinematicReleased = true
        }
        return Chapter03LightTunnelReleaseReport(
            rootEntityCount: presenter.rootEntityCount,
            modelEntityCount: presenter.modelEntityCount,
            activeMusicPlayerCount: musicPlayers,
            activeMusicTimeObserverCount: musicObservers,
            activeAngelPlaybackControllerCount:
                angelPrerecording.activePlaybackControllerCount,
            activeAngelResourceCount: presenter.angelResourceCount,
            activeTaskCount: eventTask == nil ? 0 : 1,
            cinematicOwnerReleased: cinematicReleased
        )
    }

    private func handle(
        _ event: Chapter03LightTunnelMusicController.Event,
        request: Chapter03LightTunnelRequest
    ) async throws {
        guard activeRequest?.chapterRunID == request.chapterRunID else {
            throw Chapter03Error.staleRun
        }
        switch event {
        case .prepared(let duration):
            print("[Chapter03Music] prepared duration=\(duration)")
        case .started:
            state = .portalApproaching(request.chapterRunID)
        case .mediaTime(let seconds, let duration):
            try presenter.update(
                runID: request.chapterRunID,
                mediaTimeSeconds: seconds,
                durationSeconds: duration,
                definition: request.resolvedDefinition.definition
            )
            let approachDuration = request.resolvedDefinition
                .definition.visual.approachDurationSeconds
            if !portalArrivalLogged, seconds >= approachDuration {
                portalArrivalLogged = true
                state = .portalArrived(request.chapterRunID)
                print(
                    "[Chapter03LightTunnel] circular portal arrived " +
                        "mediaTime=\(seconds) distanceMeters=3.048"
                )
            }
            try await startAngelPrerecordingIfNeeded(
                mediaTimeSeconds: seconds,
                request: request
            )
        case .completed:
            musicActuallyCompleted = true
            state = .drainingAuthoredMedia(request.chapterRunID)
            try await finishIfReady(request)
        case .failed(let message):
            throw Chapter03Error.musicPlaybackFailed(message)
        }
    }

    private func startAngelPrerecordingIfNeeded(
        mediaTimeSeconds: Double,
        request: Chapter03LightTunnelRequest
    ) async throws {
        guard !angelPrerecordingStarted,
              let resolved = request.resolvedDefinition.angelPrerecording,
              mediaTimeSeconds >= resolved.startMediaTimeSeconds else {
            return
        }
        try await music.setGainDB(
            resolved.definition.musicDuckGainDB,
            rampSeconds: resolved.definition.duckAttackSeconds,
            runID: request.chapterRunID
        )
        try angelPrerecording.play(runID: request.chapterRunID)
        angelPrerecordingStarted = true
        print(
            """
            [Chapter03AngelPR] portal-arrival playback triggered
              musicMediaTimeSeconds: \(mediaTimeSeconds)
              scheduledMediaTimeSeconds: \(resolved.startMediaTimeSeconds)
              musicDuckGainDB: \(resolved.definition.musicDuckGainDB)
              expectedMusicEndSeconds: \(request.resolvedDefinition.musicDurationSeconds)
            """
        )
    }

    private func angelPrerecordingCompleted(
        runID: UUID,
        succeeded: Bool
    ) async {
        guard let request = activeRequest,
              request.chapterRunID == runID else { return }
        guard succeeded else {
            await fail(
                Chapter03Error.angelPrerecordingInvalid(
                    "actual playback did not complete successfully"
                ),
                runID: runID
            )
            return
        }
        angelPrerecordingActuallyCompleted = true
        do {
            try await music.setGainDB(
                request.resolvedDefinition.definition.music.gainDB,
                rampSeconds: request.resolvedDefinition
                    .definition.angelPrerecording?.duckReleaseSeconds ?? 0,
                runID: runID
            )
            print(
                "[Chapter03AngelPR] actual completion restored music " +
                    "runID=\(runID.uuidString) " +
                    "gainDB=\(request.resolvedDefinition.definition.music.gainDB)"
            )
            try await finishIfReady(request)
        } catch {
            await fail(error, runID: runID)
        }
    }

    private func finishIfReady(
        _ request: Chapter03LightTunnelRequest
    ) async throws {
        guard musicActuallyCompleted else { return }
        if request.resolvedDefinition.angelPrerecording != nil {
            guard angelPrerecordingStarted,
                  angelPrerecordingActuallyCompleted else {
                print(
                    "[Chapter03LightTunnel] music completed; awaiting Angel PR actual completion"
                )
                return
            }
        }
        guard !isFinishing else { return }
        isFinishing = true
        try await ContinuousClock().sleep(for: .seconds(2))
        try await presenter.fadeOutAndRemove(runID: request.chapterRunID)
        angelPrerecording.stop(reason: "actualCompletionDrained")
        await music.stop(
            runID: request.chapterRunID,
            reason: "actualCompletionDrained"
        )
        activeRequest = nil
        eventTask = nil
        let event = Chapter03LightTunnelCompletedEvent(
            chapterRunID: request.chapterRunID,
            completionEventID: UUID(),
            musicActuallyCompleted: true,
            angelPrerecordingWasConfigured:
                request.resolvedDefinition.definition.angelPrerecording != nil,
            angelPrerecordingWasStarted: angelPrerecordingStarted,
            angelPrerecordingActuallyCompleted:
                angelPrerecordingActuallyCompleted,
            interactionLease: request.interactionLease,
            blackoutRequestID: request.blackoutRequestID
        )
        await onCompleted?(event)
    }

    private func fail(_ error: Error, runID: UUID) async {
        guard activeRequest?.chapterRunID == runID else { return }
        await cancel(reason: "failure.\(error.localizedDescription)")
        state = .failed(runID, error.localizedDescription)
        await onFailed?(runID, error)
    }
}
