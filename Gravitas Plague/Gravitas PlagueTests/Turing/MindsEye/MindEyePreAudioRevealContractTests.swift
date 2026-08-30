import XCTest

@testable import Gravitas_Plague

final class MindEyePreAudioRevealContractTests: XCTestCase {
    func testSpeechPlaybackWaitsForRevealAtAllSpokenBoundaries() throws {
        let source = try productionSource(
            "Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift"
        )
        XCTAssertEqual(
            source.components(
                separatedBy: "await performMindEyeRevealLeadIn("
            ).count - 1,
            4
        )
        XCTAssertTrue(
            source.contains(
                "mindEyeRevealLeadInBeat: Duration = .milliseconds(300)"
            )
        )
        let reveal = try XCTUnwrap(
            source.range(of: "await performMindEyeRevealLeadIn(")
        )
        let playback = try XCTUnwrap(
            source.range(of: "let handle = try await playOneShot(",
                         range: reveal.upperBound ..< source.endIndex)
        )
        XCTAssertLessThan(reveal.lowerBound, playback.lowerBound)
    }

    func testPreviewStartsMotionButDefersMouthPlaybackUntilAudioStart() throws {
        let source = try productionSource(
            "Turing/MindsEye/MindEyePresentationCoordinator.swift"
        )
        XCTAssertTrue(source.contains("pendingRevealRequest == nil"))
        XCTAssertTrue(source.contains("idle portrait revealed before audio"))
        XCTAssertTrue(source.contains("motion=keepAlive mouth=rest"))
        XCTAssertTrue(source.contains("promotePreAudioReveal(to: context)"))
        XCTAssertTrue(source.contains("motionRestarted=false"))
    }

    func testPrerecordingFillerStagesTheAuthoredPortraitBeforeOrientation() throws {
        let source = try productionSource(
            "Turing/Conversation/TuringLiveConversationSessionCoordinator.swift"
        )
        let method = try XCTUnwrap(
            source.range(of: "func prepareForPrerecordingPreFiller(")
        )
        let remainder = source[method.lowerBound...]

        XCTAssertTrue(
            remainder.contains("TuringAuthoredPresentationPreparationHub.shared.publish")
        )
        XCTAssertTrue(
            remainder.contains("TuringSpokenPresentationRevealRequest(")
        )
        XCTAssertTrue(remainder.contains("source: source"))
        XCTAssertTrue(remainder.contains("motion=keepAlive blink=active mouth=rest"))
        XCTAssertTrue(
            remainder.contains("microphoneContext=\\(microphoneContext)")
        )
        XCTAssertTrue(
            remainder.contains("currentPromptActivation=actualAuthoredMediaStart")
        )
        XCTAssertTrue(
            remainder.contains("context=previousConversationVoice")
        )
        XCTAssertTrue(
            remainder.contains("context=currentPromptVoiceFallback")
        )
    }

    func testMissingVisualFallsThroughToAudioOnly() throws {
        let source = try productionSource(
            "Turing/Audio/TuringSpokenPresentationReveal.swift"
        )
        XCTAssertTrue(source.contains("guard continuations.isEmpty == false else"))
        XCTAssertTrue(source.contains("return .audioOnly"))
        XCTAssertTrue(source.contains("return nil"))
    }

    private func productionSource(_ relativePath: String) throws -> String {
        try String(
            contentsOf: mindEyeProjectRoot()
                .appendingPathComponent("Gravitas Plague/Gravitas Plague")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
