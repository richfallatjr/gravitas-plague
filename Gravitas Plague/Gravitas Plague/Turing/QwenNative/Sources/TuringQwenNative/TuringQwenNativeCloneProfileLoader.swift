import Foundation

public struct TuringQwenNativeCloneProfileLoader: Sendable {
    public init() {}

    public func loadBigMikeBaseCloneProfile(
        from bundleRoot: URL,
        voiceID: String = "big_mike_base_clone_v1"
    ) throws -> TuringQwenNativeCloneProfile {
        let profileRoot = bundleRoot
            .appendingPathComponent("Turing/Voices/Cloned/BigMike/BaseClone", isDirectory: true)
            .appendingPathComponent("\(voiceID).qwenclone", isDirectory: true)

        guard FileManager.default.fileExists(atPath: profileRoot.path) else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Missing Big Mike Base clone profile resources at \(profileRoot.path)."
            )
        }

        let metadataURL = profileRoot.appendingPathComponent("metadata.json")
        let metadata = try loadMetadata(from: metadataURL)
        guard metadata.voiceID == voiceID else {
            throw TuringQwenNativeError.invalidConfig(
                "Clone profile voiceID must be \(voiceID), got \(metadata.voiceID)."
            )
        }
        guard metadata.modelID == "qwen3-tts-12hz-1.7b-base-4bit",
              metadata.profileKind == "qwenBaseCloneReferenceProfile" else {
            throw TuringQwenNativeError.invalidConfig(
                "Big Mike clone profile must target Base 4-bit qwenBaseCloneReferenceProfile."
            )
        }
        guard metadata.allowFallback == false,
              metadata.allowPrerecordedDialoguePlayback == false else {
            throw TuringQwenNativeError.invalidConfig(
                "Big Mike clone profile fallback/playback flags are invalid."
            )
        }

        guard let variantRef = metadata.variants.first(where: { $0.variantID == metadata.defaultVariantID }) else {
            throw TuringQwenNativeError.invalidConfig(
                "Big Mike clone profile missing default variant \(metadata.defaultVariantID)."
            )
        }

        let variantManifestURL = profileRoot.appendingPathComponent(variantRef.path)
        let variant = try loadVariant(from: variantManifestURL)
        guard variant.variantID == metadata.defaultVariantID,
              variant.voiceID == metadata.voiceID,
              variant.characterID == metadata.characterID,
              variant.kind == "baseCloneReferenceVariant",
              variant.allowFallback == false,
              variant.allowPrerecordedDialoguePlayback == false else {
            throw TuringQwenNativeError.invalidConfig(
                "Big Mike clone variant metadata does not match profile requirements."
            )
        }
        guard variant.reference.sampleRate == 24_000,
              variant.reference.channels == 1,
              variant.reference.normalizedFormat == "wav_float32_le" else {
            throw TuringQwenNativeError.invalidConfig(
                "Big Mike clone variant must provide 24 kHz mono float32 WAV conditioning audio."
            )
        }

        let variantRoot = variantManifestURL.deletingLastPathComponent()
        let originalReferenceAudioURL = variantRoot.appendingPathComponent(
            variant.reference.originalAudioPath
        )
        let normalizedReferenceAudioURL = variantRoot.appendingPathComponent(
            variant.reference.normalizedAudioPath
        )
        let referenceTextURL = variantRoot.appendingPathComponent(
            variant.reference.textPath
        )

        try requireNonEmptyFile(originalReferenceAudioURL, label: "Big Mike original reference audio")
        try requireNonEmptyFile(normalizedReferenceAudioURL, label: "Big Mike normalized reference audio")
        try requireNonEmptyFile(referenceTextURL, label: "Big Mike reference text")
        let artifactPaths = try resolvedArtifactPaths(
            variant: variant,
            variantRoot: variantRoot
        )
        try requireNonEmptyFile(
            artifactPaths.clonePromptManifestURL,
            label: "Big Mike clone prompt manifest"
        )
        try requireNonEmptyFile(
            artifactPaths.referenceCodesURL,
            label: "Big Mike reference codes"
        )
        try requireNonEmptyFile(
            artifactPaths.referenceTextTokensURL,
            label: "Big Mike reference text tokens"
        )
        try requireNonEmptyFile(
            artifactPaths.speakerEmbeddingURL,
            label: "Big Mike speaker embedding"
        )

        let referenceText = try String(contentsOf: referenceTextURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard referenceText.isEmpty == false else {
            throw TuringQwenNativeError.missingModelFile("Big Mike reference text is empty")
        }

        print("""
        [TuringQwenNativeBaseClone] profile loaded
          voiceID: \(metadata.voiceID)
          profileKind: \(metadata.profileKind)
          modelID: \(metadata.modelID)
          defaultVariantID: \(metadata.defaultVariantID)
          refAudioOriginal: \(originalReferenceAudioURL.lastPathComponent)
          refAudioNormalized: \(normalizedReferenceAudioURL.lastPathComponent)
          refTextCharacters: \(referenceText.utf16.count)
          rawReferenceRuntime: false
          precomputedCloneArtifacts: true
          clonePromptManifest: \(artifactPaths.clonePromptManifestURL.lastPathComponent)
          allowFallback: false
        """)

        let loadedVariant = TuringQwenNativeCloneProfile.Variant(
            variantID: variant.variantID,
            rootURL: variantRoot,
            manifestURL: variantManifestURL,
            originalReferenceAudioURL: originalReferenceAudioURL,
            normalizedReferenceAudioURL: normalizedReferenceAudioURL,
            refTextURL: referenceTextURL,
            clonePromptManifestURL: artifactPaths.clonePromptManifestURL,
            referenceCodesURL: artifactPaths.referenceCodesURL,
            referenceTextTokensURL: artifactPaths.referenceTextTokensURL,
            speakerEmbeddingURL: artifactPaths.speakerEmbeddingURL,
            sampleRate: variant.reference.sampleRate,
            channels: variant.reference.channels
        )

        return TuringQwenNativeCloneProfile(
            voiceID: metadata.voiceID,
            speakerID: metadata.characterID,
            modelID: metadata.modelID,
            profileKind: metadata.profileKind,
            rootURL: profileRoot,
            referenceAudioURL: normalizedReferenceAudioURL,
            originalReferenceAudioURL: originalReferenceAudioURL,
            referenceText: referenceText,
            defaultVariantID: metadata.defaultVariantID,
            allowFallback: false,
            variants: [loadedVariant.variantID: loadedVariant]
        )
    }

    private func resolvedArtifactPaths(
        variant: VariantManifest,
        variantRoot: URL
    ) throws -> ArtifactPaths {
        let artifacts = variant.qwenArtifacts
        let status = artifacts?.status ?? "notPrecomputed"
        guard status == "precomputed" || status == "ready" else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Missing Big Mike Qwen clone artifacts. Run Scripts/precompute_big_mike_clone_artifacts.sh."
            )
        }

        let cloneManifest = variantRoot.appendingPathComponent(
            artifacts?.path ?? artifacts?.clonePromptManifestPath ?? "qwen_artifacts/clone_prompt_manifest.json"
        )
        let referenceCodes = variantRoot.appendingPathComponent(
            artifacts?.referenceCodesPath ?? "qwen_artifacts/reference_codes.i32le"
        )
        let referenceTextTokens = variantRoot.appendingPathComponent(
            artifacts?.referenceTextTokensPath ?? "qwen_artifacts/ref_text_tokens.i32le"
        )
        let speakerEmbedding = variantRoot.appendingPathComponent(
            artifacts?.speakerEmbeddingPath ?? "qwen_artifacts/speaker_embedding.f32le"
        )

        return ArtifactPaths(
            clonePromptManifestURL: cloneManifest,
            referenceCodesURL: referenceCodes,
            referenceTextTokensURL: referenceTextTokens,
            speakerEmbeddingURL: speakerEmbedding
        )
    }

    private func loadMetadata(from url: URL) throws -> Metadata {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Metadata.self, from: data)
    }

    private func loadVariant(from url: URL) throws -> VariantManifest {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(VariantManifest.self, from: data)
    }

    private func requireNonEmptyFile(
        _ url: URL,
        label: String
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TuringQwenNativeError.missingModelFile("\(label): \(url.lastPathComponent)")
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize,
              fileSize > 0 else {
            throw TuringQwenNativeError.missingModelFile("\(label) is empty: \(url.lastPathComponent)")
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

    private struct VariantManifest: Decodable {
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

    private struct QwenArtifacts: Decodable {
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
