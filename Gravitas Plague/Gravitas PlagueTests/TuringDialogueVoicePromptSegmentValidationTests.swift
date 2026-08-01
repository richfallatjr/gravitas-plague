import XCTest
@testable import Gravitas_Plague

@MainActor
final class TuringDialogueVoicePromptSegmentValidationTests: XCTestCase {
    func testOverlongVoicePromptSegmentUsesSentenceBoundaryWithoutRepair()
        async throws
    {
        let runner = VoicePromptSegmentValidationRunner(
            responses: [
                """
                {
                  "schemaVersion": 1,
                  "segments": [
                    {
                      "text": "One two three four five six seven eight. Nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen.",
                      "emotion": "focused"
                    }
                  ]
                }
                """,
            ]
        )
        let service = TuringDialogueService(runner: runner)

        let plan = try await service.generateVoicePrompt(
            VoicePromptRequest(
                id: "test.voicePrompt.segmentLimit",
                characterProfileID: "rich",
                listenerProfileID: "big_mike",
                promptContext: "Keep the message concise.",
                prerecordingTranscript: "Mike, copy this.",
                storyIntent: "Keep the message concise."
            )
        )

        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(
            plan.segments[0].text,
            "One two three four five six seven eight."
        )
        XCTAssertEqual(
            plan.segments[1].text,
            "Nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen."
        )
        XCTAssertEqual(plan.segments.map(\.emotion), ["focused", "focused"])
        XCTAssertTrue(
            plan.segments.allSatisfy {
                $0.text.split(whereSeparator: { $0.isWhitespace }).count <= 15
            }
        )
        XCTAssertEqual(
            plan.segments.flatMap {
                $0.text.split(whereSeparator: { $0.isWhitespace })
            }.map(String.init),
            "One two three four five six seven eight. Nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen."
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
        )

        let calls = runner.calls()
        XCTAssertEqual(
            calls.map(\.purpose),
            ["voicePrompt_characterIntent"]
        )
    }

    func testCharacterIntentTemplateStatesConcreteSegmentLimit()
        throws
    {
        let url = try TuringResourceLoader.resourceURL(
            resourcePath:
                "Turing/Prompts/voicePrompt_characterIntent.txt"
        )
        let template = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(
            template.contains(
                "Keep each segment to 15 spoken words or fewer."
            )
        )
    }
}

@MainActor
private final class VoicePromptSegmentValidationRunner:
    TuringFoundationQueryRunning,
    @unchecked Sendable
{
    struct Call: Sendable {
        let prompt: String
        let purpose: String
    }

    private var remainingResponses: [String]
    private var recordedCalls: [Call] = []

    init(responses: [String]) {
        remainingResponses = responses
    }

    func runPrompt(
        _ prompt: String,
        purpose: String
    ) async throws -> String {
        recordedCalls.append(
            Call(prompt: prompt, purpose: purpose)
        )
        guard remainingResponses.isEmpty == false else {
            throw TuringRuntimeError.invalidConfig(
                "Voice prompt validation test exhausted responses."
            )
        }
        return remainingResponses.removeFirst()
    }

    func calls() -> [Call] {
        recordedCalls
    }
}
