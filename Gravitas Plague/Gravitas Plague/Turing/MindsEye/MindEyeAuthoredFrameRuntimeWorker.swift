import CryptoKit
import Foundation

nonisolated protocol MindEyeAuthoredFrameWorking: Sendable {
    func loadIndex(
        locator: MindEyeResourceLocator
    ) async throws -> MindEyeAuthoredFrameIndexSnapshot

    func loadTrack(
        indexEntry: MindEyeAuthoredFrameIndex.Entry,
        locator: MindEyeResourceLocator
    ) async throws -> MindEyeAuthoredFrameTrack
}

nonisolated final class MindEyeSerialAuthoredFrameWorker:
    @unchecked Sendable,
    MindEyeAuthoredFrameWorking
{
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let queueValue: UInt8 = 1

    init(
        label: String = "com.gravitas.plague.mindseye.authored-frame-worker"
    ) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: queueValue)
    }

    private func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                dispatchPrecondition(condition: .notOnQueue(.main))
                precondition(Thread.isMainThread == false)
                precondition(
                    DispatchQueue.getSpecific(key: queueKey) == queueValue
                )
                let result: Result<Value, Error> = autoreleasepool {
                    Result(catching: operation)
                }
                continuation.resume(with: result)
            }
        }
    }

    func loadIndex(
        locator: MindEyeResourceLocator
    ) async throws -> MindEyeAuthoredFrameIndexSnapshot {
        try await perform {
            let relative = "Turing/MindsEye/AudioFrames/index.json"
            let url = try locator.resolve(resourcePath: relative)
            let data = try Self.readData(
                url: url,
                code: .authoredFrameIndexMissing,
                resourcePath: relative
            )
            do {
                return try MindEyeAuthoredFrameIndexSnapshot(
                    index: JSONDecoder().decode(
                        MindEyeAuthoredFrameIndex.self,
                        from: data
                    )
                )
            } catch let failure as MindEyeFailure {
                throw failure
            } catch {
                throw MindEyeFailure(
                    code: .authoredFrameIndexInvalid,
                    characterID: nil,
                    vignetteID: nil,
                    resourcePath: relative,
                    message: "Authored frame index could not be decoded: \(error.localizedDescription)"
                )
            }
        }
    }

    func loadTrack(
        indexEntry: MindEyeAuthoredFrameIndex.Entry,
        locator: MindEyeResourceLocator
    ) async throws -> MindEyeAuthoredFrameTrack {
        try await perform {
            let path = indexEntry.manifestResourcePath
            let url = try locator.resolve(resourcePath: path)
            let data = try Self.readData(
                url: url,
                code: .authoredFrameManifestMissing,
                resourcePath: path
            )
            let manifestSHA = Self.sha256Hex(data)
            guard manifestSHA == indexEntry.manifestSHA256 else {
                throw MindEyeFailure(
                    code: .authoredFrameManifestHashMismatch,
                    characterID: indexEntry.speakerCharacterID,
                    vignetteID: nil,
                    resourcePath: path,
                    message: "Authored frame manifest bytes do not match the published index."
                )
            }

            let manifest: MindEyeAuthoredFrameManifest
            do {
                manifest = try JSONDecoder().decode(
                    MindEyeAuthoredFrameManifest.self,
                    from: data
                )
            } catch {
                throw MindEyeFailure(
                    code: .authoredFrameManifestInvalid,
                    characterID: indexEntry.speakerCharacterID,
                    vignetteID: nil,
                    resourcePath: path,
                    message: "Authored frame manifest could not be decoded: \(error.localizedDescription)"
                )
            }

            let failures = MindEyeAuthoredFrameManifestValidator.validate(manifest)
            if let first = failures.first { throw first }
            try Self.validateCrossFile(indexEntry: indexEntry, manifest: manifest)
            try Self.validateFramesSHA256(manifest, resourcePath: path)
            return try MindEyeAuthoredFrameTrackCompactor.compact(
                manifest: manifest,
                indexEntry: indexEntry,
                manifestResourcePath: path,
                manifestSHA256: manifestSHA
            )
        }
    }

    private static func readData(
        url: URL,
        code: MindEyeFailureCode,
        resourcePath: String
    ) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MindEyeFailure(
                code: code,
                characterID: nil,
                vignetteID: nil,
                resourcePath: resourcePath,
                message: "Required authored frame resource is missing."
            )
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard !data.isEmpty else {
            throw MindEyeFailure(
                code: code,
                characterID: nil,
                vignetteID: nil,
                resourcePath: resourcePath,
                message: "Required authored frame resource is empty."
            )
        }
        return data
    }

    private static func validateCrossFile(
        indexEntry: MindEyeAuthoredFrameIndex.Entry,
        manifest: MindEyeAuthoredFrameManifest
    ) throws {
        func mismatch(_ code: MindEyeFailureCode, _ message: String) -> MindEyeFailure {
            MindEyeFailure(
                code: code,
                characterID: indexEntry.speakerCharacterID,
                vignetteID: nil,
                resourcePath: indexEntry.manifestResourcePath,
                message: message
            )
        }
        guard manifest.prID == indexEntry.prID else {
            throw mismatch(.authoredFramePRMismatch, "Index and manifest PR IDs differ.")
        }
        guard manifest.speakerCharacterID == indexEntry.speakerCharacterID else {
            throw mismatch(.authoredFrameSpeakerMismatch, "Index and manifest speakers differ.")
        }
        guard manifest.interactionSurface == indexEntry.interactionSurface else {
            throw mismatch(.authoredFrameSurfaceMismatch, "Index and manifest surfaces differ.")
        }
        let expectedPath = "Turing/MindsEye/AudioFrames/\(indexEntry.prID).mouthframes.json"
        guard indexEntry.manifestResourcePath == expectedPath,
              manifest.descriptorSHA256 == indexEntry.descriptorSHA256,
              manifest.audioSHA256 == indexEntry.audioSHA256,
              manifest.transcriptSHA256 == indexEntry.transcriptSHA256,
              manifest.timeline.sampleCount == indexEntry.sampleCount,
              manifest.timeline.frameCount == indexEntry.frameCount,
              abs(manifest.timeline.durationSeconds - indexEntry.durationSeconds) <= 0.5 / 48_000,
              manifest.summary.poseFrameCounts["rest"] == indexEntry.poseFrameCounts.rest,
              manifest.summary.poseFrameCounts["small"] == indexEntry.poseFrameCounts.small,
              manifest.summary.poseFrameCounts["wide"] == indexEntry.poseFrameCounts.wide,
              manifest.summary.poseFrameCounts["round"] == indexEntry.poseFrameCounts.round,
              manifest.summary.poseFrameCounts["teeth"] == indexEntry.poseFrameCounts.teeth,
              manifest.summary.speechFrameCount == indexEntry.speechFrameCount,
              manifest.summary.fallbackFrameCount == indexEntry.fallbackFrameCount,
              manifest.summary.manualOverrideFrameCount == indexEntry.manualOverrideFrameCount,
              manifest.summary.warnings.count == indexEntry.warningCount else {
            throw mismatch(.authoredFrameManifestInvalid, "Index and manifest metadata differ.")
        }
    }

    private static func validateFramesSHA256(
        _ manifest: MindEyeAuthoredFrameManifest,
        resourcePath: String
    ) throws {
        var bytes = Data()
        bytes.reserveCapacity(manifest.frames.count * 32)
        for frame in manifest.frames {
            let phone = Data(frame.phone.utf8)
            guard let frameIndex = UInt32(exactly: frame.frameIndex),
                  let sampleStart = UInt64(exactly: frame.sampleStart),
                  let sampleEnd = UInt64(exactly: frame.sampleEnd),
                  let layerMask = UInt8(exactly: frame.layerMask),
                  let evidenceMask = UInt16(exactly: frame.evidenceMask),
                  let phoneCount = UInt16(exactly: phone.count) else {
                throw MindEyeFailure(
                    code: .authoredFrameManifestInvalid,
                    characterID: manifest.speakerCharacterID,
                    vignetteID: nil,
                    resourcePath: resourcePath,
                    message: "Frame data exceeds the binary hash contract."
                )
            }
            appendLittleEndian(frameIndex, to: &bytes)
            appendLittleEndian(sampleStart, to: &bytes)
            appendLittleEndian(sampleEnd, to: &bytes)
            bytes.append(layerMask)
            bytes.append(frame.speechActive ? 1 : 0)
            appendLittleEndian(evidenceMask, to: &bytes)
            appendLittleEndian(phoneCount, to: &bytes)
            bytes.append(phone)
        }
        guard sha256Hex(bytes) == manifest.framesSHA256 else {
            throw MindEyeFailure(
                code: .authoredFrameFramesHashMismatch,
                characterID: manifest.speakerCharacterID,
                vignetteID: nil,
                resourcePath: resourcePath,
                message: "Authored frame binary hash does not match the manifest."
            )
        }
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(
        _ value: T,
        to data: inout Data
    ) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

nonisolated struct MindEyeUnavailableAuthoredFrameWorker:
    MindEyeAuthoredFrameWorking,
    Sendable
{
    let failure: MindEyeFailure

    init(error: Error) {
        if let failure = error as? MindEyeFailure {
            self.failure = failure
        } else {
            failure = MindEyeFailure(
                code: .authoredFrameTrackUnavailable,
                characterID: nil,
                vignetteID: nil,
                resourcePath: nil,
                message: error.localizedDescription
            )
        }
    }

    func loadIndex(
        locator: MindEyeResourceLocator
    ) async throws -> MindEyeAuthoredFrameIndexSnapshot {
        _ = locator
        throw failure
    }

    func loadTrack(
        indexEntry: MindEyeAuthoredFrameIndex.Entry,
        locator: MindEyeResourceLocator
    ) async throws -> MindEyeAuthoredFrameTrack {
        _ = indexEntry
        _ = locator
        throw failure
    }
}
