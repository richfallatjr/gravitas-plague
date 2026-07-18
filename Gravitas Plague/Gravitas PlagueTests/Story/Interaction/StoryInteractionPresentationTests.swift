import XCTest

@testable import Gravitas_Plague

@MainActor
final class StoryInteractionPresentationTests: XCTestCase {
    private final class Surface: StoryInteractionSurfacePresenting {
        var snapshots: [StoryInteractionSnapshot] = []
        var onSnapshot: (() -> Void)?

        func applyInteractionSnapshot(_ snapshot: StoryInteractionSnapshot) {
            snapshots.append(snapshot)
            onSnapshot?()
        }
    }

    func testRegisteredSurfaceReceivesInitialSnapshot() async {
        let arbiter = StoryInteractionArbiter()
        await arbiter.updateTuringGate(.play, reason: "test")
        let coordinator = StoryInteractionPresentationCoordinator(
            arbiter: arbiter
        )
        let surface = Surface()
        let received = expectation(description: "initial interaction snapshot")
        surface.onSnapshot = { received.fulfill() }

        coordinator.register(surface)
        coordinator.start()
        await fulfillment(of: [received], timeout: 1.0)
        coordinator.stop()

        XCTAssertEqual(surface.snapshots.last?.walkiePresentation, .play)
        XCTAssertEqual(surface.snapshots.last?.doorPresentation, .open)
    }

    func testInitialClosedTuringGateStillPresentsDoorOpen() async {
        let coordinator = StoryInteractionPresentationCoordinator(
            arbiter: StoryInteractionArbiter()
        )
        let surface = Surface()
        let received = expectation(description: "initial idle snapshot")
        surface.onSnapshot = { received.fulfill() }

        coordinator.register(surface)
        coordinator.start()
        await fulfillment(of: [received], timeout: 1.0)
        coordinator.stop()

        XCTAssertEqual(surface.snapshots.last?.walkiePresentation, .hidden)
        XCTAssertEqual(surface.snapshots.last?.doorPresentation, .open)
        XCTAssertEqual(surface.snapshots.last?.capabilities, [.doorOpen])
    }

    func testSurfaceRegistrationDoesNotRetainDeadSurface() {
        let coordinator = StoryInteractionPresentationCoordinator(
            arbiter: StoryInteractionArbiter()
        )
        weak var weakSurface: Surface?

        autoreleasepool {
            let surface = Surface()
            weakSurface = surface
            coordinator.register(surface)
        }

        XCTAssertNil(weakSurface)
        coordinator.stop()
    }
}
