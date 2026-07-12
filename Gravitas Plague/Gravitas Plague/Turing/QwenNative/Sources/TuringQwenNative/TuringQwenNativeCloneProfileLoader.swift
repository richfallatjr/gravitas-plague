import Foundation

public struct TuringQwenNativeCloneProfileLoader: Sendable {
  public init() {}

  public func loadBigMikeBaseCloneProfile(
    from bundleRoot: URL,
    voiceID: String = "big_mike_base_clone_v1"
  ) throws -> TuringQwenNativeCloneProfile {
    try loadBaseCloneProfile(
      from: bundleRoot,
      profileResourcePath:
        "Turing/Voices/Cloned/BigMike/BaseClone/\(voiceID).qwenclone",
      expectedVoiceID: voiceID,
      expectedCharacterID: "big_mike",
      logPrefix: "Big Mike"
    )
  }

  public func loadRichBaseCloneProfile(
    from bundleRoot: URL,
    voiceID: String = "rich_base_clone_v1"
  ) throws -> TuringQwenNativeCloneProfile {
    try loadBaseCloneProfile(
      from: bundleRoot,
      profileResourcePath:
        "Turing/Voices/Cloned/Rich/BaseClone/\(voiceID).qwenclone",
      expectedVoiceID: voiceID,
      expectedCharacterID: "rich",
      logPrefix: "Rich"
    )
  }

