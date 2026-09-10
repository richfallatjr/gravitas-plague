import CryptoKit
import Foundation

actor CharacterVocalVisemeTrackStore {
    private typealias Tracks = [CharacterVocalVisemeTrackIdentity: CharacterVocalVisemeTrack]

    private nonisolated struct Configuration: Sendable {
        let characterID: String
        let catalogID: String
        let catalogPath: String
        let descriptorPath: String

        static func resolve(characterID: String) -> Self? {
            guard CharacterVocalBlendShapeProfile.resolve(
                characterID: characterID
            ) != nil else { return nil }
            return .init(
                characterID: characterID,
                catalogID: "\(characterID).infected.vocalVisemes.v1",
                catalogPath: "CharacterLibrary/FacialPerformance/" +
                    "\(characterID)_vocal_viseme_catalog.json",
                descriptorPath: "CharacterLibrary/FacialPerformance/" +
                    "\(characterID)_infected_vocal_blendshape.json"
            )
        }
    }

    private struct Load {
        let generation: UUID
        let task: Task<Result<Tracks, Error>, Never>
    }

    private static let compilerVersion = "character-vocal-allphone-visemes/1.0.0"
    private static let requiredPoses: [MindEyeMouthPose] = [
        .rest, .small, .wide, .round, .teeth
    ]
    private static let engineCommit =
        "511126b492dcb267cf30d49d631946d7b61a9530"
    private static let resourceTreeSHA256 =
        "e2ca8da1fecfd4a676fbd3d68537c705688b669b30ddaa1cb78dd1850e4fe12d"
    private static let acousticModelSHA256 =
        "88b15292ae279697836e8510e405beacc00a216be8e5733be40cf5429b4faa55"
    private static let phoneLanguageModelSHA256 =
        "c57e0fa4191b096b1279cfe3a77927f52568fdecfc6624ddb5cec9527c763a54"
    private static let vadModelSHA256 =
        "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"
    private static let phonePoseMapSHA256 =
        "32aaf5b5b5369d684ada94c847a26db9e6ff80b4fee97b687f47a4d9fb98470c"
    private static let speechBoundaryPolicy =
        "pocketsphinxNonSilencePhoneIntervals"

    private var cachedByCharacterID: [String: Result<Tracks, Error>] = [:]
    private var loadsByCharacterID: [String: Load] = [:]

    func track(
        for asset: CharacterVocalAudioAsset,
        bundle: Bundle = .main
    ) async -> CharacterVocalVisemeTrack? {
        guard let configuration = Configuration.resolve(
            characterID: asset.characterID
        ) else { return nil }
        let result = await load(configuration: configuration, bundle: bundle)
        guard case .success(let tracks) = result else { return nil }
        let identity = CharacterVocalVisemeTrackIdentity(
            characterID: asset.characterID,
            role: asset.role,
            audioFile: asset.fileName,
            audioSHA256: asset.expectedSHA256,
            looping: asset.role == .presenceLoop
        )
        return tracks[identity]
    }

    func removeAll() {
        for load in loadsByCharacterID.values { load.task.cancel() }
        loadsByCharacterID.removeAll(keepingCapacity: false)
        cachedByCharacterID.removeAll(keepingCapacity: false)
    }

    private func load(
        configuration: Configuration,
        bundle: Bundle
    ) async -> Result<Tracks, Error> {
        let characterID = configuration.characterID
        if let cached = cachedByCharacterID[characterID] { return cached }
        let task: Task<Result<Tracks, Error>, Never>
        let generation: UUID
        let startedAt: ContinuousClock.Instant
        if let existing = loadsByCharacterID[characterID] {
            task = existing.task
            generation = existing.generation
            startedAt = .now
        } else {
            startedAt = .now
            generation = UUID()
            task = Task.detached(priority: .utility) {
                do {
                    return .success(try Self.loadValidatedTracks(
                        configuration: configuration,
                        bundle: bundle
                    ))
                } catch {
                    return .failure(error)
                }
            }
            loadsByCharacterID[characterID] = .init(
                generation: generation,
                task: task
            )
        }
        let result = await task.value
        if let cached = cachedByCharacterID[characterID] { return cached }
        guard loadsByCharacterID[characterID]?.generation == generation else {
            return .failure(CancellationError())
        }
        loadsByCharacterID.removeValue(forKey: characterID)
        cachedByCharacterID[characterID] = result
        switch result {
        case .success(let tracks):
            print(
                "[CharacterVocalViseme] catalog ready " +
                "characterID=\(characterID) tracks=\(tracks.count) " +
                "seconds=\(String(format: "%.3f", Self.seconds(startedAt.duration(to: .now)))) " +
                "runtimeAudioDecode=false runtimeAnalysis=false"
            )
        case .failure(let error):
            print(
                "[CharacterVocalViseme] catalog unavailable " +
                "characterID=\(characterID) " +
                "reason=\(error.localizedDescription) audioUnaffected=true fallback=closed"
            )
        }
        return result
    }

    private nonisolated static func loadValidatedTracks(
        configuration: Configuration,
        bundle: Bundle
    ) throws -> Tracks {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let catalogURL = try resourceURL(
            bundle: bundle,
            logicalPath: configuration.catalogPath
        )
        let catalog = try JSONDecoder().decode(
            CharacterVocalVisemeCatalog.self,
            from: try Data(contentsOf: catalogURL, options: .mappedIfSafe)
        )
        let inventory = CharacterVocalAudioInventory.ordered(
            characterID: configuration.characterID
        )
        guard catalog.schemaVersion == 1,
              catalog.catalogID == configuration.catalogID,
              catalog.characterID == configuration.characterID,
              catalog.compilerVersion == compilerVersion,
              catalog.entries.count == 9,
              inventory.count == 9 else {
            throw CharacterVocalBlendShapeError.invalidDescriptor(
                "CharacterVocalVisemeCatalog.\(configuration.characterID).identity"
            )
        }
        var manifestPaths = Set<String>()
        for (entry, expected) in zip(catalog.entries, inventory) {
            guard entry.role == expected.role,
                  entry.audioFile == expected.fileName,
                  entry.audioSHA256 == expected.sha256,
                  entry.looping == (entry.role == .presenceLoop),
                  isLowercaseSHA256(entry.audioSHA256),
                  isSafeResourcePath(entry.manifestResourcePath),
                  manifestPaths.insert(entry.manifestResourcePath).inserted else {
                throw CharacterVocalBlendShapeError.invalidDescriptor(
                    "CharacterVocalVisemeCatalog.\(configuration.characterID).entries"
                )
            }
        }

        let descriptorURL = try resourceURL(
            bundle: bundle,
            logicalPath: configuration.descriptorPath
        )
        let descriptorHash = try sha256(url: descriptorURL)
        var tracks: Tracks = [:]
        tracks.reserveCapacity(catalog.entries.count)
        for entry in catalog.entries {
            let manifestURL = try resourceURL(
                bundle: bundle,
                logicalPath: entry.manifestResourcePath
            )
            let manifest = try JSONDecoder().decode(
                CharacterVocalVisemeManifest.self,
                from: try Data(contentsOf: manifestURL, options: .mappedIfSafe)
            )
            guard manifest.characterID == configuration.characterID else {
                throw CharacterVocalBlendShapeError.invalidDescriptor(
                    "CharacterVocalVisemeCatalog.\(configuration.characterID).manifestCharacter"
                )
            }
            let audioURL = try resourceURL(
                bundle: bundle,
                logicalPath: manifest.audioResourcePath
            )
            let audioHash = try sha256(url: audioURL)
            let track = try validateAndAdapt(
                manifest,
                entry: entry,
                descriptorHash: descriptorHash,
                audioHash: audioHash
            )
            guard tracks.updateValue(track, forKey: track.identity) == nil else {
                throw CharacterVocalBlendShapeError.invalidDescriptor(
                    "CharacterVocalVisemeCatalog.\(configuration.characterID).duplicateIdentity"
                )
            }
        }
        guard tracks.count == 9 else {
            throw CharacterVocalBlendShapeError.invalidDescriptor(
                "CharacterVocalVisemeCatalog.\(configuration.characterID).trackCount"
            )
        }
        return tracks
    }

    nonisolated static func validateAndAdapt(
        _ manifest: CharacterVocalVisemeManifest,
        entry: CharacterVocalVisemeCatalog.Entry,
        descriptorHash: String,
        audioHash: String
    ) throws -> CharacterVocalVisemeTrack {
        guard let configuration = Configuration.resolve(
            characterID: manifest.characterID
        ) else {
            throw CharacterVocalBlendShapeError.invalidDescriptor(
                "CharacterVocalVisemeManifest.unsupportedCharacter"
            )
        }
        let timeline = manifest.timeline
        let expectedFrameCount = (timeline.sampleCount + 799) / 800
        let expectedDuration = Double(timeline.sampleCount) / 48_000
        let expectedAudioPath = entry.role == .presenceLoop
            ? entry.audioFile
            : "Audio/\(entry.audioFile)"
        let alignment = manifest.alignment
        guard manifest.schemaVersion == 1,
              manifest.compilerVersion == compilerVersion,
              manifest.trackID == "\(configuration.characterID).\(entry.role.rawValue)." +
                URL(fileURLWithPath: entry.audioFile).deletingPathExtension().lastPathComponent +
                ".visemes",
              manifest.characterID == configuration.characterID,
              manifest.role == entry.role,
              manifest.audioFile == entry.audioFile,
              manifest.audioResourcePath == expectedAudioPath,
              manifest.audioSHA256 == entry.audioSHA256,
              manifest.audioSHA256 == audioHash,
              manifest.blendShapeDescriptorResourcePath == configuration.descriptorPath,
              manifest.blendShapeDescriptorSHA256 == descriptorHash,
              manifest.looping == entry.looping,
              timeline.sampleRate == 48_000,
              timeline.sampleCount > 0,
              timeline.framesPerSecond == 60,
              timeline.samplesPerNominalFrame == 800,
              timeline.frameCount == expectedFrameCount,
              abs(timeline.durationSeconds - expectedDuration) <= 0.5 / 48_000,
              manifest.requiredPoseFamilies == requiredPoses,
              alignment.mode == "pocketsphinxAllPhone",
              alignment.engine == "pocketsphinx",
              alignment.engineVersion == "5.1.1",
              alignment.engineCommit == engineCommit,
              alignment.resourceTreeSHA256 == resourceTreeSHA256,
              alignment.acousticModelSHA256 == acousticModelSHA256,
              alignment.phoneLanguageModelSHA256 == phoneLanguageModelSHA256,
              alignment.transcriptSHA256 == nil,
              alignment.vadModelSHA256 == vadModelSHA256,
              alignment.phonePoseMapSHA256 == phonePoseMapSHA256,
              alignment.speechBoundaryPolicy == speechBoundaryPolicy,
              isLowercaseSHA256(manifest.runsSHA256),
              !manifest.runs.isEmpty else {
            throw CharacterVocalBlendShapeError.invalidDescriptor(
                "CharacterVocalVisemeManifest.\(entry.audioFile).identity"
            )
        }

        var cursor = 0
        var previousPose: MindEyeMouthPose?
        var counts = Dictionary(uniqueKeysWithValues: requiredPoses.map { ($0.rawValue, 0) })
        var runs = ContiguousArray<CharacterVocalVisemeTrack.Run>()
        runs.reserveCapacity(manifest.runs.count)
        for run in manifest.runs {
            guard run.startFrame == cursor,
                  run.endFrameExclusive > run.startFrame,
                  run.endFrameExclusive <= timeline.frameCount,
                  run.pose != previousPose else {
                throw CharacterVocalBlendShapeError.invalidDescriptor(
                    "CharacterVocalVisemeManifest.\(entry.audioFile).runs"
                )
            }
            counts[run.pose.rawValue, default: 0] += run.endFrameExclusive - run.startFrame
            runs.append(.init(
                startFrame: run.startFrame,
                endFrameExclusive: run.endFrameExclusive,
                pose: run.pose
            ))
            cursor = run.endFrameExclusive
            previousPose = run.pose
        }
        let speechFrames = timeline.frameCount - counts[MindEyeMouthPose.rest.rawValue, default: 0]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encodedRuns = try encoder.encode(manifest.runs)
        guard cursor == timeline.frameCount,
              manifest.summary.poseFrameCounts == counts,
              manifest.summary.speechFrameCount == speechFrames,
              manifest.summary.silenceFrameCount == counts[MindEyeMouthPose.rest.rawValue],
              manifest.summary.unknownPhoneCount >= 0,
              manifest.summary.runCount == manifest.runs.count,
              sha256(data: encodedRuns) == manifest.runsSHA256 else {
            throw CharacterVocalBlendShapeError.invalidDescriptor(
                "CharacterVocalVisemeManifest.\(entry.audioFile).summary"
            )
        }
        let identity = CharacterVocalVisemeTrackIdentity(
            characterID: manifest.characterID,
            role: manifest.role,
            audioFile: manifest.audioFile,
            audioSHA256: manifest.audioSHA256,
            looping: manifest.looping
        )
        return CharacterVocalVisemeTrack(
            trackID: manifest.trackID,
            identity: identity,
            sampleRate: timeline.sampleRate,
            sampleCount: timeline.sampleCount,
            framesPerSecond: timeline.framesPerSecond,
            frameCount: timeline.frameCount,
            runsSHA256: manifest.runsSHA256,
            runs: runs
        )
    }

    private nonisolated static func resourceURL(
        bundle: Bundle,
        logicalPath: String
    ) throws -> URL {
        guard isSafeResourcePath(logicalPath) else {
            throw CharacterVocalBlendShapeError.missingResource(logicalPath)
        }
        let components = logicalPath.split(separator: "/").map(String.init)
        guard let fileName = components.last else {
            throw CharacterVocalBlendShapeError.missingResource(logicalPath)
        }
        let fileURL = URL(fileURLWithPath: fileName)
        let name = fileURL.deletingPathExtension().lastPathComponent
        let fileExtension = fileURL.pathExtension
        let subdirectory = components.dropLast().isEmpty
            ? nil
            : components.dropLast().joined(separator: "/")
        if let url = bundle.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) ?? bundle.url(forResource: name, withExtension: fileExtension) {
            return url
        }
        throw CharacterVocalBlendShapeError.missingResource(logicalPath)
    }

    private nonisolated static func isSafeResourcePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private nonisolated static func sha256(url: URL) throws -> String {
        sha256(data: try Data(contentsOf: url, options: .mappedIfSafe))
    }

    private nonisolated static func sha256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1.0e18
    }
}
