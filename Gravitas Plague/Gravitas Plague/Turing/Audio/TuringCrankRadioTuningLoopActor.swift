@preconcurrency import AVFoundation
import CryptoKit
import Foundation

nonisolated struct TuringCrankRadioOrientationToken: Sendable, Equatable {
    let id: UUID
    let ownerID: String
    let handleID: UUID
    let fileName: String
}

actor TuringCrankRadioTuningLoopActor: TuringGeneratedGapBridge {
    static let shared = TuringCrankRadioTuningLoopActor()

    struct Resource: Sendable, Equatable, Hashable {
        let fileName: String
        let fileURL: URL
        let durationSeconds: Double
        let sampleRate: Double
        let channelCount: Int
        let byteCount: Int
        let sha256: String
    }

    enum TuningError: LocalizedError {
        case notPrepared
        case endpointNotInstalled
        case ownedByAnotherRun(active: String, requested: String)
        case noPlayableResource

        var errorDescription: String? {
            switch self {
            case .notPrepared:
                return "Crank-radio tuning resources are not prepared."
            case .endpointNotInstalled:
                return "Crank-radio tuning endpoint is not installed."
            case .ownedByAnotherRun(let active, let requested):
                return "Crank-radio tuning belongs to \(active), not \(requested)."
            case .noPlayableResource:
                return "No crank-radio tuning loop could be played."
            }
        }
    }

    private let expectedFileNames = [
        "crank-radio-tuning-01.mp3",
        "crank-radio-tuning-02.mp3",
        "crank-radio-tuning-03.mp3",
        "crank-radio-tuning-04.mp3"
    ]
    private let randomIndex: @Sendable (Int) -> Int

    private var resources: [Resource] = []
    private var endpoint: (any TuringTransientAudioPlaybackEndpoint)?
    private var eventTask: Task<Void, Never>?
    private var activeOwnerID: String?
    private var activeHandle: TuringAudioPlaybackHandle?
    private var activeResource: Resource?
    private var lastSelectedResource: Resource?
    private var activeWaitingSegmentIndex: Int?
    private var activeReason: String?

    init(
        randomIndex: @escaping @Sendable (Int) -> Int = { upperBound in
            Int.random(in: 0..<upperBound)
        }
    ) {
        self.randomIndex = randomIndex
    }

    func prepareResources() throws {
        let bundle = Bundle.main
        var resolved: [Resource] = []
        resolved.reserveCapacity(expectedFileNames.count)

        for fileName in expectedFileNames {
            let fileURL = try requireResourceURL(
                fileName: fileName,
                bundle: bundle
            )
            let metadata = try TuringAudioMetadataReader.read(fileURL)
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard data.isEmpty == false else {
                throw TuringRuntimeError.invalidConfig(
                    "Invalid crank-radio tuning file \(fileName)."
                )
            }
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            let resource = Resource(
                fileName: fileName,
                fileURL: fileURL,
                durationSeconds: metadata.durationSeconds,
                sampleRate: metadata.sampleRate,
                channelCount: metadata.channelCount,
                byteCount: data.count,
                sha256: digest
            )
            resolved.append(resource)
            print("""
            [TuringCrankRadioTuning] resource validated
              path: \(fileURL.path)
              durationSeconds: \(String(format: "%.3f", metadata.durationSeconds))
              sampleRate: \(metadata.sampleRate)
              channels: \(metadata.channelCount)
              byteCount: \(data.count)
              sha256: \(digest)
            """)
        }

        guard resolved.count == expectedFileNames.count else {
            throw TuningError.notPrepared
        }
        resources = resolved
        print("""
        [TuringCrankRadioTuning] resources prepared
          count: \(resolved.count)
          files: \(resolved.map(\.fileName))
          preparedRealityResources: 0
        """)
    }

    func install(
        endpoint: any TuringTransientAudioPlaybackEndpoint
    ) async {
        await reset(reason: "replaceEndpoint")
        self.endpoint = endpoint
        let stream = await endpoint.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard Task.isCancelled == false else {
                    return
                }
                await self?.handleEndpointEvent(event)
            }
        }
    }

    func beginGap(
        ownerID: String,
        waitingForSegmentIndex: Int,
        reason: String
    ) async {
        do {
            try await startLoop(
                ownerID: ownerID,
                waitingForSegmentIndex: waitingForSegmentIndex,
                reason: reason
            )
        } catch {
            print("""
            [TuringCrankRadioTuning] gap filler unavailable
              ownerID: \(ownerID)
              waitingForSegmentIndex: \(waitingForSegmentIndex)
              reason: \(reason)
              error: \(error.localizedDescription)
              generatedFlowContinues: true
            """)
        }
    }

    func endGap(
        ownerID: String,
        reason: String
    ) async {
        guard activeOwnerID == ownerID else {
            if let activeOwnerID {
                print("""
                [TuringCrankRadioTuning] stale end ignored
                  requestedOwnerID: \(ownerID)
                  activeOwnerID: \(activeOwnerID)
                  reason: \(reason)
                """)
            }
            return
        }
        await stopActiveLoop(reason: reason)
    }

    func beginPrerecordingOrientation(
        ownerID: String,
        reason: String
    ) async throws -> TuringCrankRadioOrientationToken {
        try await startLoop(
            ownerID: ownerID,
            waitingForSegmentIndex: 0,
            reason: reason
        )
        guard let handle = activeHandle,
              let resource = activeResource,
              activeOwnerID == ownerID else {
            throw TuningError.noPlayableResource
        }
        return TuringCrankRadioOrientationToken(
            id: UUID(),
            ownerID: ownerID,
            handleID: handle.id,
            fileName: resource.fileName
        )
    }

    func endPrerecordingOrientation(
        _ token: TuringCrankRadioOrientationToken,
        reason: String
    ) async {
        guard activeOwnerID == token.ownerID,
              activeHandle?.id == token.handleID,
              activeResource?.fileName == token.fileName else {
            print("[TuringPROrientation] stale crank token ignored token=\(token.id.uuidString)")
            return
        }
        await stopActiveLoop(reason: reason)
    }

    func reset(reason: String) async {
        await stopActiveLoop(reason: reason)
        eventTask?.cancel()
        eventTask = nil
        endpoint = nil
        activeOwnerID = nil
        activeWaitingSegmentIndex = nil
        activeReason = nil
    }

    func unload(reason: String) async {
        await reset(reason: reason)
        resources.removeAll(keepingCapacity: false)
        lastSelectedResource = nil
    }

    func activeFileName() -> String? {
        activeResource?.fileName
    }

    func preparedResources() -> [Resource] {
        resources
    }

    private func startLoop(
        ownerID: String,
        waitingForSegmentIndex: Int,
        reason: String
    ) async throws {
        guard resources.isEmpty == false else {
            throw TuningError.notPrepared
        }
        guard let endpoint else {
            throw TuningError.endpointNotInstalled
        }

        if let activeOwnerID {
            guard activeOwnerID == ownerID else {
                throw TuningError.ownedByAnotherRun(
                    active: activeOwnerID,
                    requested: ownerID
                )
            }
            if activeHandle != nil {
                activeWaitingSegmentIndex = waitingForSegmentIndex
                activeReason = reason
                return
            }
        }

        var remaining = selectionCandidates()
        while remaining.isEmpty == false {
            let selected = remaining.remove(
                at: boundedRandomIndex(upperBound: remaining.count)
            )
            do {
                let handle = try await endpoint.play(
                    TuringAudioPlaybackRequest(
                        requestID: UUID(),
                        runID: ownerID,
                        fileURL: selected.fileURL,
                        kind: .crankRadioTuningFiller,
                        route: .rollingBenchRadio,
                        label: selected.fileName,
                        gainDB: Float(
                            TuringRollingBenchTuning.tuningLoopGainDB
                        ),
                        shouldLoop: true,
                        cachePolicy: .transient
                    )
                )
                activeOwnerID = ownerID
                activeHandle = handle
                activeResource = selected
                lastSelectedResource = selected
                activeWaitingSegmentIndex = waitingForSegmentIndex
                activeReason = reason
                print("""
                [TuringCrankRadioTuning] loop started
                  ownerID: \(ownerID)
                  file: \(selected.fileName)
                  waitingForSegmentIndex: \(waitingForSegmentIndex)
                  reason: \(reason)
                  shouldLoop: true
                  cachePolicy: transient
                  activeHandleCount: 1
                """)
                return
            } catch {
                await endpoint.evictTransient(
                    fileURL: selected.fileURL
                )
                print("""
                [TuringCrankRadioTuning] candidate failed
                  ownerID: \(ownerID)
                  file: \(selected.fileName)
                  error: \(error.localizedDescription)
                """)
            }
        }
        throw TuningError.noPlayableResource
    }

    private func stopActiveLoop(reason: String) async {
        let ownerID = activeOwnerID
        let handle = activeHandle
        let resource = activeResource
        let endpoint = self.endpoint

        activeHandle = nil
        activeResource = nil
        activeOwnerID = nil
        activeWaitingSegmentIndex = nil
        activeReason = nil

        guard let handle, let endpoint else {
            return
        }
        await endpoint.stop(handle, reason: reason)
        if let resource {
            await endpoint.evictTransient(fileURL: resource.fileURL)
        }
        print("""
        [TuringCrankRadioTuning] loop stopped
          ownerID: \(ownerID ?? "none")
          file: \(resource?.fileName ?? "none")
          reason: \(reason)
          transientResourceEvicted: \(resource != nil)
          activeHandleCount: 0
        """)
    }

    private func selectionCandidates() -> [Resource] {
        guard resources.count > 1,
              let lastSelectedResource else {
            return resources
        }
        let alternatives = resources.filter {
            $0 != lastSelectedResource
        }
        return alternatives.isEmpty ? resources : alternatives
    }

    private func boundedRandomIndex(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return min(
            upperBound - 1,
            max(0, randomIndex(upperBound))
        )
    }

    private func handleEndpointEvent(
        _ event: TuringAudioPlaybackEvent
    ) async {
        switch event {
        case .completed(let handle, _):
            guard activeHandle == handle else {
                return
            }
            let ownerID = activeOwnerID
            let waitingForSegmentIndex = activeWaitingSegmentIndex
            let priorReason = activeReason
            let resource = activeResource
            activeHandle = nil
            activeResource = nil
            if let resource, let endpoint {
                await endpoint.evictTransient(
                    fileURL: resource.fileURL
                )
            }
            print("""
            [TuringCrankRadioTuning] unexpected loop completion
              ownerID: \(ownerID ?? "none")
              file: \(resource?.fileName ?? "none")
              willRestartIfStillWaiting: \(ownerID != nil && waitingForSegmentIndex != nil)
            """)
            if let ownerID, let waitingForSegmentIndex {
                do {
                    try await startLoop(
                        ownerID: ownerID,
                        waitingForSegmentIndex: waitingForSegmentIndex,
                        reason:
                            "unexpectedCompletion.\(priorReason ?? "unknown")"
                    )
                } catch {
                    print("""
                    [TuringCrankRadioTuning] restart failed
                      ownerID: \(ownerID)
                      error: \(error.localizedDescription)
                    """)
                }
            }

        case .cancelled(let handle, _):
            guard activeHandle == handle else {
                return
            }
            activeHandle = nil
            activeResource = nil
            activeOwnerID = nil
            activeWaitingSegmentIndex = nil
            activeReason = nil

        case .failed(let requestID, _, let message):
            guard activeHandle?.requestID == requestID else {
                return
            }
            let resource = activeResource
            if let resource, let endpoint {
                await endpoint.evictTransient(
                    fileURL: resource.fileURL
                )
            }
            activeHandle = nil
            activeResource = nil
            activeOwnerID = nil
            activeWaitingSegmentIndex = nil
            activeReason = nil
            print("""
            [TuringCrankRadioTuning] active loop failed
              file: \(resource?.fileName ?? "none")
              error: \(message)
              generatedFlowContinues: true
            """)

        case .started, .paused, .resumed:
            break
        }
    }

    private func requireResourceURL(
        fileName: String,
        bundle: Bundle
    ) throws -> URL {
        let source = URL(fileURLWithPath: fileName)
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        let url = bundle.url(
            forResource: stem,
            withExtension: ext,
            subdirectory: "Turing/Audio/rolling-bench"
        ) ?? bundle.url(
            forResource: stem,
            withExtension: ext
        )
        guard let url else {
            throw TuringRuntimeError.invalidConfig(
                "Missing crank-radio tuning loop \(fileName)."
            )
        }
        return url
    }
}

private struct TuringAudioMetadata: Sendable {
    let durationSeconds: Double
    let sampleRate: Double
    let channelCount: Int
}

private nonisolated enum TuringAudioMetadataReader {
    static func read(_ fileURL: URL) throws -> TuringAudioMetadata {
        let values = try fileURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey]
        )
        guard values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            throw TuringRuntimeError.invalidConfig(
                "Invalid crank-radio tuning file \(fileURL.lastPathComponent)."
            )
        }

        let audioFile = try AVAudioFile(forReading: fileURL)
        let format = audioFile.fileFormat
        let sampleRate = format.sampleRate
        let channelCount = Int(format.channelCount)
        let duration = sampleRate > 0
            ? Double(audioFile.length) / sampleRate
            : 0
        guard duration.isFinite,
              duration > 0,
              sampleRate > 0,
              channelCount > 0 else {
            throw TuringRuntimeError.invalidConfig(
                "Unreadable crank-radio tuning file \(fileURL.lastPathComponent)."
            )
        }
        return TuringAudioMetadata(
            durationSeconds: duration,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }
}
