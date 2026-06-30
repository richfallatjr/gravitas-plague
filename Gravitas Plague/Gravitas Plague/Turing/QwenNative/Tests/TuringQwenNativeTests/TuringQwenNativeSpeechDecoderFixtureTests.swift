import Foundation
import Testing
@testable import TuringQwenNative

struct TuringQwenNativeSpeechDecoderFixtureTests {
    @Test func speechDecoderMaterializesOfficialDecodeFixture() throws {
        guard ProcessInfo.processInfo.environment["TURING_RUN_MLX_SPEECH_DECODER_TEST"] == "1" else {
            print("""
            speech decoder fixture skipped
              reason: requires MLX Metal runtime metallib
              optIn: TURING_RUN_MLX_SPEECH_DECODER_TEST=1
            """)
            return
        }

        let paths = try fixturePaths()
        let decodeInput = try JSONDecoder().decode(
            DecodeInputFixture.self,
            from: Data(contentsOf: paths.fixtureRoot.appendingPathComponent("decode-input-fixture.json"))
        )
        let metrics = try JSONDecoder().decode(
            ReferenceMetrics.self,
            from: Data(contentsOf: paths.fixtureRoot.appendingPathComponent("reference-output-metrics.json"))
        )

        let rows = try #require(decodeInput.items.first?.values)
        let audio = try TuringQwenNativeSpeechDecoder.decode(
            codebookRows: rows,
            modelRoot: paths.modelRoot
        )

        print("""
        speech decoder fixture metrics
          sampleCount: \(audio.samples.count)
          referenceSampleCount: \(metrics.sampleCount)
          peakAbs: \(audio.peakAbs)
          referencePeakAbs: \(metrics.peakAbs)
          rms: \(audio.rms)
          referenceRMS: \(metrics.rms)
        """)

        #expect(audio.sampleRate == metrics.sampleRate)
        #expect(audio.samples.count == metrics.sampleCount)
        #expect(abs(audio.peakAbs - metrics.peakAbs) < 0.02)
        #expect(abs(audio.rms - metrics.rms) < 0.02)
    }

    private func fixturePaths() throws -> (modelRoot: URL, fixtureRoot: URL) {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let repoRoot = packageRoot
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let modelRoot = repoRoot
            .appendingPathComponent("Gravitas Plague", isDirectory: true)
            .appendingPathComponent("TuringResources", isDirectory: true)
            .appendingPathComponent("Turing", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("Qwen3TTS", isDirectory: true)
            .appendingPathComponent("Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16", isDirectory: true)

        let fixtureRoot = packageRoot
            .appendingPathComponent("Reference", isDirectory: true)
            .appendingPathComponent("Golden", isDirectory: true)
            .appendingPathComponent("voice_design_big_mike_hello", isDirectory: true)

        return (modelRoot, fixtureRoot)
    }

    private struct DecodeInputFixture: Decodable {
        let items: [Item]

        struct Item: Decodable {
            let values: [[Int]]
        }
    }

    private struct ReferenceMetrics: Decodable {
        let finiteSampleCount: Int
        let peakAbs: Float
        let rms: Float
        let sampleCount: Int
        let sampleRate: Int
    }
}
