import AVFoundation
import CryptoKit
import Foundation

nonisolated struct CharacterVocalAudioAsset: Sendable, Equatable, Hashable {
    let characterID: String
    let role: CharacterVocalRole
    let fileName: String
    let expectedSHA256: String
    let url: URL
}

nonisolated struct CharacterVocalAudioAssetIdentity: Sendable, Equatable, Hashable {
    let characterID: String
    let role: CharacterVocalRole
    let fileName: String
    let sha256: String
}

nonisolated struct CharacterVocalPreparedPoseTrack: Sendable {
    let identity: CharacterVocalAudioAssetIdentity
    let track: TuringGeneratedSpeechFrameTrack
}

nonisolated enum DadVocalAudioInventory {
    struct Entry: Sendable, Equatable {
        let role: CharacterVocalRole
        let fileName: String
        let sha256: String
    }

    static let ordered: [Entry] = [
        .init(role: .presenceLoop, fileName: "dad_breathing.wav", sha256: "db27f0d2131e9776cc9858b7e7a4489c55058f23233ac33efcf27a5c09acf6bb"),
        .init(role: .damageHit, fileName: "dad-damaged-01.wav", sha256: "fd079a1794c72cd18b565a7398bbb3d601c18fce8be68c85578d0d10f67bf7a5"),
        .init(role: .damageHit, fileName: "dad-damaged-02.wav", sha256: "024cc7fc72276ac2501c729faa97aa5ef855f2739af4d1eba408a6304eca3e71"),
        .init(role: .damageHit, fileName: "dad-damaged-03.wav", sha256: "e28f6eba93636333ead99be7b9059bd9742136375b4aaf87fa1ab1e4e6581da1"),
        .init(role: .damageHit, fileName: "dad-damaged-04.wav", sha256: "4f5fd5842e046ab7a0fc3fb51d4fe38eb5ad4d2f923b3bacf53cb9fa262a2cbf"),
        .init(role: .death, fileName: "dad-death-01.wav", sha256: "670ff38fd3eb5e8f95d1b5848ec346b9a9e7b2f1b610b61a4c6f93e97d40b2f4"),
        .init(role: .death, fileName: "dad-death-02.wav", sha256: "bedad39a231b62e7acb4fc7462680d62d84367e5b3e341ccfe4761774853fcff"),
        .init(role: .death, fileName: "dad-death-03.wav", sha256: "a06c5cf435c3597d7bbd6e98023dc170250e9a95c8bd807fda2ecb67746ff0dc"),
        .init(role: .death, fileName: "dad-death-04.wav", sha256: "48d97a9a5558870a4ba4ee238f805ca4dd86465ffe3bace1898036f66b9dd205")
    ]

    static func entry(role: CharacterVocalRole, fileName: String) -> Entry? {
        ordered.first { $0.role == role && $0.fileName == fileName }
    }

    static func assets(bundle: Bundle = .main) -> [CharacterVocalAudioAsset] {
        ordered.compactMap { entry in
            let url = bundle.url(forResource: entry.fileName, withExtension: nil) ?? {
                let path = URL(fileURLWithPath: entry.fileName)
                return bundle.url(
                    forResource: path.deletingPathExtension().lastPathComponent,
                    withExtension: path.pathExtension
                )
            }()
            guard let url else { return nil }
            return .init(
                characterID: "dad",
                role: entry.role,
                fileName: entry.fileName,
                expectedSHA256: entry.sha256,
                url: url
            )
        }
    }

    static func asset(
        for start: CharacterVocalPlaybackStart,
        bundle: Bundle = .main
    ) -> CharacterVocalAudioAsset? {
        guard start.identity.characterID == "dad",
              start.identity.archetype == .dad,
              let entry = entry(
                role: start.identity.role,
                fileName: start.identity.fileName
              ) else { return nil }
        let path = URL(fileURLWithPath: entry.fileName)
        guard let url = bundle.url(forResource: entry.fileName, withExtension: nil) ??
                bundle.url(
                    forResource: path.deletingPathExtension().lastPathComponent,
                    withExtension: path.pathExtension
                ) else { return nil }
        return .init(
            characterID: "dad",
            role: entry.role,
            fileName: entry.fileName,
            expectedSHA256: entry.sha256,
            url: url
        )
    }
}

private nonisolated final class CharacterVocalPoseTrackWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.gravitasplague.character-vocal-track-worker",
        qos: .utility
    )
    private let analyzer = TuringGeneratedSpeechAnalyzer(configuration: .production)

    func compile(
        _ asset: CharacterVocalAudioAsset
    ) async -> Result<CharacterVocalPreparedPoseTrack, Error> {
        await withCheckedContinuation { continuation in
            queue.async { [analyzer] in
                dispatchPrecondition(condition: .notOnQueue(.main))
                do {
                    let data = try Data(contentsOf: asset.url, options: .mappedIfSafe)
                    let digest = SHA256.hash(data: data).map {
                        String(format: "%02x", $0)
                    }.joined()
                    guard digest == asset.expectedSHA256 else {
                        throw CharacterVocalBlendShapeError.hashMismatch(
                            resource: asset.fileName,
                            expected: asset.expectedSHA256,
                            actual: digest
                        )
                    }
                    let decoded = try Self.decode(url: asset.url)
                    let analysis: TuringGeneratedSpeechVisualAnalysis
                    do {
                        analysis = try analyzer.analyze(
                            processedAudio: decoded.samples,
                            sampleRate: decoded.sampleRate,
                            channelCount: decoded.channelCount,
                            deadline: nil,
                            cancellationToken: nil
                        )
                    } catch {
                        throw CharacterVocalBlendShapeError.poseAnalysisFailed(
                            "\(asset.fileName): \(error.localizedDescription)"
                        )
                    }
                    continuation.resume(returning: .success(.init(
                        identity: .init(
                            characterID: asset.characterID,
                            role: asset.role,
                            fileName: asset.fileName,
                            sha256: digest
                        ),
                        track: analysis.frameTrack
                    )))
                } catch {
                    continuation.resume(returning: .failure(error))
                }
            }
        }
    }

    private struct DecodedPCM {
        let samples: [Float]
        let sampleRate: Int
        let channelCount: Int
    }

    private static func decode(url: URL) throws -> DecodedPCM {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let channels = Int(format.channelCount)
            guard channels > 0, format.sampleRate > 0,
                  file.length > 0,
                  file.length <= AVAudioFramePosition(UInt32.max),
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(file.length)
                  ) else {
                throw CharacterVocalBlendShapeError.audioDecodeFailed(url.lastPathComponent)
            }
            try file.read(into: buffer)
            guard let channelData = buffer.floatChannelData,
                  buffer.frameLength > 0 else {
                throw CharacterVocalBlendShapeError.audioDecodeFailed(url.lastPathComponent)
            }
            let frames = Int(buffer.frameLength)
            var samples = [Float]()
            samples.reserveCapacity(frames * channels)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let value = channelData[channel][frame]
                    samples.append(value.isFinite ? value : 0)
                }
            }
            return .init(
                samples: samples,
                sampleRate: Int(format.sampleRate.rounded()),
                channelCount: channels
            )
        } catch let error as CharacterVocalBlendShapeError {
            throw error
        } catch {
            throw CharacterVocalBlendShapeError.audioDecodeFailed(
                "\(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }
}

actor CharacterVocalPoseTrackStore {
    private let worker = CharacterVocalPoseTrackWorker()
    private var preparedByAsset: [CharacterVocalAudioAsset: CharacterVocalPreparedPoseTrack] = [:]
    private var failuresByAsset: [CharacterVocalAudioAsset: String] = [:]
    private var preparationTasks: [
        CharacterVocalAudioAsset: Task<Result<CharacterVocalPreparedPoseTrack, Error>, Never>
    ] = [:]

    func prepare(
        _ asset: CharacterVocalAudioAsset
    ) async -> CharacterVocalPreparedPoseTrack? {
        if let prepared = preparedByAsset[asset] { return prepared }
        if failuresByAsset[asset] != nil { return nil }

        let startedAt = ContinuousClock.now
        let task: Task<Result<CharacterVocalPreparedPoseTrack, Error>, Never>
        if let existing = preparationTasks[asset] {
            task = existing
        } else {
            task = Task { [worker] in
                await worker.compile(asset)
            }
            preparationTasks[asset] = task
        }
        let result = await task.value
        preparationTasks.removeValue(forKey: asset)
        if let prepared = preparedByAsset[asset] { return prepared }
        switch result {
        case .success(let prepared):
            preparedByAsset[asset] = prepared
            let elapsed = Self.seconds(startedAt.duration(to: .now))
            print(
                "[DadVocalTrack] prepared file=\(asset.fileName) role=\(asset.role.rawValue) " +
                "frames=\(prepared.track.frameCount) runs=\(prepared.track.poseRuns.count) " +
                "seconds=\(String(format: "%.3f", elapsed)) rawPCMRetained=false"
            )
            return prepared
        case .failure(let error):
            let reason = error.localizedDescription
            failuresByAsset[asset] = reason
            print(
                "[DadVocalTrack] unavailable file=\(asset.fileName) " +
                "role=\(asset.role.rawValue) reason=\(reason) audioUnaffected=true"
            )
            return nil
        }
    }

    func removeAll() {
        for task in preparationTasks.values { task.cancel() }
        preparationTasks.removeAll(keepingCapacity: false)
        preparedByAsset.removeAll(keepingCapacity: false)
        failuresByAsset.removeAll(keepingCapacity: false)
    }

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1.0e18
    }
}
