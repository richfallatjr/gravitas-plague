import Foundation

@MainActor
final class TuringWalkieCommsFXController {
    static let shared = TuringWalkieCommsFXController()

    private enum State: Equatable {
        case idle
        case opening
        case sendingLeadIn
    }

    private let assetStore = TuringWalkieCommsAssetStore()
    private var state: State = .idle
    private var randomBurstTask: Task<Void, Never>?
    private var lastBurstURL: URL?
    private var activeBurstHandleID: UUID?
    private var sendingStaticActive = false

    private init() {}

    func playOpenCommBeforeRecording(reason: String) async {
        state = .opening

        do {
            let url = try assetStore.openCommURL()
            print("""
            [TuringWalkieComms] open comm started
              reason: \(reason)
              file: \(url.lastPathComponent)
            """)

            _ = try await playOneShotAndWait(
                fileURL: url,
                kind: .commSFX,
                label: "open-comm"
            )

            print("""
            [TuringWalkieComms] open comm finished
              reason: \(reason)
            """)
        } catch {
            print("""
            [TuringWalkieComms] open comm unavailable
              reason: \(reason)
              error: \(error.localizedDescription)
            """)
        }

        if state == .opening {
            state = .idle
        }
    }

    func playScriptedOpenComm(reason: String) async throws {
        let url = try assetStore.openCommURL()
        print("""
        [TuringWalkieComms] scripted open comm started
          reason: \(reason)
          file: \(url.lastPathComponent)
          route: spatialWalkie
        """)
        _ = try await playOneShotAndWait(
            fileURL: url,
            kind: .commSFX,
            label: "open-comm"
        )
        print("""
        [TuringWalkieComms] scripted open comm completed
          reason: \(reason)
          completionSource: AudioPlaybackController.completionHandler
        """)
    }

    func playScriptedSendComm(reason: String) async throws {
        let url = try assetStore.sendCommURL()
        print("""
        [TuringWalkieComms] scripted send comm started
          reason: \(reason)
          file: \(url.lastPathComponent)
          route: spatialWalkie
        """)
        _ = try await playOneShotAndWait(
            fileURL: url,
            kind: .commSFX,
            label: "send-comm"
        )
        print("""
        [TuringWalkieComms] scripted send comm completed
          reason: \(reason)
          completionSource: AudioPlaybackController.completionHandler
        """)
    }

    func playSendCommAndStartSendingLeadIn(reason: String) async {
        do {
            let url = try assetStore.sendCommURL()
            print("""
            [TuringWalkieComms] send comm started
              reason: \(reason)
              file: \(url.lastPathComponent)
            """)

            Task { @MainActor [weak self] in
                _ = try? await self?.playOneShotAndWait(
                    fileURL: url,
                    kind: .commSFX,
                    label: "send-comm"
                )
            }
        } catch {
            print("""
            [TuringWalkieComms] send comm unavailable
              reason: \(reason)
              error: \(error.localizedDescription)
            """)
        }

        await startAmbientWalkieStatic(reason: "conversationVoice.\(reason)")
        await startSendingLeadIn(reason: reason)
    }

    func startResponseLeadInAfterExternalSend(
        reason: String
    ) async {
        // ScriptPoint02 already played send-comm spatially. Start only the
        // existing response lead-in; never replay the chirp.
        await startAmbientWalkieStatic(
            reason: "externalSend.\(reason)"
        )
        await startSendingLeadIn(
            reason: "externalSend.\(reason)"
        )

        print("""
        [TuringWalkieComms] response lead-in started after external send
          reason: \(reason)
          sendCommReplayed: false
          ambientStatic: true
          sendingStatic: true
          randomBursts: true
          stopCondition: firstBigMikePlayback
        """)
    }

    func runFixedResponseLeadInAfterExternalSend(
        reason: String,
        durationSeconds: TimeInterval
    ) async {
        let duration = max(0, durationSeconds)
        let startedAt = Date()

        await startAmbientWalkieStatic(
            reason: "externalSend.\(reason)"
        )
        await startSendingLeadIn(
            reason: "externalSend.\(reason)"
        )

        print("""
        [TuringWalkieComms] fixed response lead-in started
          reason: \(reason)
          requestedSeconds: \(String(format: "%.3f", duration))
          sendCommReplayed: false
          ambientStatic: true
          sendingStatic: true
          randomBursts: true
          stopCondition: fixedDuration
        """)

        do {
            try await Task.sleep(for: .seconds(duration))
        } catch {
            await stopSendingLeadIn(
                reason: "fixedResponseLeadInCancelled.\(reason)"
            )
            print("""
            [TuringWalkieComms] fixed response lead-in cancelled
              reason: \(reason)
              elapsedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(startedAt)))
            """)
            return
        }

        await stopSendingLeadIn(
            reason: "fixedResponseLeadInCompleted.\(reason)"
        )

        print("""
        [TuringWalkieComms] fixed response lead-in completed
          reason: \(reason)
          requestedSeconds: \(String(format: "%.3f", duration))
          elapsedSeconds: \(String(format: "%.3f", Date().timeIntervalSince(startedAt)))
          ambientStaticContinues: true
          sendingStaticStopped: true
          randomBurstsStopped: true
        """)
    }

