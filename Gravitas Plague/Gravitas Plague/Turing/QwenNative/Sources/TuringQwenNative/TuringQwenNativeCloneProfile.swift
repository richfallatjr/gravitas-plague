import Foundation

public struct TuringQwenNativeCloneProfile: Sendable {
    public let voiceID: String
    public let speakerID: String
    public let modelID: String
    public let profileKind: String
    public let rootURL: URL
    public let referenceAudioURL: URL
    public let originalReferenceAudioURL: URL
    public let referenceText: String
    public let defaultVariantID: String
    public let allowFallback: Bool
    public let variants: [String: Variant]

    public init(
        voiceID: String,
        speakerID: String,
        modelID: String,
        profileKind: String,
        rootURL: URL,
        referenceAudioURL: URL,
        originalReferenceAudioURL: URL,
        referenceText: String,
        defaultVariantID: String,
        allowFallback: Bool,
        variants: [String: Variant]
    ) {
        self.voiceID = voiceID
        self.speakerID = speakerID
        self.modelID = modelID
        self.profileKind = profileKind
        self.rootURL = rootURL
        self.referenceAudioURL = referenceAudioURL
        self.originalReferenceAudioURL = originalReferenceAudioURL
        self.referenceText = referenceText
        self.defaultVariantID = defaultVariantID
        self.allowFallback = allowFallback
        self.variants = variants
    }

    public func requireVariant(_ variantID: String) throws -> Variant {
        guard let variant = variants[variantID] else {
            throw TuringQwenNativeError.missingModelFile(
                "Base clone profile variant \(variantID) for \(voiceID)"
            )
        }

        return variant
    }

    public struct Variant: Sendable {
        public let variantID: String
        public let rootURL: URL
        public let manifestURL: URL
        public let originalReferenceAudioURL: URL
        public let normalizedReferenceAudioURL: URL
        public let refTextURL: URL
        public let clonePromptManifestURL: URL
        public let referenceCodesURL: URL
        public let referenceTextTokensURL: URL
        public let speakerEmbeddingURL: URL
        public let sampleRate: Int
        public let channels: Int

        public init(
            variantID: String,
            rootURL: URL,
            manifestURL: URL,
            originalReferenceAudioURL: URL,
            normalizedReferenceAudioURL: URL,
            refTextURL: URL,
            clonePromptManifestURL: URL,
            referenceCodesURL: URL,
            referenceTextTokensURL: URL,
            speakerEmbeddingURL: URL,
            sampleRate: Int,
            channels: Int
        ) {
            self.variantID = variantID
            self.rootURL = rootURL
            self.manifestURL = manifestURL
            self.originalReferenceAudioURL = originalReferenceAudioURL
            self.normalizedReferenceAudioURL = normalizedReferenceAudioURL
            self.refTextURL = refTextURL
            self.clonePromptManifestURL = clonePromptManifestURL
            self.referenceCodesURL = referenceCodesURL
            self.referenceTextTokensURL = referenceTextTokensURL
            self.speakerEmbeddingURL = speakerEmbeddingURL
            self.sampleRate = sampleRate
            self.channels = channels
        }
    }
}
