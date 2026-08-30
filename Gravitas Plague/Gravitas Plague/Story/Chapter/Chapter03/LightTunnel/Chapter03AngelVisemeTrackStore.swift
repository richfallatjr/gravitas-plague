import CryptoKit
import Foundation

nonisolated struct Chapter03AngelVisemeTrackStore {
    func loadOptional(
        definition: Chapter03HeavenPortalEmberDefinition,
        angelPrerecording: Chapter03ResolvedAngelPrerecording?,
        bundle: Bundle = .main
    ) async -> Chapter03AngelVisemeTrack? {
        guard definition.enabled, let angelPrerecording else { return nil }
        do {
            let cueURL = try TuringResourceLoader.resourceURL(
                resourcePath: definition.visemeResourcePath,
                bundle: bundle
            )
            let descriptorURL = try TuringResourceLoader.resourceURL(
                resourcePath: angelPrerecording.definition.descriptorResourcePath,
                bundle: bundle
            )
            let expectedDescriptorPath = angelPrerecording.definition.descriptorResourcePath
            let expectedAudioPath = angelPrerecording.descriptor.audioFile
            let expectedCinematicID = definition.sourceCinematicID
            let audioURL = angelPrerecording.audioURL
            return try await Task.detached(priority: .utility) {
                let manifestData = try Data(contentsOf: cueURL)
                let descriptorData = try Data(contentsOf: descriptorURL)
                let audioData = try Data(contentsOf: audioURL)
                let manifest = try JSONDecoder().decode(
                    Chapter03AngelVisemeManifest.self,
                    from: manifestData
                )
                return try Self.validateAndAdapt(
                    manifest,
                    expectedCinematicID: expectedCinematicID,
                    expectedDescriptorPath: expectedDescriptorPath,
                    expectedAudioPath: expectedAudioPath,
                    descriptorSHA256: Self.sha256(descriptorData),
                    audioSHA256: Self.sha256(audioData)
                )
            }.value
        } catch {
            await MainActor.run {
                Chapter03HeavenPortalEmberDiagnostics.cueUnavailable(error)
            }
            return nil
        }
    }

    static func validateAndAdapt(
        _ manifest: Chapter03AngelVisemeManifest,
        expectedCinematicID: String,
        expectedDescriptorPath: String,
        expectedAudioPath: String,
        descriptorSHA256: String,
        audioSHA256: String
    ) throws -> Chapter03AngelVisemeTrack {
        let timeline = manifest.timeline
        let expectedFrameCount = Int(ceil(Double(timeline.sampleCount) / 800.0))
        let expectedDuration = Double(timeline.sampleCount) / 48_000
        let expectedPoses: [MindEyeMouthPose] = [.rest, .small, .wide, .round, .teeth]
        let expectedMultipliers: [String: Float] = [
            "rest": 1, "small": 1.33, "wide": 2, "round": 1.5, "teeth": 1.75
        ]
        guard manifest.schemaVersion == 1,
              manifest.compilerVersion == "chapter03-angel-visemes/1.0.0",
              manifest.trackID == expectedCinematicID + ".visemes",
              manifest.sourceCinematicID == expectedCinematicID,
              manifest.descriptorResourcePath == expectedDescriptorPath,
              manifest.audioResourcePath == expectedAudioPath,
              Self.isLowercaseSHA256(manifest.descriptorSHA256),
              Self.isLowercaseSHA256(manifest.audioSHA256),
              manifest.descriptorSHA256 == descriptorSHA256,
              manifest.audioSHA256 == audioSHA256,
              timeline.sampleRate == 48_000,
              timeline.sampleCount > 0,
              timeline.framesPerSecond == 60,
              timeline.samplesPerNominalFrame == 800,
              timeline.frameCount == expectedFrameCount,
              abs(timeline.durationSeconds - expectedDuration) <= 0.5 / 48_000,
              manifest.requiredPoseFamilies == expectedPoses,
              manifest.densityMultipliers == expectedMultipliers,
              manifest.alignment.mode == "pocketsphinxAllPhone",
              manifest.alignment.engine == "pocketsphinx",
              manifest.alignment.engineVersion == "5.1.1",
              manifest.alignment.phoneLanguageModelSHA256 != nil,
              manifest.alignment.transcriptSHA256 == nil,
              Self.isLowercaseSHA256(manifest.alignment.acousticModelSHA256),
              manifest.alignment.phoneLanguageModelSHA256.map(Self.isLowercaseSHA256) == true,
              Self.isLowercaseSHA256(manifest.alignment.VADModelSHA256),
              Self.isLowercaseSHA256(manifest.alignment.phonePoseMapSHA256),
              Self.isLowercaseSHA256(manifest.runsSHA256),
              !manifest.runs.isEmpty else {
            throw Chapter03Error.definitionInvalid("Angel viseme cue identity is invalid")
        }

        var expectedStart = 0
        var previousPose: MindEyeMouthPose?
        var counts = Dictionary(uniqueKeysWithValues: expectedPoses.map { ($0.rawValue, 0) })
        for run in manifest.runs {
            guard run.startFrame == expectedStart,
                  run.endFrameExclusive > run.startFrame,
                  run.endFrameExclusive <= timeline.frameCount,
                  run.pose != previousPose else {
                throw Chapter03Error.definitionInvalid("Angel viseme runs are not contiguous")
            }
            counts[run.pose.rawValue, default: 0] += run.endFrameExclusive - run.startFrame
            expectedStart = run.endFrameExclusive
            previousPose = run.pose
        }
        let speechFrames = counts.reduce(0) { partial, pair in
            partial + (pair.key == MindEyeMouthPose.rest.rawValue ? 0 : pair.value)
        }
        guard expectedStart == timeline.frameCount,
              manifest.summary.poseFrameCounts == counts,
              manifest.summary.speechFrameCount == speechFrames,
              manifest.summary.silenceFrameCount == counts[MindEyeMouthPose.rest.rawValue],
              manifest.summary.runCount == manifest.runs.count else {
            throw Chapter03Error.definitionInvalid("Angel viseme summary is stale")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedRuns = try encoder.encode(manifest.runs)
        guard sha256(encodedRuns) == manifest.runsSHA256 else {
            throw Chapter03Error.definitionInvalid("Angel viseme run hash is invalid")
        }

        return Chapter03AngelVisemeTrack(
            trackID: manifest.trackID,
            sampleRate: timeline.sampleRate,
            sampleCount: timeline.sampleCount,
            framesPerSecond: timeline.framesPerSecond,
            frameCount: timeline.frameCount,
            runs: ContiguousArray(manifest.runs.map {
                Chapter03AngelVisemeTrack.Run(
                    startFrame: $0.startFrame,
                    endFrameExclusive: $0.endFrameExclusive,
                    pose: $0.pose
                )
            })
        )
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        let bytes = value.utf8
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
