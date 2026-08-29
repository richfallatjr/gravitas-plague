import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredFrameManifestTests: XCTestCase {
    func testCanonicalManifestDecodesAndValidates() throws {
        let manifest = try JSONDecoder().decode(
            MindEyeAuthoredFrameManifest.self,
            from: canonicalData()
        )

        XCTAssertEqual(manifest.speakerCharacterID, .bigMike)
        XCTAssertEqual(manifest.interactionSurface, .walkie)
        XCTAssertEqual(manifest.requiredPoseFamilies, [.rest, .small, .wide, .round, .teeth])
        XCTAssertTrue(MindEyeAuthoredFrameManifestValidator.validate(manifest).isEmpty)
    }

    func testPoseMaskMismatchIsRejected() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData()) as? [String: Any]
        )
        var frames = try XCTUnwrap(object["frames"] as? [[String: Any]])
        frames[0]["layerMask"] = 16
        object["frames"] = frames
        let data = try JSONSerialization.data(withJSONObject: object)
        let manifest = try JSONDecoder().decode(MindEyeAuthoredFrameManifest.self, from: data)

        XCTAssertTrue(
            MindEyeAuthoredFrameManifestValidator.validate(manifest)
                .contains { $0.code == .authoredFrameManifestInvalid }
        )
    }

    func testUppercaseHashIsRejected() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: canonicalData()) as? [String: Any]
        )
        object["audioSHA256"] = String(repeating: "A", count: 64)
        let data = try JSONSerialization.data(withJSONObject: object)
        let manifest = try JSONDecoder().decode(MindEyeAuthoredFrameManifest.self, from: data)

        XCTAssertTrue(
            MindEyeAuthoredFrameManifestValidator.validate(manifest)
                .contains { $0.code == .authoredFrameManifestHashInvalid }
        )
    }

    private func canonicalData() -> Data {
        let hash = String(repeating: "0", count: 64)
        let text = """
        {
          "schemaVersion": 1,
          "compilerVersion": "mind-eye-authored-frame-compiler/1.0.3",
          "prID": "prologue.walkie.bigMike.richContact.001",
          "speakerCharacterID": "big_mike",
          "interactionSurface": "walkie",
          "descriptorResourcePath": "Turing/Prerecordings/prologue.walkie.bigMike.richContact.001.json",
          "descriptorSHA256": "\(hash)",
          "audioResourcePath": "Turing/Audio/prerecordings/pr-big-mike-rich-contact.mp3",
          "audioSHA256": "\(hash)",
          "transcriptSHA256": "\(hash)",
          "timeline": {"sampleRate":48000,"sampleCount":800,"durationSeconds":0.016666667,"framesPerSecond":60,"samplesPerNominalFrame":800,"frameCount":1},
          "mouthLayerBits": {"rest":1,"small":2,"wide":4,"round":8,"teeth":16},
          "requiredPoseFamilies": ["rest","small","wide","round","teeth"],
          "analysisProvenance": {
            "toolchainLockSHA256":"\(hash)","compilerConfigSHA256":"\(hash)","phonemePoseMapSHA256":"\(hash)","pronunciationOverridesSHA256":"\(hash)","manualOverrideSHA256":null,
            "mfa":{"version":"3.3.9","acousticModel":"english_us_arpa","acousticModelVersion":"3.0.0","dictionary":"english_us_arpa","dictionaryVersion":"3.0.0","g2pModel":"english_us_arpa","g2pModelVersion":"2.0.0a","retryUsed":false,"rawOutputSHA256":"\(hash)"},
            "vad":{"name":"silero-vad","version":"6.2.1","backend":"onnx","modelSHA256":"\(hash)","configurationSHA256":"\(hash)"}
          },
          "framesSHA256": "\(hash)",
          "frames": [{"frameIndex":0,"sampleStart":0,"sampleEnd":800,"pose":"rest","layerMask":1,"speechActive":false,"phone":"sil","evidenceMask":5}],
          "summary": {"poseFrameCounts":{"rest":1,"small":0,"wide":0,"round":0,"teeth":0},"speechFrameCount":0,"silenceFrameCount":1,"fallbackFrameCount":0,"manualOverrideFrameCount":0,"alignedWordCount":1,"transcriptTokenCount":1,"oovWords":[],"g2pWords":[],"warnings":[]}
        }
        """
        return Data(text.utf8)
    }
}
