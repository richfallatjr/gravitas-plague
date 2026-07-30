import Foundation

protocol TuringHamReceiverBedControlling: Sendable {
    func prepareResources() async throws
    func install(
        endpoint: any TuringAudioPlaybackEndpoint
    ) async
    func beginSession(ownerID: String) async throws
    func endSession(ownerID: String, reason: String) async
    func reset(reason: String) async
    func unload(reason: String) async
}

actor TuringHamReceiverBedActor:
    TuringHamReceiverBedControlling
{
    static let shared = TuringHamReceiverBedActor()

    private let ambientGainDB: Float = -15
    private var endpoint: (any TuringAudioPlaybackEndpoint)?
    private var ambientURL: URL?
    private var activeOwnerID: String?
    private var ambientHandle: TuringAudioPlaybackHandle?
    private var eventTask: Task<Void, Never>?

    func prepareResources() async throws {
        ambientURL = optionalAmbientURL()
        print("""
        [TuringHamReceiverBed] resources prepared
          ambientConfigured: \(ambientURL != nil)
          ambientFile: \(ambientURL?.lastPathComponent ?? "none")
          ambientGainDB: \(ambientGainDB)
        """)
    }

    func install(
        endpoint: any TuringAudioPlaybackEndpoint
    ) async {
        await reset(reason: "replaceEndpoint")
        self.endpoint = endpoint
        let stream = await endpoint.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard Task.isCancelled == false else {
                    return
                }
                await self?.received(event)
            }
        }
    }

    func beginSession(ownerID: String) async throws {
        guard endpoint != nil else {
            throw TuringRuntimeError.invalidConfig(
                "Ham-receiver audio endpoint is not installed."
            )
        }
        if activeOwnerID == ownerID {
            if ambientURL != nil,
               ambientHandle == nil {
                try await startAmbient(ownerID: ownerID)
            }
            return
        }
        guard activeOwnerID == nil else {
            throw TuringRuntimeError.invalidConfig(
                "Ham-receiver bed belongs to \(activeOwnerID ?? "unknown")."
            )
        }

        activeOwnerID = ownerID
        do {
            try await startAmbient(ownerID: ownerID)
        } catch {
            activeOwnerID = nil
            throw error
        }
        print("""
        [TuringHamReceiverBed] session started
          ownerID: \(ownerID)
          ambientConfigured: \(ambientURL != nil)
          ambientUnderTuningPRAndGenerated: true
        """)
    }

    func endSession(
        ownerID: String,
        reason: String
    ) async {
        guard activeOwnerID == ownerID else {
            return
        }
        let handle = ambientHandle
        ambientHandle = nil
        activeOwnerID = nil
        if let handle, let endpoint {
            await endpoint.stop(handle, reason: reason)
        }
        print("""
        [TuringHamReceiverBed] session ended
          ownerID: \(ownerID)
          reason: \(reason)
        """)
    }

    func reset(reason: String) async {
        if let activeOwnerID {
            await endSession(
                ownerID: activeOwnerID,
                reason: reason
            )
        } else if let ambientHandle,
                  let endpoint {
            self.ambientHandle = nil
            await endpoint.stop(
                ambientHandle,
                reason: reason
            )
        }
        eventTask?.cancel()
        eventTask = nil
        endpoint = nil
    }

    func unload(reason: String) async {
        await reset(reason: reason)
        ambientURL = nil
    }

    private func startAmbient(
        ownerID: String
    ) async throws {
        guard let ambientURL else {
            return
        }
        guard let endpoint else {
            throw TuringRuntimeError.invalidConfig(
                "Ham-receiver audio endpoint is not installed."
            )
        }
        ambientHandle = try await endpoint.play(
            TuringAudioPlaybackRequest(
                requestID: UUID(),
                runID: ownerID,
                fileURL: ambientURL,
                kind: .hamReceiverAmbient,
                route: .hamReceiver,
                label: ambientURL.lastPathComponent,
                gainDB: ambientGainDB,
                shouldLoop: true,
                cachePolicy: .bundled
            )
        )
    }

    private func received(
        _ event: TuringAudioPlaybackEvent
    ) async {
        switch event {
        case .completed(let handle, let successfully):
            guard ambientHandle == handle else {
                return
            }
            ambientHandle = nil
            guard successfully,
                  let activeOwnerID else {
                return
            }
            do {
                try await startAmbient(
                    ownerID: activeOwnerID
                )
            } catch {
                print("""
                [TuringHamReceiverBed] ambient restart failed
                  ownerID: \(activeOwnerID)
                  error: \(error.localizedDescription)
                """)
            }

        case .cancelled(let handle, _):
            if ambientHandle == handle {
                ambientHandle = nil
            }

        case .failed(let requestID, _, let message):
            guard ambientHandle?.requestID ==
                    requestID else {
                return
            }
            ambientHandle = nil
            print("""
            [TuringHamReceiverBed] ambient failed
              error: \(message)
            """)

        case .started:
            break
        }
    }

    private func optionalAmbientURL() -> URL? {
        let bundle = Bundle.main
        return bundle.url(
            forResource: "Narrow-band-analog",
            withExtension: "wav",
            subdirectory:
                "Turing/Audio/rolling-bench"
        ) ?? bundle.url(
            forResource: "Narrow-band-analog",
            withExtension: "wav"
        )
    }
}
