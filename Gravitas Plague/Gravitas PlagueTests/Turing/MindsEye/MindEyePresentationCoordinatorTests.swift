import XCTest

@testable import Gravitas_Plague

final class MindEyePresentationCoordinatorTests: XCTestCase {
    func testSuccessfulAttachInstallsActiveIdentityBeforeMotionStarts() throws {
        let source = try coordinatorSource()
        let active = try XCTUnwrap(source.range(of: "active = ActivePresentation("))
        let start = try XCTUnwrap(source.range(of: "prepared.visual.startKeepAlive("))
        XCTAssertLessThan(active.lowerBound, start.lowerBound)
    }

    func testMotionStartFailureRetainsStaticCardAndAudioOnlyFailurePolicy() throws {
        let source = try coordinatorSource()
        XCTAssertTrue(source.contains("stage: \"startKeepAlive\""))
        XCTAssertTrue(source.contains("fallback=audioOnly"))
        let keepAliveBlock = try XCTUnwrap(source.range(of: "let keepAlive ="))
        let shownMessage = try XCTUnwrap(source.range(of: "dynamic card shown"))
        XCTAssertLessThan(keepAliveBlock.lowerBound, shownMessage.lowerBound)
    }

    func testReplacementStopsOldTokenBeforeDetach() throws {
        let source = try coordinatorSource()
        let method = try XCTUnwrap(source.range(of: "private func detachActiveImmediately"))
        let suffix = String(source[method.lowerBound...])
        let stop = try XCTUnwrap(suffix.range(of: "active.visual.stopKeepAlive"))
        let detach = try XCTUnwrap(suffix.range(of: "active.visual.detach"))
        XCTAssertLessThan(stop.lowerBound, detach.lowerBound)
    }

    func testPauseAndResumeFreezeOnlySpeechAnimation() throws {
        let source = try coordinatorSource()
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "active.identity.key == key").count - 1,
            2
        )
        XCTAssertTrue(source.contains("mouth=frozen"))
        XCTAssertTrue(source.contains("mouth=resumed"))
        XCTAssertTrue(source.contains("keepAlive=continues blink=continues"))

        let pauseCase = try XCTUnwrap(source.range(of: "case .paused(let context"))
        let resumeCase = try XCTUnwrap(
            source.range(of: "case .resumed(let context", range: pauseCase.upperBound..<source.endIndex)
        )
        let pausedBlock = source[pauseCase.lowerBound..<resumeCase.lowerBound]
        XCTAssertFalse(pausedBlock.contains("setFrameUpdatesPaused"))

        let completedCase = try XCTUnwrap(
            source.range(
                of: "case .authoredItemCompleted",
                range: resumeCase.upperBound..<source.endIndex
            )
        )
        let resumedBlock = source[resumeCase.lowerBound..<completedCase.lowerBound]
        XCTAssertFalse(resumedBlock.contains("setFrameUpdatesPaused"))
    }

    func testAttachWhileAudioPausedDoesNotSuspendKeepAliveOrBlinking() throws {
        let source = try coordinatorSource()
        XCTAssertFalse(source.contains("attachedWhileSpokenPlaybackPaused"))
        XCTAssertTrue(source.contains("still idle and blink"))
    }

    func testPreAudioRevealCannotReplaceAnAudiblePresentation() throws {
        let source = try coordinatorSource()
        let handler = try XCTUnwrap(
            source.range(of: "private func handleRevealRequest(")
        )
        let suffix = String(source[handler.lowerBound...])
        let audibleGuard = try XCTUnwrap(
            suffix.range(of: "if let active, active.isAudible")
        )
        let continuityPromotion = try XCTUnwrap(
            suffix.range(of: "if canPromoteGeneratedContinuity")
        )
        let replacement = try XCTUnwrap(
            suffix.range(of: "preAudioRevealReplacement")
        )
        XCTAssertLessThan(audibleGuard.lowerBound, continuityPromotion.lowerBound)
        XCTAssertLessThan(audibleGuard.lowerBound, replacement.lowerBound)
        XCTAssertTrue(suffix.contains("audible owner retained"))
        XCTAssertTrue(suffix.contains("deviceSelectionContinues=true computeContinues=true"))
        XCTAssertTrue(suffix.contains("await resolveReveal(request, outcome: .audioOnly)"))
    }

    private func coordinatorSource() throws -> String {
        try String(
            contentsOf: mindEyeProjectRoot().appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePresentationCoordinator.swift"
            ),
            encoding: .utf8
        )
    }
}
