import Foundation

actor TuringRollingBenchRadioActor {
    private struct Assets: Sendable {
        let staticURL: URL
        let cueURL: URL
        let broadcastURL: URL
    }

    private let loader: TuringRealityAudioResourceLoader
    private var endpoint: (any TuringAudioPlaybackEndpoint)?
    private var assets: Assets?
    private var eventTask: Task<Void, Never>?
    private var repeatDelayTask: Task<Void, Never>?
    private var cycleID = UUID()
    private var isPlaying = false
    private var staticHandle: TuringAudioPlaybackHandle?
    private var cueHandle: TuringAudioPlaybackHandle?
    private var broadcastHandle: TuringAudioPlaybackHandle?

    init(loader: TuringRealityAudioResourceLoader = .shared) {
        self.loader = loader
    }

    func prepareResources() async throws {
        let assets = try resolveAssets()
        _ = try await loader.load(
            fileURL: assets.staticURL,
            shouldLoop: true,
            cachePolicy: .bundled
        )
        _ = try await loader.load(
            fileURL: assets.cueURL,
            shouldLoop: false,
            cachePolicy: .bundled
        )
        _ = try await loader.load(
            fileURL: assets.broadcastURL,
            shouldLoop: false,
            cachePolicy: .bundled
        )
        self.assets = assets
        print("[TuringRollingBenchRadio] resources prepared off MainActor")
    }

    func install(endpoint: any TuringAudioPlaybackEndpoint) async {
        await stop(reason: "install")
        eventTask?.cancel()
        self.endpoint = endpoint
        let stream = await endpoint.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard Task.isCancelled == false else { return }
                await self?.received(event)
            }
        }
    }

    func play(source: String) async throws {
        guard isPlaying == false, let endpoint, let assets else { return }
        await stopOwnedHandles(reason: "newPlay")
        cycleID = UUID()
        isPlaying = true
        let cycle = cycleID
        staticHandle = try await endpoint.play(
            request(
                fileURL: assets.staticURL,
                kind: .ambientStatic,
                label: "rollingBenchStatic",
                gainDB: Float(TuringRollingBenchTuning.staticGainDB),
                loops: true,
                cycleID: cycle
            )
        )
        try await startCue(cycleID: cycle)
        print("[TuringRollingBenchRadio] cycle started cycleID=\(cycle.uuidString) source=\(source)")
    }

    func pause(source: String) async {
        await stop(reason: "pause.\(source)")
    }

    func reset(reason: String) async {
        await stop(reason: "reset.\(reason)")
        eventTask?.cancel()
        eventTask = nil
        endpoint = nil
    }

    func unload(reason: String) async {
        await reset(reason: reason)
        assets = nil
    }

    private func startCue(cycleID: UUID) async throws {
        guard isPlaying, self.cycleID == cycleID,
              let endpoint, let assets else { return }
        cueHandle = try await endpoint.play(
            request(
                fileURL: assets.cueURL,
                kind: .radioCue,
                label: "emergencyBeep",
                gainDB: Float(TuringRollingBenchTuning.cueGainDB),
                loops: false,
                cycleID: cycleID
            )
        )
    }

    private func startBroadcast(cycleID: UUID) async throws {
        guard isPlaying, self.cycleID == cycleID,
              let endpoint, let assets else { return }
        broadcastHandle = try await endpoint.play(
            request(
                fileURL: assets.broadcastURL,
                kind: .radioBroadcast,
                label: "emergencyBroadcast",
                gainDB: Float(TuringRollingBenchTuning.broadcastGainDB),
                loops: false,
                cycleID: cycleID
            )
        )
    }

    private func received(_ event: TuringAudioPlaybackEvent) async {
        guard case .completed(let handle, let successfully) = event,
              successfully else { return }
        let activeCycle = cycleID
        if cueHandle == handle {
            cueHandle = nil
            guard isPlaying else { return }
            do {
                try await startBroadcast(cycleID: activeCycle)
            } catch {
                await stop(reason: "broadcastStartFailed")
            }
            return
        }
        if broadcastHandle == handle {
            broadcastHandle = nil
            guard isPlaying else { return }
            scheduleRepeat(cycleID: activeCycle)
        }
    }

    private func scheduleRepeat(cycleID: UUID) {
        repeatDelayTask?.cancel()
        repeatDelayTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: TuringRollingBenchTuning.broadcastRepeatDelay
                )
            } catch {
                return
            }
            await self?.repeatDelayCompleted(cycleID: cycleID)
        }
    }

    private func repeatDelayCompleted(cycleID: UUID) async {
        guard isPlaying, self.cycleID == cycleID else { return }
        repeatDelayTask = nil
        do {
            try await startCue(cycleID: cycleID)
        } catch {
            await stop(reason: "repeatCueStartFailed")
        }
    }

    private func stop(reason: String) async {
        cycleID = UUID()
        isPlaying = false
        repeatDelayTask?.cancel()
        repeatDelayTask = nil
        await stopOwnedHandles(reason: reason)
    }

    private func stopOwnedHandles(reason: String) async {
        guard let endpoint else {
            staticHandle = nil
            cueHandle = nil
            broadcastHandle = nil
            return
        }
        let handles = [staticHandle, cueHandle, broadcastHandle].compactMap { $0 }
        staticHandle = nil
        cueHandle = nil
        broadcastHandle = nil
        for handle in handles {
            await endpoint.stop(handle, reason: reason)
        }
    }

    private func request(
        fileURL: URL,
        kind: TuringAudioClipKind,
        label: String,
        gainDB: Float,
        loops: Bool,
        cycleID: UUID
    ) -> TuringAudioPlaybackRequest {
        .init(
            requestID: UUID(),
            runID: "rollingBench.\(cycleID.uuidString)",
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
            staticURL: requireResource(name: "Narrow-band-analog", ext: "wav"),
            cueURL: requireResource(name: "Create_a_short_emerg_beeping", ext: "wav"),
            broadcastURL: requireResource(name: "EmergencyBroadcast", ext: "mp3")
        )
    }

    private func requireResource(name: String, ext: String) throws -> URL {
        let url = Bundle.main.url(
            forResource: name,
            withExtension: ext,
            subdirectory: "Turing/Audio/rolling-bench"
        ) ?? Bundle.main.url(forResource: name, withExtension: ext)
        guard let url else {
            throw TuringRuntimeError.invalidConfig(
                "Missing rolling-bench radio asset: \(name).\(ext)"
            )
        }
        return url
    }
}
