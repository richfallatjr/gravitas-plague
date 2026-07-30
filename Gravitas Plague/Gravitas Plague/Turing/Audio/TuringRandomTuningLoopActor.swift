@preconcurrency import AVFoundation
import CryptoKit
import Foundation

actor TuringRandomTuningLoopActor:
    TuringGeneratedGapBridge
{
    struct Configuration: Sendable {
        let deviceID: String
        let resourceSubdirectory: String
        let fileNames: [String]
        let route: TuringAudioRouteID
        let clipKind: TuringAudioClipKind
        let gainDB: Float
        let avoidImmediateRepeat: Bool

        static let hamReceiver = Configuration(
            deviceID: "hamReceiver",
            resourceSubdirectory:
                "Turing/Audio/ham-receiver",
            fileNames: [
                "ham-radio-tuning-static-01.mp3",
                "ham-radio-tuning-static-02.mp3",
                "ham-radio-tuning-static-03.mp3",
                "ham-radio-tuning-static-04.mp3"
            ],
            route: .hamReceiver,
            clipKind: .hamReceiverTuningFiller,
            gainDB: -14,
            avoidImmediateRepeat: true
        )
    }

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
        case notPrepared(String)
        case endpointNotInstalled(String)
        case ownedByAnotherRun(
            deviceID: String,
            active: String,
            requested: String
        )
        case noPlayableResource(String)

        var errorDescription: String? {
            switch self {
            case .notPrepared(let deviceID):
                return "\(deviceID) tuning resources are not prepared."
            case .endpointNotInstalled(let deviceID):
                return "\(deviceID) tuning endpoint is not installed."
            case .ownedByAnotherRun(
                let deviceID,
                let active,
                let requested
            ):
                return "\(deviceID) tuning belongs to \(active), not \(requested)."
            case .noPlayableResource(let deviceID):
                return "No \(deviceID) tuning loop could be played."
            }
        }
    }

    static let hamReceiver =
        TuringRandomTuningLoopActor(
            configuration: .hamReceiver
        )

    private let configuration: Configuration
    private let randomIndex: @Sendable (Int) -> Int
    private var resources: [Resource] = []
    private var endpoint:
        (any TuringTransientAudioPlaybackEndpoint)?
    private var eventTask: Task<Void, Never>?
    private var activeOwnerID: String?
    private var activeHandle: TuringAudioPlaybackHandle?
    private var activeResource: Resource?
    private var lastSelectedResource: Resource?
    private var activeWaitingSegmentIndex: Int?
    private var activeReason: String?

    init(
        configuration: Configuration,
        randomIndex:
            @escaping @Sendable (Int) -> Int = {
                upperBound in
                Int.random(in: 0..<upperBound)
            }
    ) {
        self.configuration = configuration
        self.randomIndex = randomIndex
    }

    func prepareResources() throws {
        let bundle = Bundle.main
        var resolved: [Resource] = []
        resolved.reserveCapacity(
            configuration.fileNames.count
        )

        for fileName in configuration.fileNames {
            let fileURL = try requireResourceURL(
                fileName: fileName,
                bundle: bundle
            )
            let metadata = try Self.readMetadata(
                fileURL
            )
            let data = try Data(
                contentsOf: fileURL,
                options: .mappedIfSafe
            )
            guard data.isEmpty == false else {
                throw TuringRuntimeError.invalidConfig(
                    "Invalid \(configuration.deviceID) tuning file \(fileName)."
                )
            }
            let digest = SHA256.hash(data: data)
                .map {
                    String(format: "%02x", $0)
                }
                .joined()
            let resource = Resource(
                fileName: fileName,
                fileURL: fileURL,
                durationSeconds:
                    metadata.durationSeconds,
                sampleRate: metadata.sampleRate,
                channelCount: metadata.channelCount,
                byteCount: data.count,
                sha256: digest
            )
            resolved.append(resource)
            print("""
            [TuringRandomTuning] resource validated
              deviceID: \(configuration.deviceID)
              path: \(fileURL.path)
              durationSeconds: \(String(format: "%.3f", metadata.durationSeconds))
              sampleRate: \(metadata.sampleRate)
              channels: \(metadata.channelCount)
              byteCount: \(data.count)
              sha256: \(digest)
            """)
        }

        guard resolved.count ==
                configuration.fileNames.count else {
            throw TuningError.notPrepared(
                configuration.deviceID
            )
        }
        resources = resolved
        print("""
        [TuringRandomTuning] resources prepared
          deviceID: \(configuration.deviceID)
          count: \(resolved.count)
          files: \(resolved.map(\.fileName))
          preparedRealityResources: 0
        """)
    }

    func install(
        endpoint:
            any TuringTransientAudioPlaybackEndpoint
    ) async {
        await reset(reason: "replaceEndpoint")
        self.endpoint = endpoint
        let stream = await endpoint.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard Task.isCancelled == false else {
                    return
                }
                await self?.handleEndpointEvent(
                    event
                )
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
                waitingForSegmentIndex:
                    waitingForSegmentIndex,
                reason: reason
            )
        } catch {
            print("""
            [TuringRandomTuning] gap filler unavailable
              deviceID: \(configuration.deviceID)
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
            return
        }
        await stopActiveLoop(reason: reason)
    }

    func reset(reason: String) async {
        await stopActiveLoop(reason: reason)
        eventTask?.cancel()
        eventTask = nil
        endpoint = nil
    }

    func unload(reason: String) async {
        await reset(reason: reason)
        resources.removeAll(keepingCapacity: false)
        lastSelectedResource = nil
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
            throw TuningError.notPrepared(
                configuration.deviceID
            )
        }
        guard let endpoint else {
            throw TuningError.endpointNotInstalled(
                configuration.deviceID
            )
        }

        if let activeOwnerID {
            guard activeOwnerID == ownerID else {
                throw TuningError.ownedByAnotherRun(
                    deviceID:
                        configuration.deviceID,
                    active: activeOwnerID,
                    requested: ownerID
                )
            }
            if activeHandle != nil {
                activeWaitingSegmentIndex =
                    waitingForSegmentIndex
                activeReason = reason
                return
            }
        }

        var remaining = selectionCandidates()
        while remaining.isEmpty == false {
            let selected = remaining.remove(
                at:
                    boundedRandomIndex(
                        upperBound: remaining.count
                    )
            )
            do {
                let handle = try await endpoint.play(
                    TuringAudioPlaybackRequest(
                        requestID: UUID(),
                        runID: ownerID,
                        fileURL: selected.fileURL,
                        kind: configuration.clipKind,
                        route: configuration.route,
                        label: selected.fileName,
                        gainDB: configuration.gainDB,
                        shouldLoop: true,
                        cachePolicy: .transient
                    )
                )
                activeOwnerID = ownerID
                activeHandle = handle
                activeResource = selected
                lastSelectedResource = selected
                activeWaitingSegmentIndex =
                    waitingForSegmentIndex
                activeReason = reason
                print("""
                [TuringRandomTuning] loop started
                  deviceID: \(configuration.deviceID)
                  ownerID: \(ownerID)
                  file: \(selected.fileName)
                  waitingForSegmentIndex: \(waitingForSegmentIndex)
                  reason: \(reason)
                  activeHandleCount: 1
                """)
                return
            } catch {
                await endpoint.evictTransient(
                    fileURL: selected.fileURL
                )
            }
        }
        throw TuningError.noPlayableResource(
            configuration.deviceID
        )
    }

    private func stopActiveLoop(
        reason: String
    ) async {
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
            await endpoint.evictTransient(
                fileURL: resource.fileURL
            )
        }
        print("""
        [TuringRandomTuning] loop stopped
          deviceID: \(configuration.deviceID)
          ownerID: \(ownerID ?? "none")
          file: \(resource?.fileName ?? "none")
          reason: \(reason)
          activeHandleCount: 0
        """)
    }

    private func selectionCandidates()
        -> [Resource]
    {
        guard configuration.avoidImmediateRepeat,
              resources.count > 1,
              let lastSelectedResource else {
            return resources
        }
        let alternatives = resources.filter {
            $0 != lastSelectedResource
        }
        return alternatives.isEmpty
            ? resources
            : alternatives
    }

    private func boundedRandomIndex(
        upperBound: Int
    ) -> Int {
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
            let waitingIndex =
                activeWaitingSegmentIndex
            let priorReason = activeReason
            let resource = activeResource
            activeHandle = nil
            activeResource = nil
            if let resource, let endpoint {
                await endpoint.evictTransient(
                    fileURL: resource.fileURL
                )
            }
            if let ownerID, let waitingIndex {
                do {
                    try await startLoop(
                        ownerID: ownerID,
                        waitingForSegmentIndex:
                            waitingIndex,
                        reason:
                            "unexpectedCompletion.\(priorReason ?? "unknown")"
                    )
                } catch {
                    print("""
                    [TuringRandomTuning] restart failed
                      deviceID: \(configuration.deviceID)
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
            guard activeHandle?.requestID ==
                    requestID else {
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
            [TuringRandomTuning] active loop failed
              deviceID: \(configuration.deviceID)
              file: \(resource?.fileName ?? "none")
              error: \(message)
            """)

        case .started:
            break
        }
    }

    private func requireResourceURL(
        fileName: String,
        bundle: Bundle
    ) throws -> URL {
        let source =
            URL(fileURLWithPath: fileName)
        let stem =
            source.deletingPathExtension()
                .lastPathComponent
        let ext = source.pathExtension
        let url = bundle.url(
            forResource: stem,
            withExtension: ext,
            subdirectory:
                configuration
                    .resourceSubdirectory
        ) ?? bundle.url(
            forResource: stem,
            withExtension: ext
        )
        guard let url else {
            throw TuringRuntimeError.invalidConfig(
                "Missing \(configuration.deviceID) tuning loop \(fileName)."
            )
        }
        return url
    }

    private nonisolated static func readMetadata(
        _ fileURL: URL
    ) throws -> (
        durationSeconds: Double,
        sampleRate: Double,
        channelCount: Int
    ) {
        let values = try fileURL.resourceValues(
            forKeys: [
                .fileSizeKey,
                .isRegularFileKey
            ]
        )
        guard values.isRegularFile == true,
              (values.fileSize ?? 0) > 0 else {
            throw TuringRuntimeError.invalidConfig(
                "Invalid tuning file \(fileURL.lastPathComponent)."
            )
        }

        let audioFile = try AVAudioFile(
            forReading: fileURL
        )
        let format = audioFile.fileFormat
        let sampleRate = format.sampleRate
        let channelCount =
            Int(format.channelCount)
        let duration = sampleRate > 0
            ? Double(audioFile.length) /
                sampleRate
            : 0
        guard duration.isFinite,
              duration > 0,
              sampleRate > 0,
              channelCount > 0 else {
            throw TuringRuntimeError.invalidConfig(
                "Unreadable tuning file \(fileURL.lastPathComponent)."
            )
        }
        return (
            duration,
            sampleRate,
            channelCount
        )
    }
}
