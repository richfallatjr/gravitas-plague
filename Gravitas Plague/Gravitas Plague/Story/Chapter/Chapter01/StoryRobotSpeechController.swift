import Foundation
import RealityKit

@MainActor
enum Chapter01RobotAudioRoute {
    private static weak var emitter: Entity?
    private static var endpoint: TuringSpatialAudioEndpoint?

    static func install(on emitter: Entity) {
        clear(reason: "replaceRobotAudioEmitter")
        self.emitter = emitter
        endpoint = TuringSpatialAudioEndpointFactory.make(emitter: emitter)
        print("[Chapter01RobotAudio] installed emitter=\(emitter.name)")
    }

    static func requireEndpoint() throws -> TuringSpatialAudioEndpoint {
        guard let emitter,
              emitter.parent != nil,
              let endpoint else {
            throw Chapter01RobotError.audioEndpointMissing
        }
        return endpoint
    }

    static func clear(reason: String) {
        if let endpoint {
            Task { await endpoint.stopAll(reason: reason) }
        }
        endpoint = nil
        emitter = nil
    }
}

actor StoryRobotSpeechController {
    private var catalog: Chapter01RobotSpeechCatalog?
    private var endpoint: TuringSpatialAudioEndpoint?
    private var eventTask: Task<Void, Never>?
    private var activeEncounterID: UUID?
    private var activeCue: Chapter01RobotSpeechCue?
    private var activeFilename: String?
    private var activeHandle: TuringAudioPlaybackHandle?
    private var completion: CheckedContinuation<Void, Error>?

    func prepare(catalog: Chapter01RobotSpeechCatalog) throws {
        try catalog.validate()
        for cue in catalog.cues {
            let url = try Chapter01RobotResourceResolver.requirePrerecording(cue.audioFile)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard FileManager.default.isReadableFile(atPath: url.path),
                  (values.fileSize ?? 0) > 0 else {
                throw Chapter01RobotError.speechNotPrepared(cue.cueID)
            }
        }
        self.catalog = catalog
    }

    func install(endpoint: TuringSpatialAudioEndpoint) async {
        await stopActive(reason: "replaceRobotSpeechEndpoint")
        eventTask?.cancel()
        self.endpoint = endpoint
        let stream = await endpoint.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { return }
                await self?.handle(event)
            }
        }
    }

    func play(
        _ cue: Chapter01RobotSpeechCue,
        encounterID: UUID
    ) async throws {
        guard activeHandle == nil, completion == nil else {
            throw Chapter01RobotError.speechAlreadyActive
        }
        guard let endpoint,
              let descriptor = catalog?.descriptor(for: cue) else {
            throw Chapter01RobotError.speechNotPrepared(cue)
        }
        let url = try Chapter01RobotResourceResolver.requirePrerecording(descriptor.audioFile)
        let handle = try await endpoint.play(
            TuringAudioPlaybackRequest(
                requestID: UUID(),
                runID: encounterID.uuidString,
                fileURL: url,
                kind: .storyRobotSpeech,
                route: .storyRobot,
                label: cue.rawValue,
                gainDB: descriptor.gainDB,
                shouldLoop: false,
                cachePolicy: .transient
            )
        )
        activeEncounterID = encounterID
        activeCue = cue
        activeFilename = descriptor.audioFile
        activeHandle = handle
        print("""
        [Chapter01Robot] PR
          cueID: \(cue.rawValue)
          file: \(descriptor.audioFile)
          handleID: \(handle.id.uuidString)
          actualStarted: true
          actualCompleted: false
        """)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
            }
        } onCancel: {
            Task { await self.stop(encounterID: encounterID, reason: "speechTaskCancelled") }
        }
    }

    func stop(encounterID: UUID, reason: String) async {
        guard activeEncounterID == encounterID else { return }
        await stopActive(reason: reason)
    }

    func reset(reason: String) async {
        await stopActive(reason: reason)
        eventTask?.cancel()
        eventTask = nil
        endpoint = nil
        catalog = nil
    }

    func activeHandleCount() -> Int { activeHandle == nil ? 0 : 1 }

    private func stopActive(reason: String) async {
        let handle = activeHandle
        finish(.failure(CancellationError()))
        if let handle, let endpoint {
            await endpoint.stop(handle, reason: reason)
        }
    }

    private func handle(_ event: TuringAudioPlaybackEvent) {
        switch event {
        case .completed(let handle, let successfully) where handle == activeHandle:
            logTerminalEvent(
                handle: handle,
                actualCompleted: successfully,
                result: successfully ? "completed" : "completionFailed"
            )
            finish(successfully ? .success(()) : .failure(Chapter01RobotError.speechPlaybackFailed))
        case .cancelled(let handle, _) where handle == activeHandle:
            logTerminalEvent(handle: handle, actualCompleted: false, result: "cancelled")
            finish(.failure(CancellationError()))
        case .failed(let requestID, _, let message) where activeHandle?.requestID == requestID:
            if let activeHandle {
                logTerminalEvent(handle: activeHandle, actualCompleted: false, result: "failed")
            }
            finish(.failure(Chapter01RobotError.audioFailure(message)))
        default:
            break
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        let continuation = completion
        completion = nil
        activeHandle = nil
        activeEncounterID = nil
        activeCue = nil
        activeFilename = nil
        switch result {
        case .success:
            continuation?.resume()
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    private func logTerminalEvent(
        handle: TuringAudioPlaybackHandle,
        actualCompleted: Bool,
        result: String
    ) {
        print("""
        [Chapter01Robot] PR
          cueID: \(activeCue?.rawValue ?? "unknown")
          file: \(activeFilename ?? "unknown")
          handleID: \(handle.id.uuidString)
          actualStarted: true
          actualCompleted: \(actualCompleted)
          result: \(result)
        """)
    }
}