  public func loadBaseCloneProfile(
    from bundleRoot: URL,
    profileResourcePath: String,
    expectedVoiceID: String,
    expectedCharacterID: String,
    logPrefix: String
  ) throws -> TuringQwenNativeCloneProfile {
    let profileRoot = bundleRoot.appendingPathComponent(
      profileResourcePath,
      isDirectory: true
    )

    guard
      FileManager.default.fileExists(
        atPath: profileRoot.path
      )
    else {
      throw
        TuringQwenNativeError
        .nativeGenerationNotImplemented(
          "Missing \(logPrefix) Base clone profile at \(profileRoot.path)."
        )
    }

    let metadataURL =
      profileRoot
      .appendingPathComponent("metadata.json")
    let metadata = try loadMetadata(
      from: metadataURL
    )

    guard metadata.voiceID == expectedVoiceID else {
      throw
        TuringQwenNativeError
        .invalidConfig(
          "Expected voiceID \(expectedVoiceID), got \(metadata.voiceID)."
        )
    }
    guard metadata.characterID == expectedCharacterID else {
      throw
        TuringQwenNativeError
        .invalidConfig(
          "Expected characterID \(expectedCharacterID), got \(metadata.characterID)."
        )
    }
    guard metadata.modelID == "qwen3-tts-12hz-1.7b-base-4bit",
      metadata.profileKind == "qwenBaseCloneReferenceProfile"
    else {
      throw
        TuringQwenNativeError
        .invalidConfig(
          "\(logPrefix) clone must target the Base 4-bit clone profile."
        )
    }
    guard metadata.allowFallback == false,
      metadata.allowRuntimeRefAudioEncoding == false,
      metadata.allowPrerecordedDialoguePlayback == false
    else {
      throw
        TuringQwenNativeError
        .invalidConfig(
          "\(logPrefix) fallback/playback flags are invalid."
        )
    }

    guard
      let variantRef =
        metadata.variants.first(
          where: {
            $0.variantID == metadata.defaultVariantID
          }
        )
    else {
      throw
        TuringQwenNativeError
        .invalidConfig(
          "Missing default variant \(metadata.defaultVariantID)."
        )
    }

    let variantManifestURL =
      profileRoot.appendingPathComponent(
        variantRef.path
      )
    let variant = try loadVariant(
      from: variantManifestURL
    )

    guard variant.variantID == metadata.defaultVariantID,
      variant.voiceID == metadata.voiceID,
      variant.characterID == metadata.characterID,
      variant.kind == "baseCloneReferenceVariant",
      variant.allowFallback == false,
      variant.allowPrerecordedDialoguePlayback == false
    else {
      throw
        TuringQwenNativeError
        .invalidConfig(
          "\(logPrefix) variant metadata does not match its profile."
        )
    }
    guard variant.reference.sampleRate == 24_000,
      variant.reference.channels == 1,
      variant.reference.normalizedFormat == "wav_float32_le"
    else {
      throw
        TuringQwenNativeError
        .invalidConfig(
          "\(logPrefix) reference must be 24 kHz mono float32 WAV."
        )
    }

    let variantRoot =
      variantManifestURL
      .deletingLastPathComponent()
    let originalURL =
      variantRoot.appendingPathComponent(
        variant.reference
          .originalAudioPath
      )
    let normalizedURL =
      variantRoot.appendingPathComponent(
        variant.reference
          .normalizedAudioPath
      )
    let textURL =
      variantRoot.appendingPathComponent(
        variant.reference.textPath
      )

    try requireNonEmptyFile(
      originalURL,
      label:
        "\(logPrefix) original audio"
    )
    try requireNonEmptyFile(
      normalizedURL,
      label:
        "\(logPrefix) normalized audio"
    )
    try requireNonEmptyFile(
      textURL,
      label:
        "\(logPrefix) reference text"
    )

    let artifactPaths =
      try resolvedArtifactPaths(
        variant: variant,
        variantRoot: variantRoot,
        logPrefix: logPrefix
      )

    try requireNonEmptyFile(
      artifactPaths
        .clonePromptManifestURL,
      label:
        "\(logPrefix) clone prompt manifest"
    )
    try requireNonEmptyFile(
      artifactPaths.referenceCodesURL,
      label:
        "\(logPrefix) reference codes"
    )
    try requireNonEmptyFile(
      artifactPaths
        .referenceTextTokensURL,
      label:
        "\(logPrefix) reference text tokens"
    )
    try requireNonEmptyFile(
      artifactPaths.speakerEmbeddingURL,
      label:
        "\(logPrefix) speaker embedding"
    )

    let referenceText =
      try String(
        contentsOf: textURL,
        encoding: .utf8
      )
      .trimmingCharacters(
        in: .whitespacesAndNewlines
      )
    guard referenceText.isEmpty == false else {
      throw
        TuringQwenNativeError
        .missingModelFile(
          "\(logPrefix) reference text is empty."
        )
    }

    let loadedVariant =
      TuringQwenNativeCloneProfile
      .Variant(
        variantID:
          variant.variantID,
        rootURL: variantRoot,
        manifestURL:
          variantManifestURL,
        originalReferenceAudioURL:
          originalURL,
        normalizedReferenceAudioURL:
          normalizedURL,
        refTextURL: textURL,
        clonePromptManifestURL:
          artifactPaths
          .clonePromptManifestURL,
        referenceCodesURL:
          artifactPaths
          .referenceCodesURL,
        referenceTextTokensURL:
          artifactPaths
          .referenceTextTokensURL,
        speakerEmbeddingURL:
          artifactPaths
          .speakerEmbeddingURL,
        sampleRate:
          variant.reference
          .sampleRate,
        channels:
          variant.reference
          .channels
      )

    print(
      """
      [TuringCloneProfile] profile loaded
        characterID: \(metadata.characterID)
        voiceID: \(metadata.voiceID)
        defaultVariantID: \(metadata.defaultVariantID)
        sharedModelID: \(metadata.modelID)
        fallbackAllowed: false
        runtimeReferenceEncoding: false
      """)

    if metadata.characterID == "rich" {
      print(
        """
        [TuringRichClone] profile loaded
          characterID: rich
          voiceID: \(metadata.voiceID)
          defaultVariantID: \(metadata.defaultVariantID)
          fallbackAllowed: false
        """)
    }

    return TuringQwenNativeCloneProfile(
      voiceID: metadata.voiceID,
      speakerID: metadata.characterID,
      modelID: metadata.modelID,
      profileKind:
        metadata.profileKind,
      rootURL: profileRoot,
      referenceAudioURL:
        normalizedURL,
      originalReferenceAudioURL:
        originalURL,
      referenceText: referenceText,
      defaultVariantID:
        metadata.defaultVariantID,
      allowFallback: false,
      variants: [
        loadedVariant.variantID:
          loadedVariant
      ]
    )
  }

