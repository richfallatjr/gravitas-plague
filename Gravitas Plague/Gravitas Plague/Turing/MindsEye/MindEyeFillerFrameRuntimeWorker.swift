import CryptoKit
import Foundation

nonisolated protocol MindEyeFillerFrameWorking: Sendable {
    func loadIndex(locator: MindEyeResourceLocator) async throws -> MindEyeFillerFrameIndexSnapshot
    func loadTrack(
        entry: MindEyeFillerFrameIndex.Entry,
        clip: TuringFillerClipDescriptor,
        expectedSurface: StoryInteractionSurfaceID,
        locator: MindEyeResourceLocator
    ) async throws -> MindEyeAuthoredFrameTrack
}

nonisolated final class MindEyeSerialFillerFrameWorker:
    @unchecked Sendable,
    MindEyeFillerFrameWorking
{
    private let queue = DispatchQueue(
        label: "com.gravitas.plague.mindseye.filler-frame-worker",
        qos: .userInitiated
    )

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                precondition(!Thread.isMainThread)
                continuation.resume(with: autoreleasepool {
                    Result(catching: operation)
                })
            }
        }
    }

    func loadIndex(
        locator: MindEyeResourceLocator
    ) async throws -> MindEyeFillerFrameIndexSnapshot {
        try await perform {
            let path = "Turing/MindsEye/Fillers/index.json"
            let data = try Data(
                contentsOf: locator.resolve(resourcePath: path),
                options: .mappedIfSafe
            )
            return try MindEyeFillerFrameIndexSnapshot(
                index: JSONDecoder().decode(MindEyeFillerFrameIndex.self, from: data)
            )
        }
    }

    func loadTrack(
        entry: MindEyeFillerFrameIndex.Entry,
        clip: TuringFillerClipDescriptor,
        expectedSurface: StoryInteractionSurfaceID,
        locator: MindEyeResourceLocator
    ) async throws -> MindEyeAuthoredFrameTrack {
        try await perform {
            guard entry.fillerID == clip.identity.fillerID,
                  entry.speakerCharacterID == clip.identity.speakerCharacterID,
                  entry.audioResourcePath == clip.identity.audioResourcePath,
                  entry.audioSHA256 == clip.identity.audioSHA256,
                  entry.trackResourcePath == clip.identity.trackResourcePath,
                  entry.trackSHA256 == clip.identity.trackSHA256 else {
                throw Self.failure(entry, "Filler catalog/index identity mismatch.")
            }
            let trackData = try Data(
                contentsOf: locator.resolve(resourcePath: entry.trackResourcePath),
                options: .mappedIfSafe
            )
            guard Self.sha256(trackData) == entry.trackSHA256 else {
                throw Self.failure(entry, "Filler track hash mismatch.")
            }
            let audioData = try Data(contentsOf: clip.fileURL, options: .mappedIfSafe)
            guard Self.sha256(audioData) == entry.audioSHA256 else {
                throw Self.failure(entry, "Filler audio hash mismatch; audio continues at rest.")
            }
            let manifest = try JSONDecoder().decode(
                MindEyeFillerFrameManifest.self,
                from: trackData
            )
            try MindEyeFillerFrameManifestValidator.validate(manifest)
            guard manifest.fillerID == entry.fillerID,
                  manifest.speakerCharacterID == entry.speakerCharacterID,
                  manifest.audioSHA256 == entry.audioSHA256,
                  manifest.poseRuns.count == entry.poseRunCount else {
                throw Self.failure(entry, "Filler index/track metadata mismatch.")
            }
            var bits = ContiguousArray<UInt8>()
            var runs = ContiguousArray<MindEyeAuthoredPoseRun>()
            bits.reserveCapacity(manifest.timeline.frameCount)
            for run in manifest.poseRuns {
                guard let bit = MindEyeAuthoredMouthLayerBit(pose: run.pose) else {
                    throw Self.failure(entry, "Unknown filler mouth pose.")
                }
                bits.append(contentsOf: repeatElement(
                    bit.rawValue,
                    count: run.endFrameExclusive - run.startFrame
                ))
                runs.append(.init(
                    startFrame: run.startFrame,
                    endFrameExclusive: run.endFrameExclusive,
                    pose: run.pose
                ))
            }
            guard Self.sha256(Data(bits)) == manifest.expandedFramesSHA256 else {
                throw Self.failure(entry, "Filler expanded pose hash mismatch.")
            }
            let descriptor = MindEyeAuthoredFrameTrackDescriptor(
                prID: entry.fillerID,
                speakerCharacterID: entry.speakerCharacterID,
                interactionSurface: expectedSurface,
                manifestResourcePath: entry.trackResourcePath,
                manifestSHA256: entry.trackSHA256,
                descriptorSHA256: manifest.descriptorSHA256,
                audioSHA256: manifest.audioSHA256,
                transcriptSHA256: manifest.authoring.transcriptSHA256 ?? manifest.descriptorSHA256,
                framesSHA256: manifest.expandedFramesSHA256,
                sampleRate: manifest.timeline.sampleRate,
                sampleCount: manifest.timeline.sampleCount,
                framesPerSecond: manifest.timeline.framesPerSecond,
                samplesPerNominalFrame: manifest.timeline.samplesPerNominalFrame,
                frameCount: manifest.timeline.frameCount,
                durationSeconds: manifest.timeline.durationSeconds
            )
            return try MindEyeAuthoredFrameTrack(
                descriptor: descriptor,
                poseBits: bits,
                poseRuns: runs
            )
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(
        _ entry: MindEyeFillerFrameIndex.Entry,
        _ message: String
    ) -> MindEyeFailure {
        MindEyeFailure(
            code: .authoredFrameTrackInvalid,
            characterID: entry.speakerCharacterID,
            vignetteID: nil,
            resourcePath: entry.trackResourcePath,
            message: message
        )
    }
}
