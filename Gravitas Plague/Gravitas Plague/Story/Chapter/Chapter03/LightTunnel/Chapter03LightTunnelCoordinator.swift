import Foundation
import simd

@MainActor
final class Chapter03LightTunnelCoordinator {
    private let presenter: Chapter03LightTunnelPresenter
    private let music: Chapter03LightTunnelMusicController
    private let cinematicWorld: CinematicWorldPresentationCoordinator
    private let deviceTransformProvider: () -> simd_float4x4?
    private weak var blackout: ImmersiveBlackoutController?

    private(set) var state: Chapter03State = .idle
    private var activeRequest: Chapter03LightTunnelRequest?
    private var eventTask: Task<Void, Never>?
    private var portalArrivalLogged = false
    private var musicActuallyCompleted = false

    var onCompleted: ((Chapter03LightTunnelCompletedEvent) async -> Void)?
    var onFailed: ((UUID, Error) async -> Void)?

    init(
        presenter: Chapter03LightTunnelPresenter,
        music: Chapter03LightTunnelMusicController,
        cinematicWorld: CinematicWorldPresentationCoordinator,
        deviceTransformProvider: @escaping () -> simd_float4x4?
    ) {
        self.presenter = presenter
        self.music = music
        self.cinematicWorld = cinematicWorld
        self.deviceTransformProvider = deviceTransformProvider
    }

    func bind(blackout: ImmersiveBlackoutController) {
        self.blackout = blackout
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
            let stream = try await music.prepareAndPlay(
                runID: request.chapterRunID,
                resourceURL: request.resolvedDefinition.musicURL,
                definition: definition.music
            )
            activeRequest = request
            portalArrivalLogged = false
            musicActuallyCompleted = false
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
            if releasePresentation {
                presenter.remove(runID: nil, reason: reason)
            }
            state = .cancelled
            return
        }
        activeRequest = nil
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
            activeAngelPlaybackControllerCount: 0,
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
        case .completed:
            musicActuallyCompleted = true
            state = .drainingAuthoredMedia(request.chapterRunID)
            try await finish(request)
        case .failed(let message):
            throw Chapter03Error.musicPlaybackFailed(message)
        }
    }

    private func finish(_ request: Chapter03LightTunnelRequest) async throws {
        guard musicActuallyCompleted else {
            throw Chapter03Error.musicPlaybackFailed("actual completion was not observed")
        }
        try await ContinuousClock().sleep(for: .seconds(2))
        try await presenter.fadeOutAndRemove(runID: request.chapterRunID)
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
            angelPrerecordingWasStarted: false,
            angelPrerecordingActuallyCompleted: false,
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
