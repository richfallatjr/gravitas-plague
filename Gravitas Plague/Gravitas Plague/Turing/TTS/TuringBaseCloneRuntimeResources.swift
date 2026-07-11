import Foundation

struct TuringBaseCloneRuntimeResources: Sendable {
  static let modelFolderName =
    "Qwen3-TTS-12Hz-1.7B-Base-4bit"

  func locateBundledModel(
    bundle: Bundle = .main
  ) throws -> URL {
    let candidates = [
      "Turing/Models/Qwen3TTS/\(Self.modelFolderName)",
      "TuringResources/Turing/Models/Qwen3TTS/\(Self.modelFolderName)",
    ]

    for candidate in candidates {
      if let url = bundle.url(
        forResource: candidate,
        withExtension: nil
      ) {
        return url
      }
    }

    let available = bundledQwenModelFolderNames(bundle: bundle)
    let summary =
      available.isEmpty
      ? "none"
      : available.joined(separator: ", ")

    throw NSError(
      domain: "TuringBaseCloneRuntimeResources",
      code: 1,
      userInfo: [
        NSLocalizedDescriptionKey:
          "Bundled Qwen Base 4-bit model not found. " + "Expected \(Self.modelFolderName). "
          + "Available Qwen model folders: \(summary)."
      ]
    )
  }

  func stageWritableModel(
    from source: URL
  ) throws -> URL {
    let fileManager = FileManager.default
    let appSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )

    let stageContainer =
      appSupport
      .appendingPathComponent(
        "TuringQwenNativeBaseClone",
        isDirectory: true
      )
    let writableModelRoot =
      stageContainer
      .appendingPathComponent(
        "WritableModel",
        isDirectory: true
      )
    let stagedRoot =
      writableModelRoot
      .appendingPathComponent(
        source.lastPathComponent,
        isDirectory: true
      )

    try fileManager.createDirectory(
      at: stageContainer,
      withIntermediateDirectories: true
    )

    try removeLegacyWritableStages(
      stageContainer: stageContainer,
      preserving: writableModelRoot
    )

    if fileManager.fileExists(atPath: stagedRoot.path),
      isWritableModelStageUsable(stagedRoot)
    {
      try markExcludedFromBackup(stagedRoot)
      try verifyWritable(stagedRoot)

      print(
        """
        [TuringBaseCloneRuntime] writable stage ready
          source: \(source.path)
          staged: \(stagedRoot.path)
          writable: true
          reusedExistingStage: true
        """)

      return stagedRoot
    }

    if fileManager.fileExists(atPath: stagedRoot.path) {
      try fileManager.removeItem(at: stagedRoot)
    }

    try fileManager.createDirectory(
      at: writableModelRoot,
      withIntermediateDirectories: true
    )
    try fileManager.copyItem(
      at: source,
      to: stagedRoot
    )
    try markExcludedFromBackup(stagedRoot)
    try verifyWritable(stagedRoot)

    print(
      """
      [TuringBaseCloneRuntime] writable stage ready
        source: \(source.path)
        staged: \(stagedRoot.path)
        writable: true
        reusedExistingStage: false
      """)

    return stagedRoot
  }

  private func bundledQwenModelFolderNames(
    bundle: Bundle
  ) -> [String] {
    let fileManager = FileManager.default
    let candidates = [
      bundle.url(
        forResource: "Turing/Models/Qwen3TTS",
        withExtension: nil
      ),
      bundle.url(
        forResource: "TuringResources/Turing/Models/Qwen3TTS",
        withExtension: nil
      ),
    ]

    for candidate in candidates {
      guard let root = candidate,
        let contents = try? fileManager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      else {
        continue
      }

      let names = contents.compactMap { url -> String? in
        guard
          (try? url.resourceValues(
            forKeys: [.isDirectoryKey]
          ).isDirectory) == true
        else {
          return nil
        }

        return url.lastPathComponent
      }

      if names.isEmpty == false {
        return names.sorted()
      }
    }

    return []
  }

  private func removeLegacyWritableStages(
    stageContainer: URL,
    preserving writableModelRoot: URL
  ) throws {
    let fileManager = FileManager.default
    guard
      let contents = try? fileManager.contentsOfDirectory(
        at: stageContainer,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }

    for url in contents
    where url.standardizedFileURL != writableModelRoot.standardizedFileURL {
      try? fileManager.removeItem(at: url)
    }
  }

  private func isWritableModelStageUsable(
    _ root: URL
  ) -> Bool {
    let required = [
      "config.json",
      "generation_config.json",
      "model.safetensors",
      "model.safetensors.index.json",
      "tokenizer_config.json",
      "vocab.json",
      "merges.txt",
      "speech_tokenizer/config.json",
      "speech_tokenizer/model.safetensors",
    ]

    return required.allSatisfy { relativePath in
      FileManager.default.fileExists(
        atPath:
          root
          .appendingPathComponent(relativePath)
          .path
      )
    }
  }

  private func markExcludedFromBackup(
    _ root: URL
  ) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true

    var mutableRoot = root
    try mutableRoot.setResourceValues(values)
  }

  private func verifyWritable(
    _ root: URL
  ) throws {
    let probe = root.appendingPathComponent(".write-probe")
    try Data("ok".utf8).write(to: probe)
    try FileManager.default.removeItem(at: probe)
  }
}
