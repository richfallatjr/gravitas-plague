import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeAuthoredToGeneratedContinuityTests: XCTestCase {
    func testSeparateParentAndChildRunsCarryOneExplicitContinuityIdentity() {
        let parentFlow = UUID()
        let childFlow = UUID()
        let token = TuringSpokenPresentationContinuity(
            continuityID: UUID(),
            parent: .init(
                playbackRunID: "prologue.scriptPoint05.\(parentFlow)",
                flowInstanceID: parentFlow,
                mediaIdentity: "authored.primary.scriptPoint05"
            ),
            childPlaybackRunID: "response.\(childFlow)",
            childFlowInstanceID: childFlow,
            speakerCharacterID: .bigMike,
            interactionSurface: .walkie
        )
        let child = TuringFlowIdentity(
            flowInstanceID: childFlow,
            scriptPointID: "conversation.response",
            characterID: TuringConversationCharacterID.bigMike.rawValue,
            prerecordingID: "generated",
            voicePromptID: "generated",
            interactionSurface: .walkie,
            playbackRunID: token.childPlaybackRunID,
            spokenPresentationContinuity: token
        )

        let run = TuringSpokenPresentationRunIdentity(flowIdentity: child)
        XCTAssertEqual(run.playbackRunID, token.childPlaybackRunID)
        XCTAssertEqual(run.flowInstanceID, token.childFlowInstanceID)
        XCTAssertEqual(run.continuity, token)
        XCTAssertNotEqual(token.parent?.playbackRunID, token.childPlaybackRunID)
    }

    func testCoordinatorRequiresExactParentChildSpeakerAndSurfaceMatching() throws {
        let source = try String(
            contentsOf: presentationCoordinatorURL(),
            encoding: .utf8
        )
        for requirement in [
            "parent.playbackRunID",
            "parent.flowInstanceID",
            "parent.mediaIdentity",
            "continuity.childPlaybackRunID == runID",
            "continuity.childFlowInstanceID == context.run.flowInstanceID",
            "continuity.speakerCharacterID == context.speakerCharacterID",
            "continuity.interactionSurface == context.interactionSurface",
            "context.run.continuity?.continuityID == continuity.continuityID"
        ] {
            XCTAssertTrue(source.contains(requirement), requirement)
        }
    }

    private func presentationCoordinatorURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/MindsEye/" +
                    "MindEyePresentationCoordinator.swift"
            )
    }
}

final class MindEyeRuntimeLipSyncReadyBeforeStartTests: XCTestCase {
    func testPreparedClipConsumesAnalysisBeforeAudibleStart() throws {
        let root = repositoryRoot()
        let fileStore = try String(
            contentsOf: root.appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/Audio/" +
                    "TuringGeneratedPlaybackFileStore.swift"
            ),
            encoding: .utf8
        )
        let playback = try String(
            contentsOf: root.appendingPathComponent(
                "Gravitas Plague/Gravitas Plague/Turing/Audio/" +
                    "TuringStoryWalkiePlaybackCoordinator.swift"
            ),
            encoding: .utf8
        )
        XCTAssertTrue(fileStore.contains("analysisCoordinator.submit"))
        XCTAssertTrue(playback.contains("earlyGeneratedAnalysis"))
        XCTAssertTrue(playback.contains("analysis merged before enqueue"))
    }
}

final class MindEyeRuntimeLipSyncLateJoinTests: XCTestCase {
    func testLateJoinUsesExactHandleAndMinimumRemainingAudioGate() throws {
        let source = try String(
            contentsOf: presentationCoordinatorURL(),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("duration - elapsed < .milliseconds(350)"))
        XCTAssertTrue(source.contains("playbackHandle"))
        XCTAssertTrue(source.contains("ticketID"))
        XCTAssertTrue(source.contains("generatedTrackBecameAvailable"))
    }
}

final class MindEyeRuntimeLipSyncStaleResultTests: XCTestCase {
    func testStaleCompletionGuardsCoverRunSegmentContinuityAndHandle() throws {
        let source = try String(
            contentsOf: presentationCoordinatorURL(),
            encoding: .utf8
        )
        XCTAssertTrue(source.contains("context.run.playbackRunID"))
        XCTAssertTrue(source.contains("context.run.flowInstanceID"))
        XCTAssertTrue(source.contains("continuityMatches"))
        XCTAssertTrue(source.contains("activeMatches"))
        XCTAssertTrue(source.contains("desiredMatches"))
    }
}

private func repositoryRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

private func presentationCoordinatorURL() -> URL {
    repositoryRoot().appendingPathComponent(
        "Gravitas Plague/Gravitas Plague/Turing/MindsEye/" +
            "MindEyePresentationCoordinator.swift"
    )
}
