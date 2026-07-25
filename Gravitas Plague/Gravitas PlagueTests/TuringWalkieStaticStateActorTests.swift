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
}
