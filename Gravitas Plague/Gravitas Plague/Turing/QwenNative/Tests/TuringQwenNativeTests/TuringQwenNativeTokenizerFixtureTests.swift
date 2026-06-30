import Foundation
import Testing
@testable import TuringQwenNative

struct TuringQwenNativeTokenizerFixtureTests {
    @Test func tokenizerMatchesOfficialVoiceDesignFixture() throws {
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

        let fixture = try JSONDecoder().decode(
            TokenizerFixture.self,
            from: Data(contentsOf: fixtureRoot.appendingPathComponent("tokenizer-fixture.json"))
        )

        let tokenizer = try TuringQwenNativeTokenizer(modelRoot: modelRoot)
        #expect(try tokenizer.encode(fixture.assistantText) == fixture.assistantInputIds[0])

        let actualInstruct = try tokenizer.encode(fixture.instructText)
        let expectedInstruct = fixture.instructInputIds[0]
        if actualInstruct != expectedInstruct {
            let mismatch = zip(actualInstruct, expectedInstruct)
                .enumerated()
                .first { $0.element.0 != $0.element.1 }
            print("""
            tokenizer mismatch
              actualCount: \(actualInstruct.count)
              expectedCount: \(expectedInstruct.count)
              firstMismatch: \(String(describing: mismatch))
              actualPrefix: \(Array(actualInstruct.prefix(40)))
              expectedPrefix: \(Array(expectedInstruct.prefix(40)))
            """)
        }
        #expect(actualInstruct == expectedInstruct)
    }

    private struct TokenizerFixture: Decodable {
        let assistantText: String
        let assistantInputIds: [[Int]]
        let instructText: String
        let instructInputIds: [[Int]]

        enum CodingKeys: String, CodingKey {
            case assistantText
            case assistantInputIds = "assistantInputIds"
            case instructText
            case instructInputIds = "instructInputIds"
        }
    }
}
