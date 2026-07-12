import Foundation
import Testing
@testable import TuringQwenNative

@Suite
struct TuringQwenNativeRichCloneProfileTests {
    @Test
    func loadsPackagedRichCloneProfile() throws {
        let testDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceRoot = projectDirectory.appendingPathComponent(
            "TuringResources",
            isDirectory: true
        )

        let profile = try TuringQwenNativeCloneProfileLoader()
            .loadRichBaseCloneProfile(from: resourceRoot)

        #expect(profile.voiceID == "rich_base_clone_v1")
        #expect(profile.speakerID == "rich")
        #expect(profile.defaultVariantID == "rich_reference_01")
        #expect(profile.allowFallback == false)

        let variant = try profile.requireVariant("rich_reference_01")
        #expect(variant.sampleRate == 24_000)
        #expect(variant.channels == 1)
        #expect(
            FileManager.default.fileExists(
                atPath: variant.referenceCodesURL.path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: variant.speakerEmbeddingURL.path
            )
        )

        let artifacts = try TuringQwenNativeCloneArtifactsLoader().load(
            from: variant,
            expectedVoiceID: profile.voiceID
        )
        #expect(artifacts.voiceID == profile.voiceID)
        #expect(artifacts.variantID == variant.variantID)
        #expect(artifacts.referenceRowCount > 0)
        #expect(artifacts.codebookCount == 16)
    }

    @Test
    func genericArtifactIdentityValidationStillLoadsBigMike() throws {
        let testDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let projectDirectory = testDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resourceRoot = projectDirectory.appendingPathComponent(
            "TuringResources",
            isDirectory: true
        )

        let profile = try TuringQwenNativeCloneProfileLoader()
            .loadBigMikeBaseCloneProfile(from: resourceRoot)
        let variant = try profile.requireVariant(profile.defaultVariantID)
        let artifacts = try TuringQwenNativeCloneArtifactsLoader().load(
            from: variant,
            expectedVoiceID: profile.voiceID
        )

        #expect(artifacts.voiceID == profile.voiceID)
        #expect(artifacts.variantID == profile.defaultVariantID)
        #expect(artifacts.referenceRowCount > 0)
        #expect(artifacts.codebookCount == 16)
    }
}
