import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringSpokenPresentationHubTests: XCTestCase {
    func testTwoSubscribersReceiveIdenticalEvent() async {
        let hub = TuringSpokenPresentationHub()
        var first = (await hub.events()).makeAsyncIterator()
        var second = (await hub.events()).makeAsyncIterator()
        let event = makeEvent(segmentIndex: 1)

        await hub.emit(event)

        let firstEvent = await first.next()
        let secondEvent = await second.next()
        XCTAssertEqual(firstEvent, event)
        XCTAssertEqual(secondEvent, event)
    }

    func testTerminatingOneSubscriberLeavesOtherActive() async {
        let hub = TuringSpokenPresentationHub()
        let firstStream = await hub.events()
        var second = (await hub.events()).makeAsyncIterator()
        let firstTask = Task<TuringSpokenPresentationEvent?, Never> {
            for await event in firstStream { return event }
            return nil
        }
        firstTask.cancel()
        await Task.yield()

        let event = makeEvent(segmentIndex: 2)
        await hub.emit(event)

        let secondEvent = await second.next()
        XCTAssertEqual(secondEvent, event)
    }

    func testLateSubscriberReceivesFutureEventsOnly() async {
        let hub = TuringSpokenPresentationHub()
        await hub.emit(makeEvent(segmentIndex: 3))
        var late = (await hub.events()).makeAsyncIterator()
        let future = makeEvent(segmentIndex: 4)

        await hub.emit(future)

        let lateEvent = await late.next()
        XCTAssertEqual(lateEvent, future)
    }

    func testHubPreservesIdentityAndTiming() async {
        let hub = TuringSpokenPresentationHub()
        var iterator = (await hub.events()).makeAsyncIterator()
        let event = makeEvent(segmentIndex: 5)

        await hub.emit(event)

        let received = await iterator.next()
        guard let received,
              case .started(let receivedContext) = received else {
            return XCTFail("Expected a start event.")
        }
        guard case .started(let expectedContext) = event else {
            return XCTFail("Fixture must be a start event.")
        }
        XCTAssertEqual(receivedContext, expectedContext)
        XCTAssertEqual(receivedContext.clockOrigin, expectedContext.clockOrigin)
        XCTAssertEqual(receivedContext.playbackHandle, expectedContext.playbackHandle)
    }

    private func makeEvent(
        segmentIndex: Int
    ) -> TuringSpokenPresentationEvent {
        let flowIdentity = TuringFlowIdentity(
            scriptPointID: "test.hub",
            characterID: TuringConversationCharacterID.bigMike.rawValue,
            prerecordingID: "test.pr",
            voicePromptID: "test.prompt",
            playbackRunID: "test.hub.run"
        )
        let handle = TuringAudioPlaybackHandle(
            id: UUID(),
            requestID: UUID(),
            runID: flowIdentity.playbackRunID,
            route: .storyWalkie
        )
        return .started(
            context: TuringSpokenPresentationContext(
                run: .init(flowIdentity: flowIdentity),
                playbackHandle: handle,
                speakerCharacterID: .bigMike,
                interactionSurface: .walkie,
                source: .generated(segmentIndex: segmentIndex),
                clockOrigin: ContinuousClock.now
            )
        )
    }
}
