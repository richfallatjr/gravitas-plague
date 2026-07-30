import Foundation

protocol TuringRollingBenchRadioBedControlling: Sendable {
    func prepareResources() async throws
    func install(
        endpoint: any TuringAudioPlaybackEndpoint
    ) async
    func beginSession(ownerID: String) async throws
    func playEmergencyCue(ownerID: String) async throws
    func endSession(ownerID: String, reason: String) async
    func reset(reason: String) async
    func unload(reason: String) async
}

actor TuringRollingBenchRadioBedActor:
    TuringRollingBenchRadioBedControlling
{
    static let shared = TuringRollingBenchRadioBedActor()

    private struct Assets: Sendable {
        let ambientStaticURL: URL
        let cueURL: URL
    }

    private let loader: TuringRealityAudioResourceLoader
    private var endpoint: (any TuringAudioPlaybackEndpoint)?
    private var assets: Assets?
    private var activeOwnerID: String?
    private var ambientStaticHandle: TuringAudioPlaybackHandle?
    private var cueHandle: TuringAudioPlaybackHandle?
    private var eventTask: Task<Void, Never>?
    private var cueWaiters:
        [UUID: CheckedContinuation<Void, Error>] = [:]
    private var completedCueRequestIDs = Set<UUID>()
    private var failedCueRequests: [UUID: String] = [:]

    init(
        loader: TuringRealityAudioResourceLoader = .shared
    ) {
        self.loader = loader
    }

    func prepareResources() async throws {
        let resolved = try resolveAssets()
        _ = try await loader.load(
            fileURL: resolved.ambientStaticURL,
            shouldLoop: true,
            cachePolicy: .bundled
        )
        _ = try await loader.load(
            fileURL: resolved.cueURL,
            shouldLoop: false,
            cachePolicy: .bundled
        )
        assets = resolved
        print("[TuringCrankRadioCue] resources prepared off MainActor")
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
        guard endpoint != nil,
              assets != nil else {
            throw TuringRuntimeError.invalidConfig(
                "Crank-radio audio bed is not prepared and installed."
            )
        }
        if activeOwnerID == ownerID {
            if ambientStaticHandle == nil {
                try await startAmbientStatic(ownerID: ownerID)
            }
            return
        }
        guard activeOwnerID == nil else {
            throw TuringRuntimeError.invalidConfig(
                "Crank-radio bed belongs to \(activeOwnerID ?? "unknown")."
            )
        }

        activeOwnerID = ownerID
        do {
            try await startAmbientStatic(ownerID: ownerID)
        } catch {
            activeOwnerID = nil
            throw error
        }
        print("""
        [TuringCrankRadioBed] session started
          ownerID: \(ownerID)
          continuousStaticOwned: true
          ambientStaticGainDB: \(TuringRollingBenchTuning.ambientStaticGainDB)
          overlapsTuningCuePRAndGeneratedSpeech: true
        """)
    }

    func playEmergencyCue(ownerID: String) async throws {
        guard activeOwnerID == ownerID,
              let endpoint,
              let assets else {
            throw TuringRuntimeError.invalidConfig(
                "Crank-radio cue requested without the active session."
            )
        }

        if let cueHandle {
            await endpoint.stop(
                cueHandle,
                reason: "replaceEmergencyCue"
            )
            self.cueHandle = nil
        }

        let handle = try await endpoint.play(
            request(
                ownerID: ownerID,
                fileURL: assets.cueURL,
                kind: .radioCue,
                label: "crankRadioEmergencyCue",
                gainDB:
                    Float(
                        TuringRollingBenchTuning.cueGainDB
                    ),
                loops: false
            )
        )
        cueHandle = handle

        try await withCheckedThrowingContinuation {
            continuation in
            if completedCueRequestIDs.remove(
                handle.requestID
            ) != nil {
                continuation.resume()
            } else if let message =
                failedCueRequests.removeValue(
                    forKey: handle.requestID
                ) {
                continuation.resume(
                    throwing:
                        TuringRuntimeError.invalidConfig(
                            message
                        )
                )
            } else {
                cueWaiters[handle.requestID] =
                    continuation
            }
        }
    }

    func endSession(
        ownerID: String,
        reason: String
    ) async {
        guard activeOwnerID == ownerID else {
            return
        }
        await stopOwnedHandles(reason: reason)
        activeOwnerID = nil
        finishCueWaiters(throwing: CancellationError())
        print("""
        [TuringCrankRadioCue] session ended
          ownerID: \(ownerID)
          reason: \(reason)
        """)
    }

    func reset(reason: String) async {
        if let ownerID = activeOwnerID {
            await endSession(
                ownerID: ownerID,
                reason: reason
            )
        } else {
            await stopOwnedHandles(reason: reason)
        }
        eventTask?.cancel()
        eventTask = nil
        endpoint = nil
        completedCueRequestIDs.removeAll(
            keepingCapacity: false
        )
        failedCueRequests.removeAll(
            keepingCapacity: false
        )
    }

    func unload(reason: String) async {
        await reset(reason: reason)
        assets = nil
    }

    private func received(
        _ event: TuringAudioPlaybackEvent
    ) async {
        switch event {
        case .completed(
            let handle,
            let successfully
        ):
            if ambientStaticHandle == handle {
                ambientStaticHandle = nil
                guard successfully,
                      let ownerID = activeOwnerID else {
                    return
                }
                do {
                    try await startAmbientStatic(
                        ownerID: ownerID
                    )
                    print("""
                    [TuringCrankRadioBed] ambient static restarted
                      ownerID: \(ownerID)
                      reason: unexpectedLoopCompletion
                    """)
                } catch {
                    print("""
                    [TuringCrankRadioBed] ambient static restart failed
                      ownerID: \(ownerID)
                      error: \(error.localizedDescription)
                    """)
                }
                return
            }
            guard cueHandle == handle else {
                return
            }
            cueHandle = nil
            if let waiter =
                cueWaiters.removeValue(
                    forKey: handle.requestID
                ) {
                if successfully {
                    waiter.resume()
                } else {
                    waiter.resume(
                        throwing:
                            TuringRuntimeError.invalidConfig(
                                "Crank-radio emergency cue playback failed."
                            )
                    )
                }
            } else if successfully {
                completedCueRequestIDs.insert(
                    handle.requestID
                )
            } else {
                failedCueRequests[handle.requestID] =
                    "Crank-radio emergency cue playback failed."
            }

        case .cancelled(let handle, _):
            if ambientStaticHandle == handle {
                ambientStaticHandle = nil
                return
            }
            guard cueHandle == handle else {
                return
            }
            cueHandle = nil
            cueWaiters.removeValue(
                forKey: handle.requestID
            )?.resume(throwing: CancellationError())

        case .failed(
            let requestID,
            _,
            let message
        ):
            if ambientStaticHandle?.requestID ==
                requestID {
                ambientStaticHandle = nil
                print("""
                [TuringCrankRadioBed] ambient static failed
                  ownerID: \(activeOwnerID ?? "none")
                  error: \(message)
                """)
                return
            }
            guard cueHandle?.requestID == requestID else {
                return
            }
            cueHandle = nil
            if let waiter =
                cueWaiters.removeValue(
                    forKey: requestID
                ) {
                waiter.resume(
                    throwing:
                        TuringRuntimeError.invalidConfig(
                            message
                        )
                )
            } else {
                failedCueRequests[requestID] = message
            }

        case .started:
            break
        }
    }

    private func stopOwnedHandles(
        reason: String
    ) async {
        guard let endpoint else {
            ambientStaticHandle = nil
            cueHandle = nil
            return
        }
        let handles = [
            ambientStaticHandle,
            cueHandle
        ].compactMap { $0 }
        ambientStaticHandle = nil
        cueHandle = nil
        for handle in handles {
            await endpoint.stop(
                handle,
                reason: reason
            )
        }
    }

    private func startAmbientStatic(
        ownerID: String
    ) async throws {
        guard ambientStaticHandle == nil,
              let endpoint,
              let assets else {
            return
        }
        let handle = try await endpoint.play(
            request(
                ownerID: ownerID,
                fileURL:
                    assets.ambientStaticURL,
                kind: .ambientStatic,
                label:
                    "crankRadioAmbientStatic",
                gainDB:
                    Float(
                        TuringRollingBenchTuning
                            .ambientStaticGainDB
                    ),
                loops: true
            )
        )
        ambientStaticHandle = handle
        print("""
        [TuringCrankRadioBed] ambient static started
          ownerID: \(ownerID)
          handleID: \(handle.id.uuidString)
          file: \(assets.ambientStaticURL.lastPathComponent)
          gainDB: \(TuringRollingBenchTuning.ambientStaticGainDB)
          shouldLoop: true
        """)
    }

    private func finishCueWaiters(
        throwing error: Error
    ) {
        let waiters = cueWaiters.values
        cueWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func request(
        ownerID: String,
        fileURL: URL,
        kind: TuringAudioClipKind,
        label: String,
        gainDB: Float,
        loops: Bool
    ) -> TuringAudioPlaybackRequest {
        .init(
            requestID: UUID(),
            runID: ownerID,
            fileURL: fileURL,
            kind: kind,
            route: .rollingBenchRadio,
            label: label,
            gainDB: gainDB,
            shouldLoop: loops,
            cachePolicy: .bundled
        )
    }

    private func resolveAssets() throws -> Assets {
        try Assets(
            ambientStaticURL:
                requireResource(
                    name: "Narrow-band-analog",
                    ext: "wav"
                ),
            cueURL:
                requireResource(
                    name: "emergency-broadcast-alert-data-burst",
                    ext: "mp3"
                )
        )
    }

    private func requireResource(
        name: String,
        ext: String
    ) throws -> URL {
        let url = Bundle.main.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "Turing/Audio/rolling-bench"
        ) ?? Bundle.main.url(
            forResource: name,
            withExtension: ext
        )
        guard let url else {
            throw TuringRuntimeError.invalidConfig(
                "Missing rolling-bench radio asset: \(name).\(ext)"
            )
        }
        return url
    }
}
