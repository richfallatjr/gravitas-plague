import Foundation
import Testing

@testable import TuringQwenNative

private final class Phase3FailingLoader:
    TuringQwenNativeResidencyLoading,
    @unchecked Sendable
{
    private let lock = NSLock()
    private(set) var invocationCount = 0

    func load(
        token: TuringQwenNativeSharedResidencyOwner.Token,
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String
    ) throws -> TuringQwenNativeSharedResidencySnapshot {
        lock.lock()
        invocationCount += 1
        lock.unlock()
        throw TuringQwenNativeError.invalidConfig("injected owner load failure")
    }
}

struct TuringQwenNativeSharedResidencyOwnerTests {
    @Test
    func failedOwnerLoadDoesNotRetryIndependently() async throws {
        await TuringQwenNativeMetalCircuitBreaker.shared.resetForTesting()
        let loader = Phase3FailingLoader()
        let owner = TuringQwenNativeSharedResidencyOwner(loader: loader)
        await #expect(throws: (any Error).self) {
            try await owner.prepare(
                modelRoot: URL(fileURLWithPath: "/tmp/phase3-model"),
                cloneProfile: phase3CloneProfile(),
                variantID: "default"
            )
        }
        #expect(loader.invocationCount == 1)
        await #expect(throws: (any Error).self) {
            try await owner.prepare(
                modelRoot: URL(fileURLWithPath: "/tmp/phase3-model"),
                cloneProfile: phase3CloneProfile(),
                variantID: "default"
            )
        }
        #expect(loader.invocationCount == 1)
    }
}

func phase3CloneProfile(
    voiceID: String = "big_mike",
    variantID: String = "default"
) -> TuringQwenNativeCloneProfile {
    let root = URL(fileURLWithPath: "/tmp/phase3-clone")
    let variant = TuringQwenNativeCloneProfile.Variant(
        variantID: variantID,
        rootURL: root,
        manifestURL: root.appendingPathComponent("manifest.json"),
        originalReferenceAudioURL: root.appendingPathComponent("original.wav"),
        normalizedReferenceAudioURL: root.appendingPathComponent("normalized.wav"),
        refTextURL: root.appendingPathComponent("ref.txt"),
        clonePromptManifestURL: root.appendingPathComponent("clone.json"),
        referenceCodesURL: root.appendingPathComponent("codes.bin"),
        referenceTextTokensURL: root.appendingPathComponent("tokens.bin"),
        speakerEmbeddingURL: root.appendingPathComponent("embedding.bin"),
        sampleRate: 24_000,
        channels: 1
    )
    return TuringQwenNativeCloneProfile(
        voiceID: voiceID,
        speakerID: voiceID,
        modelID: "qwen3-tts-12hz-1.7b-base-4bit",
        profileKind: "baseCloneICL",
        rootURL: root,
        referenceAudioURL: variant.normalizedReferenceAudioURL,
        originalReferenceAudioURL: variant.originalReferenceAudioURL,
        referenceText: "test",
        defaultVariantID: variantID,
        allowFallback: false,
        variants: [variantID: variant]
    )
}
