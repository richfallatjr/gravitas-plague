import Foundation

actor TuringWalkieCommsFXActor {
    private enum State: Equatable {
        case idle
        case opening
        case sendingLeadIn
    }

    private let assetStore = TuringWalkieCommsAssetStore()
    private var endpoint: (any TuringAudioPlaybackEndpoint)?
    private var endpointIdentity: ObjectIdentifier?
    private var eventTask: Task<Void, Never>?
    private var state: State = .idle
    private var randomBurstTask: Task<Void, Never>?
    private var lastBurstURL: URL?
    private var activeBurstHandle: TuringAudioPlaybackHandle?
    private var activeOneShotHandles = Set<TuringAudioPlaybackHandle>()
    private var sendingStaticActive = false

    func install(endpoint newEndpoint: any TuringAudioPlaybackEndpoint) async {
        let identity = ObjectIdentifier(newEndpoint as AnyObject)
        guard endpointIdentity != identity else { return }
        await stopOwnedOneShots(reason: "replaceEndpoint")
        eventTask?.cancel()
        endpoint = newEndpoint
        endpointIdentity = identity
        let stream = await newEndpoint.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard Task.isCancelled == false else { return }
                await self?.received(event)
            }
        }
    }

    func playOpenCommBeforeRecording(reason: String) async {
        state = .opening
        do {
            let url = try assetStore.openCommURL()
            _ = try await playOneShotAndWait(
                fileURL: url,
                label: "open-comm",
                runID: reason
            )
        } catch {
            print("[TuringWalkieComms] open comm unavailable reason=\(reason) error=\(error.localizedDescription)")
        }
        if state == .opening { state = .idle }
    }

    func playScriptedOpenComm(reason: String) async throws {
        _ = try await playOneShotAndWait(
            fileURL: assetStore.openCommURL(),
            label: "open-comm",
            runID: reason
        )
    }

    func playScriptedSendComm(reason: String) async throws {
        _ = try await playOneShotAndWait(
            fileURL: assetStore.sendCommURL(),
            label: "send-comm",
            runID: reason
        )
    }

    func ambientStaticURL() throws -> URL {
        try assetStore.ambientStaticLoopURL()
    }

    func sendingStaticURL() throws -> URL {
        try assetStore.sendingStaticLoopURL()
    }

    func playSendCommAndStartSendingLeadIn(reason: String) async {
        if let url = try? assetStore.sendCommURL() {
            Task { [weak self] in
                _ = try? await self?.playOneShotAndWait(
                    fileURL: url,
                    label: "send-comm",
                    runID: reason
                )
            }
        }
    }

    func beginSendingLeadIn(reason: String) {
        guard state != .sendingLeadIn else { return }
        state = .sendingLeadIn
        sendingStaticActive = true
        startRandomBursts(reason: reason)
    }

    func runFixedDelay(seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(max(0, seconds)))
            return true
        } catch {
            return false
        }
    }

    func stopSendingLeadIn(reason: String) async {
        let wasActive = state == .sendingLeadIn || sendingStaticActive
        randomBurstTask?.cancel()
        randomBurstTask = nil
        if let handle = activeBurstHandle, let endpoint {
            activeBurstHandle = nil
            await endpoint.stop(handle, reason: "sendingLeadInStopped.\(reason)")
        }
        sendingStaticActive = false
        state = .idle
        if wasActive {
            print("[TuringWalkieComms] sending lead-in stopped reason=\(reason)")
        }
    }

    func stopAll(reason: String) async {
        randomBurstTask?.cancel()
        randomBurstTask = nil
        await stopOwnedOneShots(reason: reason)
        sendingStaticActive = false
        state = .idle
    }

    private func startRandomBursts(reason: String) {
        randomBurstTask?.cancel()
        let urls = assetStore.randomBurstURLs()
        guard urls.isEmpty == false else { return }
        randomBurstTask = Task { [weak self] in
            guard let self else { return }
            while Task.isCancelled == false {
                let delay = Double.random(in: 2...7)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
                guard await self.canPlayBurst else { return }
                await self.playBurst(from: urls, reason: reason)
            }
        }
    }

    private var canPlayBurst: Bool {
        state == .sendingLeadIn
    }

    private func playBurst(from urls: [URL], reason: String) async {
        guard let endpoint else { return }
        let candidates = urls.count > 1
            ? urls.filter { $0 != lastBurstURL }
            : urls
        guard let url = candidates.randomElement() ?? urls.first else { return }
        lastBurstURL = url
        do {
            activeBurstHandle = try await endpoint.play(
                request(
                    fileURL: url,
                    label: url.deletingPathExtension().lastPathComponent,
                    runID: reason
                )
            )
        } catch {
            print("[TuringWalkieComms] random burst failed error=\(error.localizedDescription)")
        }
    }

    private func playOneShotAndWait(
        fileURL: URL,
        label: String,
        runID: String
    ) async throws -> TuringAudioPlaybackHandle {
        guard let endpoint else {
            throw TuringWalkieAudioError.playbackStartFailed(label)
        }
        let stream = await endpoint.events()
        let handle = try await endpoint.play(
            request(fileURL: fileURL, label: label, runID: runID)
        )
        activeOneShotHandles.insert(handle)
        for await event in stream {
            switch event {
            case .completed(let completed, let successfully)
                where completed == handle:
                activeOneShotHandles.remove(handle)
                guard successfully else {
                    throw TuringWalkieAudioError.playbackStartFailed(label)
                }
                return handle
            case .cancelled(let cancelled, let reason)
                where cancelled == handle:
                activeOneShotHandles.remove(handle)
                throw TuringRuntimeError.invalidConfig(
                    "Walkie comm \(label) cancelled: \(reason)"
                )
            default:
                continue
            }
        }
        activeOneShotHandles.remove(handle)
        throw TuringRuntimeError.invalidConfig(
            "Walkie comm event stream ended during \(label)."
        )
    }

    private func request(
        fileURL: URL,
        label: String,
        runID: String
    ) -> TuringAudioPlaybackRequest {
        .init(
            requestID: UUID(),
            runID: runID,
            fileURL: fileURL,
            kind: .commSFX,
            route: .storyWalkie,
            label: label,
            gainDB: 0,
            shouldLoop: false,
            cachePolicy: .bundled
        )
    }

    private func received(_ event: TuringAudioPlaybackEvent) {
        guard case .completed(let handle, _) = event,
              activeBurstHandle == handle else { return }
        activeBurstHandle = nil
    }

    private func stopOwnedOneShots(reason: String) async {
        guard let endpoint else {
            activeBurstHandle = nil
            activeOneShotHandles.removeAll(keepingCapacity: false)
            return
        }
        let oneShots = Array(activeOneShotHandles)
        activeOneShotHandles.removeAll(keepingCapacity: false)
        for handle in oneShots {
            await endpoint.stop(handle, reason: reason)
        }
        guard let handle = activeBurstHandle else { return }
        activeBurstHandle = nil
        await endpoint.stop(handle, reason: reason)
    }
}
