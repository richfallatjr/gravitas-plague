import Foundation
import XCTest
@testable import Gravitas_Plague

final class TuringAudiobookSegmentationResponseDecoderTests: XCTestCase {
    func testPhase1RunnerCommitsDeviceToolCallsWithoutRepair() async throws {
        let source = """
        Rich, listen to this stuff. THE GRAVITAS PLAGUE SPREADS. Officials are warning residents to stay indoors after new cases of the Gravitas Plague were confirmed across the city. Doctors say the illness attacks the brain's fear response. Early victims may seem confused, sleepless, or strangely calm. Later symptoms include cloudy eyes, broken speech, fixation on movement, and sudden agitation. One hospital worker said, "They look awake, but unreachable." The infected are not dead. They are living hosts with severe brain damage. Residents are advised to lock doors, avoid contact with rabid animals, and report any bite or fluid exposure immediately. If someone you know appears infected, do not open the door. If the eyes cloud, isolate. If speech fails, do not negotiate.
        """
        let raw = #"""
        tool:call:create_segment_for_text("Rich, listen to this stuff. THE GRAVITAS PLAGUE SPREADS. Officials are warning residents to stay indoors after new cases of the Gravitas Plague were confirmed across the city.", 3, "narration")
        tool:call:create_segment_for_text("Doctors say the illness attacks the brain's fear response. Early victims may seem confused, sleepless, or strangely calm.", 3, "narration")
        tool:call:create_segment_for_text("Later symptoms include cloudy eyes, broken speech, fixation on movement, and sudden agitation.", 3, "narration")
        tool:call:create_segment_for_text("One hospital worker said, \\\"They look awake, but unreachable.\\\"", 3, "narration")
        tool:call:create_segment_for_text("The infected are not dead. They are living hosts with severe brain damage.", 3, "narration")
        tool:call:create_segment_for_text("Residents are advised to lock doors, avoid contact with rabid animals, and report any bite or fluid exposure immediately.", 3, "narration")
        tool:call:create_segment_for_text("If someone you know appears infected, do not open the door. If the eyes cloud, isolate.", 3, "narration")
        tool:call:create_segment_for_text("If speech fails, do not negotiate.", 3, "narration")
        """#
        let foundation = ToolCallFoundationRunner(response: raw)
        let runner = TuringPhase1AudiobookRunner(runner: foundation)

        let plan = try await runner.makePlan(
            request: TuringLongformVoiceScriptRequest(
                requestID: "prologue.scriptPoint05.headlineReading",
                sourceText: source,
                speakerID: "big_mike",
                voiceID: "big_mike_base_clone_v1",
                defaultEmotion: "narration"
            )
        )

        XCTAssertEqual(plan.segmentCount, 8)
        XCTAssertEqual(
            plan.sections.flatMap(\.segments).map(\.globalIndex),
            Array(0..<8)
        )
        let purposes = await foundation.requestedPurposes()
        XCTAssertEqual(
            purposes,
            ["voiceScript_audiobookSourceSectionSegmentation"]
        )
        XCTAssertFalse(
            purposes.contains(
                "voiceScript_audiobookSourceSectionSegmentationRepair"
            )
        )
    }

    func testDecodesFoundationToolCallResponseWithoutRepair() throws {
        let raw = #"""
        tool:call:create_segment_for_text("Rich, listen to this stuff.", 3, "narration")
        tool:call:create_segment_for_text("One worker said, \\\"They look awake, but unreachable.\\\"", 3, "narration")
        tool:call:create_segment_for_text("If speech fails, do not negotiate.", 3, "narration")
        """#

        let payload = try TuringAudiobookSegmentationResponseDecoder.decode(
            raw,
            expectedSectionIndex: 4
        )

        XCTAssertEqual(payload.schemaVersion, 1)
        XCTAssertEqual(payload.sectionIndex, 4)
        XCTAssertEqual(payload.segments.count, 3)
        XCTAssertEqual(payload.segments.map(\.index), [0, 1, 2])
        XCTAssertEqual(
            payload.segments[1].spokenText,
            #"One worker said, "They look awake, but unreachable.""#
        )
        XCTAssertEqual(payload.segments.map(\.emotion), [
            "narration",
            "narration",
            "narration"
        ])
    }

    func testExistingJSONResponseRemainsSupported() throws {
        let raw = #"""
        ```json
        {
          "schemaVersion": 1,
          "sectionIndex": 2,
          "segments": [
            {
              "index": 0,
              "spokenText": "Existing JSON remains authoritative.",
              "emotion": "narration"
            }
          ]
        }
        ```
        """#

        let payload = try TuringAudiobookSegmentationResponseDecoder.decode(
            raw,
            expectedSectionIndex: 2
        )

        XCTAssertEqual(payload.sectionIndex, 2)
        XCTAssertEqual(payload.segments.count, 1)
        XCTAssertEqual(
            payload.segments[0].spokenText,
            "Existing JSON remains authoritative."
        )
    }

    func testPhase1RunnerUsesExactLocalFallbackWithoutFoundationRepair()
        async throws
    {
        let source = """
        First sentence stays exactly as authored. Second sentence also stays exactly as authored, including its punctuation. Third sentence contains enough additional words to force the deterministic segmenter to create more than one useful speech chunk without rewriting anything. Fourth sentence finishes the authored source cleanly so coverage can be compared after normalizing whitespace.
        """
        let foundation = ToolCallFoundationRunner(
            response: "malformed segmentation response"
        )
        let runner = TuringPhase1AudiobookRunner(runner: foundation)

        let plan = try await runner.makePlan(
            request: TuringLongformVoiceScriptRequest(
                requestID: "scriptVoice.localFallback",
                sourceText: source,
                speakerID: "big_mike",
                voiceID: "big_mike_base_clone_v1",
                defaultEmotion: "narration"
            )
        )

        XCTAssertGreaterThan(plan.segmentCount, 1)
        XCTAssertEqual(
            normalizeWhitespace(plan.flattenedSegments.map(\.spokenText)
                .joined(separator: " ")),
            normalizeWhitespace(source)
        )
        XCTAssertEqual(
            await foundation.requestedPurposes(),
            ["voiceScript_audiobookSourceSectionSegmentation"]
        )
    }

    func testPhase1RunnerUsesExactLocalFallbackWhenFoundationFails()
        async throws
    {
        let source = """
        First authored sentence remains intact. Second authored sentence also remains intact. Third authored sentence provides enough words for more than one generated speech segment without asking another model to repair or rewrite the source material in any way.
        """
        let foundation = ToolCallFoundationRunner(
            response: "unused",
            shouldFail: true
        )
        let runner = TuringPhase1AudiobookRunner(runner: foundation)

        let plan = try await runner.makePlan(
            request: TuringLongformVoiceScriptRequest(
                requestID: "scriptVoice.foundationFailureFallback",
                sourceText: source,
                speakerID: "big_mike",
                voiceID: "big_mike_base_clone_v1",
                defaultEmotion: "narration"
            )
        )

        XCTAssertGreaterThan(plan.segmentCount, 0)
        XCTAssertEqual(
            normalizeWhitespace(plan.flattenedSegments.map(\.spokenText)
                .joined(separator: " ")),
            normalizeWhitespace(source)
        )
        XCTAssertEqual(
            await foundation.requestedPurposes(),
            ["voiceScript_audiobookSourceSectionSegmentation"]
        )
    }

    func testRejectsPartialToolCallResponse() {
        let raw = #"""
        tool:call:create_segment_for_text("Accepted-looking segment.", 3, "narration")
        unrelated trailing output
        """#

        XCTAssertThrowsError(
            try TuringAudiobookSegmentationResponseDecoder.decode(
                raw,
                expectedSectionIndex: 0
            )
        )
    }

    private func normalizeWhitespace(_ value: String) -> String {
        value.split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
    }
}

private actor ToolCallFoundationRunner: TuringFoundationQueryRunning {
    private let response: String
    private let shouldFail: Bool
    private var purposes: [String] = []

    init(response: String, shouldFail: Bool = false) {
        self.response = response
        self.shouldFail = shouldFail
    }

    func runPrompt(
        _ prompt: String,
        purpose: String
    ) async throws -> String {
        purposes.append(purpose)
        if shouldFail {
            throw TestFoundationFailure()
        }
        return response
    }

    func requestedPurposes() -> [String] {
        purposes
    }
}

private struct TestFoundationFailure: Error {}