  private func resolvedArtifactPaths(
    variant: VariantManifest,
    variantRoot: URL,
    logPrefix: String
  ) throws -> ArtifactPaths {
    let artifacts = variant.qwenArtifacts
    let status =
      artifacts?.status ?? "notPrecomputed"

    guard status == "precomputed" || status == "ready" else {
      throw
        TuringQwenNativeError
        .nativeGenerationNotImplemented(
          "Missing \(logPrefix) Qwen clone artifacts for variant "
            + "\(variant.variantID). Run the character-specific "
            + "offline precompute script before launching the app."
        )
    }

    let cloneManifest =
      variantRoot.appendingPathComponent(
        artifacts?.path ?? artifacts?
          .clonePromptManifestPath ?? "qwen_artifacts/clone_prompt_manifest.json"
      )
    let referenceCodes =
      variantRoot.appendingPathComponent(
        artifacts?
          .referenceCodesPath ?? "qwen_artifacts/reference_codes.i32le"
      )
    let referenceTextTokens =
      variantRoot.appendingPathComponent(
        artifacts?
          .referenceTextTokensPath ?? "qwen_artifacts/ref_text_tokens.i32le"
      )
    let speakerEmbedding =
      variantRoot.appendingPathComponent(
        artifacts?
          .speakerEmbeddingPath ?? "qwen_artifacts/speaker_embedding.f32le"
      )

    return ArtifactPaths(
      clonePromptManifestURL:
        cloneManifest,
      referenceCodesURL:
        referenceCodes,
      referenceTextTokensURL:
        referenceTextTokens,
      speakerEmbeddingURL:
        speakerEmbedding
    )
  }

  private func loadMetadata(
    from url: URL
  ) throws -> Metadata {
    let data = try Data(
      contentsOf: url
    )
    return try JSONDecoder()
      .decode(
        Metadata.self,
        from: data
      )
  }

  private func loadVariant(
    from url: URL
  ) throws -> VariantManifest {
    let data = try Data(
      contentsOf: url
    )
    return try JSONDecoder()
      .decode(
        VariantManifest.self,
        from: data
      )
  }

  private func requireNonEmptyFile(
    _ url: URL,
    label: String
  ) throws {
    guard
      FileManager.default
        .fileExists(
          atPath: url.path
        )
    else {
      throw
        TuringQwenNativeError
        .missingModelFile(
          "\(label): \(url.lastPathComponent)"
        )
    }

    let values =
      try url.resourceValues(
        forKeys: [.fileSizeKey]
      )
    guard
      let fileSize =
        values.fileSize,
      fileSize > 0
    else {
      throw
        TuringQwenNativeError
        .missingModelFile(
          "\(label) is empty: \(url.lastPathComponent)"
        )
    }
  }

  private struct Metadata: Decodable {
    let voiceID: String
    let characterID: String
    let modelID: String
    let profileKind: String
    let defaultVariantID: String
    let allowFallback: Bool
    let allowRuntimeRefAudioEncoding: Bool
    let allowPrerecordedDialoguePlayback: Bool
    let variants: [VariantRef]
  }

  private struct VariantRef: Decodable {
    let variantID: String
    let path: String
  }

  private struct VariantManifest:
    Decodable
  {
    let variantID: String
    let voiceID: String
    let characterID: String
    let kind: String
    let reference: Reference
    let qwenArtifacts: QwenArtifacts?
    let allowFallback: Bool
    let allowPrerecordedDialoguePlayback: Bool
  }

  private struct Reference: Decodable {
    let originalAudioPath: String
    let normalizedAudioPath: String
    let textPath: String
    let sampleRate: Int
    let channels: Int
    let normalizedFormat: String
  }

  private struct QwenArtifacts:
    Decodable
  {
    let status: String
    let path: String?
    let clonePromptManifestPath: String?
    let referenceCodesPath: String?
    let referenceTextTokensPath: String?
    let speakerEmbeddingPath: String?
  }

  private struct ArtifactPaths {
    let clonePromptManifestURL: URL
    let referenceCodesURL: URL
    let referenceTextTokensURL: URL
    let speakerEmbeddingURL: URL
  }
}
