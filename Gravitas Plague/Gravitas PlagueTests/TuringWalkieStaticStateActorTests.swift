import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringWalkieStaticStateActorTests: XCTestCase {
    func testAmbientRetentionDefersUnrelatedStopUntilFlowRelease() async throws {
        let endpoint = FakeRichGlobalClipPlayer()
        let state = TuringWalkieStaticStateActor(endpoint: endpoint)
        let ownerID = "turingFlow.test"

        try await state.retainAmbient(
            fileURL: URL(fileURLWithPath: "/tmp/walkie-static.mp3"),
            runID: "test.run",
            ownerID: ownerID
        )
        await state.stopAmbient(reason: "unrelatedStop")

        let startedKinds = await endpoint.startedKinds()
        let deferredCancelReasons = await endpoint.cancelReasonsSnapshot()
        XCTAssertEqual(startedKinds, [.ambientStatic])
        XCTAssertEqual(deferredCancelReasons, [])

        await state.releaseAmbient(
            ownerID: ownerID,
            reason: "promptVoicePlaybackCompleted"
        )

        let releasedCancelReasons = await endpoint.cancelReasonsSnapshot()
        XCTAssertEqual(
            releasedCancelReasons,
            ["promptVoicePlaybackCompleted"]
        )
    }

    func testStopAllOverridesAmbientRetentionForShutdown() async throws {
        let endpoint = FakeRichGlobalClipPlayer()
        let state = TuringWalkieStaticStateActor(endpoint: endpoint)

        try await state.retainAmbient(
            fileURL: URL(fileURLWithPath: "/tmp/walkie-static.mp3"),
            runID: "test.run",
            ownerID: "turingFlow.test"
        )
        await state.stopAll(reason: "immersiveShutdown")

        let cancelReasons = await endpoint.cancelReasonsSnapshot()
        XCTAssertEqual(
            cancelReasons,
            ["immersiveShutdown"]
        )
    }

    func testConversationSendingCoverStopsWhileAmbientRemainsRetained() async throws {
        let endpoint = FakeRichGlobalClipPlayer()
        let state = TuringWalkieStaticStateActor(endpoint: endpoint)
        let ownerID = "live.test"

        try await state.retainAmbient(
            fileURL: URL(fileURLWithPath: "/tmp/walkie-ambient.mp3"),
            runID: "conversation.test",
            ownerID: ownerID
        )
        let sendingHandle = try await state.startRetainedSending(
            fileURL: URL(fileURLWithPath: "/tmp/walkie-sending.mp3"),
            runID: "conversation.test",
            ownerID: ownerID
        )

        await state.stopRetainedSending(
            ownerID: ownerID,
            handle: sendingHandle,
            reason: "responsePlaybackStarted"
        )
        await state.stopAmbient(reason: "unrelatedResponseStartStop")

        let responseStartCancelReasons =
            await endpoint.cancelReasonsSnapshot()
        XCTAssertEqual(
            responseStartCancelReasons,
            ["responsePlaybackStarted"]
        )

        await state.releaseAmbient(
            ownerID: ownerID,
            reason: "responsePlaybackCompleted"
        )

        let responseCompletionCancelReasons =
            await endpoint.cancelReasonsSnapshot()
        XCTAssertEqual(
            responseCompletionCancelReasons,
            ["responsePlaybackStarted", "responsePlaybackCompleted"]
        )
    }
}