    func startSendingLeadIn(reason: String) async {
        guard state != .sendingLeadIn else {
            return
        }

        state = .sendingLeadIn
        do {
            let url = try assetStore.sendingStaticLoopURL()
            let routed = await TuringStoryWalkieAudioRoute.startSendingStaticLoop(
                fileURL: url,
                reason: reason
            )
            sendingStaticActive = routed
            if routed {
                print("""
                [TuringWalkieComms] sending static loop started
                  reason: \(reason)
                  file: \(url.lastPathComponent)
                  stopCondition: firstPlaybackOrFirstFiller
                """)
            }
        } catch {
            print("""
            [TuringWalkieComms] sending static loop unavailable
              reason: \(reason)
              error: \(error.localizedDescription)
            """)
        }

        startRandomBursts(reason: reason)
    }

    func stopSendingLeadIn(reason: String) async {
        let wasActive = state == .sendingLeadIn || sendingStaticActive
        randomBurstTask?.cancel()
        randomBurstTask = nil
        if let activeBurstHandleID,
           let clipPlayer = TuringStoryWalkieAudioRoute.makeActiveClipPlayer() {
            clipPlayer.cancel(
                handleID: activeBurstHandleID,
                reason: "sendingLeadInStopped.\(reason)"
            )
            self.activeBurstHandleID = nil
        }
        await TuringStoryWalkieAudioRoute.stopSendingStaticLoop(
            reason: reason
        )
        sendingStaticActive = false

        state = .idle

        if wasActive {
            print("""
            [TuringWalkieComms] sending lead-in stopped
              reason: \(reason)
            """)
        }
    }

    func startAmbientWalkieStatic(reason: String) async {
        do {
            let url = try assetStore.ambientStaticLoopURL()
            let routed = await TuringStoryWalkieAudioRoute
                .startAmbientWalkieStaticLoop(fileURL: url, reason: reason)
            if routed {
                print("""
                [TuringWalkieComms] ambient walkie static started
                  reason: \(reason)
                  file: \(url.lastPathComponent)
                """)
            }
        } catch {
            print("""
            [TuringWalkieComms] ambient walkie static unavailable
              reason: \(reason)
              error: \(error.localizedDescription)
            """)
        }
    }

    func stopAmbientWalkieStatic(reason: String) async {
        await TuringStoryWalkieAudioRoute.stopAmbientWalkieStaticLoop(
            reason: reason
        )
    }

    func stopAll(reason: String) async {
        randomBurstTask?.cancel()
        randomBurstTask = nil
        if let activeBurstHandleID,
           let clipPlayer = TuringStoryWalkieAudioRoute.makeActiveClipPlayer() {
            clipPlayer.cancel(
                handleID: activeBurstHandleID,
                reason: "stopAll.\(reason)"
            )
            self.activeBurstHandleID = nil
        }
        await TuringStoryWalkieAudioRoute.stopSendingStaticLoop(reason: reason)
        await TuringStoryWalkieAudioRoute.stopAmbientWalkieStaticLoop(
            reason: reason
        )
        sendingStaticActive = false
        state = .idle
        print("""
        [TuringWalkieComms] stopped
          reason: \(reason)
        """)
    }

    private func startRandomBursts(reason: String) {
        randomBurstTask?.cancel()
        let urls = assetStore.randomBurstURLs()
        guard urls.isEmpty == false else {
            print("""
            [TuringWalkieComms] random burst disabled
              reason: missingWalkieTalkie01To06
            """)
            return
        }

        randomBurstTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let delay = Double.random(in: 2.0...7.0)
                try? await Task.sleep(
                    nanoseconds: UInt64(delay * 1_000_000_000)
                )
                guard !Task.isCancelled,
                      self.state == .sendingLeadIn else {
                    return
                }

                let url = self.chooseBurstURL(from: urls)
                self.lastBurstURL = url

                print("""
                [TuringWalkieComms] random pre-playback burst started
                  clip: \(url.lastPathComponent)
                  nextWindowSeconds: 2.0...7.0
                """)

                let label = url.deletingPathExtension().lastPathComponent
                self.activeBurstHandleID = try? self.playOneShotNoWait(
                    fileURL: url,
                    kind: .commSFX,
                    label: label,
                    completion: { [weak self] completedID in
                        guard self?.activeBurstHandleID == completedID else {
                            return
                        }
                        self?.activeBurstHandleID = nil
                    }
                )
            }
        }
    }

    private func chooseBurstURL(from urls: [URL]) -> URL {
        guard urls.count > 1,
              let lastBurstURL else {
            return urls.randomElement() ?? urls[0]
        }
        return urls.filter { $0 != lastBurstURL }.randomElement() ?? urls[0]
    }

    private func playOneShotAndWait(
        fileURL: URL,
        kind: TuringWalkieOneShotClipPlayer.ClipKind,
        label: String
    ) async throws -> UUID {
        try await withCheckedThrowingContinuation { continuation in
            do {
                guard let clipPlayer = TuringStoryWalkieAudioRoute
                    .makeActiveClipPlayer() else {
                    continuation.resume(
                        throwing: TuringWalkieAudioError.playbackStartFailed(label)
                    )
                    return
                }

                _ = try clipPlayer.playOneShot(
                    fileURL: fileURL,
                    kind: kind,
                    label: label,
                    completion: { completedID in
                        continuation.resume(returning: completedID)
                    }
                )
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    @discardableResult
    private func playOneShotNoWait(
        fileURL: URL,
        kind: TuringWalkieOneShotClipPlayer.ClipKind,
        label: String,
        completion: @escaping @MainActor (UUID) -> Void
    ) throws -> UUID {
        guard let clipPlayer = TuringStoryWalkieAudioRoute
            .makeActiveClipPlayer() else {
            throw TuringWalkieAudioError.playbackStartFailed(label)
        }

        return try clipPlayer.playOneShot(
            fileURL: fileURL,
            kind: kind,
            label: label,
            completion: completion
        )
    }
}
