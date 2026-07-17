import Foundation

actor TuringFillerCatalogActor {
    struct Catalog: Sendable {
        let weightedURLs: [URL]
    }

    private struct Key: Hashable {
        let characterID: String
        let directoryCandidates: [String]
        let extensions: [String]
    }

    private var cache: [Key: Catalog] = [:]

    func catalog(
        characterID: String,
        directoryCandidates: [String],
        extensions: Set<String>
    ) throws -> Catalog {
        let key = Key(
            characterID: characterID,
            directoryCandidates: directoryCandidates,
            extensions: extensions.sorted()
        )
        if let existing = cache[key] {
            return existing
        }
        TuringAudioOffloadSignposts.assertNotMainThread("fillerDiscovery")

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

        var weighted: [URL] = []
        for file in Set(unique).sorted(by: {
            $0.lastPathComponent < $1.lastPathComponent
        }) {
            weighted.append(
                contentsOf: Array(repeating: file, count: parsedWeight(from: file))
            )
        }
        let result = Catalog(weightedURLs: weighted)
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
}
