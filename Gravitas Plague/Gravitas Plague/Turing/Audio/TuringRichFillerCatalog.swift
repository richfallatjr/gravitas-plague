import Foundation

struct TuringRichFillerCatalog: Sendable {
  private let weightedEntries: [URL]

  init(bundle: Bundle = .main) {
    weightedEntries = Self.discover(bundle: bundle)
  }

  init(weightedEntries: [URL]) {
    self.weightedEntries = weightedEntries
  }

  var uniqueFileCount: Int {
    Set(weightedEntries.map(\.standardizedFileURL)).count
  }

  var weightedEntryCount: Int {
    weightedEntries.count
  }

  func randomURL(avoiding previous: URL?) -> URL? {
    guard weightedEntries.isEmpty == false else {
      return nil
    }

    if let previous,
      uniqueFileCount > 1
    {
      let standardizedPrevious = previous.standardizedFileURL
      return
        weightedEntries
        .filter {
          $0.standardizedFileURL != standardizedPrevious
        }
        .randomElement()
    }

    return weightedEntries.randomElement()
  }

  static func parsedWeight(from url: URL) -> Int {
    let stem = url.deletingPathExtension().lastPathComponent
    guard let suffix = stem.split(separator: "_").last,
      let value = Int(suffix)
    else {
      return 1
    }

    return max(1, min(10, value))
  }

  private static func discover(bundle: Bundle) -> [URL] {
    let supportedExtensions: Set<String> = [
      "wav",
      "mp3",
      "m4a",
      "aiff",
      "caf",
    ]

    var uniqueFilesByPath: [String: URL] = [:]

    for candidate in TuringRichVoiceIdentity.fillerDirectoryCandidates {
      let directories = [
        bundle.resourceURL?.appendingPathComponent(
          candidate,
          isDirectory: true
        ),
        bundle.bundleURL.appendingPathComponent(
          candidate,
          isDirectory: true
        ),
      ].compactMap { $0 }

      for directory in directories {
        guard
          let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
          )
        else {
          continue
        }

        for file in files {
          guard
            supportedExtensions.contains(
              file.pathExtension.lowercased()
            )
          else {
            continue
          }

          let standardized = file.standardizedFileURL
          uniqueFilesByPath[standardized.path] = standardized
        }
      }
    }

    return uniqueFilesByPath.values
      .sorted { $0.path < $1.path }
      .flatMap { file in
        Array(
          repeating: file,
          count: parsedWeight(from: file)
        )
      }
  }
}
