import Foundation

actor TuringFillerCatalogActor {
    private struct PublishedIndex: Decodable {
        struct Entry: Decodable {
            let fillerID: String
            let speakerCharacterID: TuringConversationCharacterID
            let audioResourcePath: String
            let audioSHA256: String
            let weight: Int
            let authoringMode: TuringFillerAuthoringMode
            let trackResourcePath: String
            let trackSHA256: String
        }
        let schemaVersion: Int
        let indexVersion: String
        let entries: [Entry]
    }

    private struct Key: Hashable {
        let characterID: String
        let directoryCandidates: [String]
        let extensions: [String]
    }

    private var cache: [Key: TuringFillerCatalog] = [:]

    func catalog(
        characterID: String,
        directoryCandidates: [String],
        extensions: Set<String>
    ) throws -> TuringFillerCatalog {
        let key = Key(
            characterID: characterID,
            directoryCandidates: directoryCandidates,
            extensions: extensions.sorted()
        )
        if let existing = cache[key] {
            return existing
        }
        TuringAudioOffloadSignposts.assertNotMainThread("fillerDiscovery")

        if let published = try loadPublishedCatalog(characterID: characterID) {
            cache[key] = published
            return published
        }

        var unique: [URL] = []
        for candidate in directoryCandidates {
            let urls = [
                Bundle.main.resourceURL?.appendingPathComponent(
                    candidate,
                    isDirectory: true
                ),
                Bundle.main.url(
                    forResource: (candidate as NSString).lastPathComponent,
                    withExtension: nil
                ),
                URL(fileURLWithPath: candidate)
            ].compactMap { $0 }

            for directory in urls {
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ) else {
                    continue
                }
                unique.append(contentsOf: files.filter {
                    extensions.contains($0.pathExtension.lowercased())
                })
            }
        }

        let speaker = TuringConversationCharacterID(rawValue: characterID)
        let clips = Set(unique).sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }).map { file in
            let stem = file.deletingPathExtension().lastPathComponent
            return TuringFillerClipDescriptor(
                identity: TuringFillerClipIdentity(
                    fillerID: "untracked.\(characterID).\(stem)",
                    speakerCharacterID: speaker ?? .bigMike,
                    audioResourcePath: file.lastPathComponent,
                    audioSHA256: nil,
                    trackResourcePath: nil,
                    trackSHA256: nil
                ),
                fileURL: file,
                weight: parsedWeight(from: file),
                authoringMode: .untrackedFallback
            )
        }
        let result = TuringFillerCatalog(clips: clips)
        cache[key] = result
        return result
    }

    func clear() {
        cache.removeAll(keepingCapacity: false)
    }

    private func parsedWeight(from fileURL: URL) -> Int {
        let stem = fileURL.deletingPathExtension().lastPathComponent.lowercased()
        let patterns = ["weight-", "weight_", "w-"]
        for pattern in patterns {
            guard let range = stem.range(of: pattern, options: .backwards) else {
                continue
            }
            let suffix = stem[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            if let value = Int(digits), value > 0 {
                return min(value, 100)
            }
        }
        if let token = stem.split(separator: "_").last,
           let value = Int(token), value > 0 {
            return min(value, 100)
        }
        return 1
    }

    private func loadPublishedCatalog(
        characterID: String
    ) throws -> TuringFillerCatalog? {
        guard let resourceRoot = Bundle.main.resourceURL else { return nil }
        let indexURL = resourceRoot.appendingPathComponent(
            "Turing/MindsEye/Fillers/index.json"
        )
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let index = try JSONDecoder().decode(
            PublishedIndex.self,
            from: Data(contentsOf: indexURL, options: .mappedIfSafe)
        )
        guard index.schemaVersion == 1,
              index.indexVersion == "mind-eye-filler-index/1" else {
            throw TuringRuntimeError.invalidConfig("Unsupported Mind's Eye filler index.")
        }
        let entries = index.entries
            .filter { $0.speakerCharacterID.rawValue == characterID }
            .sorted { $0.fillerID < $1.fillerID }
        let clips = try entries.map { entry in
            let fileURL = resourceRoot.appendingPathComponent(entry.audioResourcePath)
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  (1...100).contains(entry.weight) else {
                throw TuringRuntimeError.invalidConfig(
                    "Published filler audio/weight is invalid: \(entry.fillerID)"
                )
            }
            return TuringFillerClipDescriptor(
                identity: TuringFillerClipIdentity(
                    fillerID: entry.fillerID,
                    speakerCharacterID: entry.speakerCharacterID,
                    audioResourcePath: entry.audioResourcePath,
                    audioSHA256: entry.audioSHA256,
                    trackResourcePath: entry.trackResourcePath,
                    trackSHA256: entry.trackSHA256
                ),
                fileURL: fileURL,
                weight: entry.weight,
                authoringMode: entry.authoringMode
            )
        }
        return clips.isEmpty ? nil : TuringFillerCatalog(clips: clips)
    }
}
