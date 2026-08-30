import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeGPUAdmissionCancellationTests {
    @Test
    func cancellingQueuedGenerationRemovesExactlyThatWaiter() async throws {
        let controller = try controller()
        await controller.beginRun(runID: "cancel-generation")
        let first = try await controller.acquireGeneration(work: work(0))
        let second = try await controller.acquireGeneration(work: work(1))
        let queued = Task {
            try await controller.acquireGeneration(work: work(2))
        }
        _ = try await waitForSnapshot(controller) {
            $0.queuedGenerationCount == 1
        }

        queued.cancel()
        await #expect(throws: CancellationError.self) {
            try await queued.value
        }
        #expect((await controller.snapshot()).queuedGenerationCount == 0)

        await controller.release(first, reason: "test")
        await controller.release(second, reason: "test")
        _ = try await controller.finishRun(reason: "test")
    }

    @Test
    func cancellingQueuedDecodeLeavesGenerationOwnershipIntact() async throws {
        let controller = try controller()
        await controller.beginRun(runID: "cancel-decode")
        let active = try await controller.acquireGeneration(work: work(0))
        let queued = Task {
            try await controller.acquireDecode(work: decodeWork(0))
        }
        _ = try await waitForSnapshot(controller) {
            $0.queuedDecodeCount == 1
        }

        queued.cancel()
        await #expect(throws: CancellationError.self) {
            try await queued.value
        }
        let afterCancellation = await controller.snapshot()
        #expect(afterCancellation.queuedDecodeCount == 0)
        #expect(afterCancellation.activeGenerationLeaseCount == 1)

        await controller.release(active, reason: "test")
        _ = try await controller.finishRun(reason: "test")
    }

    @Test
    func cancellingRunResumesAllWaitersWithoutInventingActiveRelease() async throws {
        let controller = try controller()
        await controller.beginRun(runID: "cancel-run")
        let first = try await controller.acquireGeneration(work: work(0))
        let second = try await controller.acquireGeneration(work: work(1))
        let queuedDecode = Task {
            try await controller.acquireDecode(work: decodeWork(0))
        }
        let queuedGeneration = Task {
            try await controller.acquireGeneration(work: work(2))
        }
        _ = try await waitForSnapshot(controller) {
            $0.queuedDecodeCount == 1 && $0.queuedGenerationCount == 1
        }

        await controller.cancelAll(reason: "test")
        await #expect(throws: CancellationError.self) {
            try await queuedDecode.value
        }
        await #expect(throws: CancellationError.self) {
            try await queuedGeneration.value
        }
        let cancelled = await controller.snapshot()
        #expect(cancelled.activeGenerationLeaseCount == 2)
        #expect(cancelled.queuedDecodeCount == 0)
        #expect(cancelled.queuedGenerationCount == 0)

        await controller.release(first, reason: "unwind")
        await controller.release(second, reason: "unwind")
        let final = try await controller.finishRun(reason: "test")
        #expect(final.activeGenerationLeaseCount == 0)
    }

    @Test
    func cancellationRacingWithGrantDoesNotLeakOrDoubleResume() async throws {
        let controller = try controller()
        await controller.beginRun(runID: "cancel-at-grant")
        let first = try await controller.acquireGeneration(work: work(0))
        let second = try await controller.acquireGeneration(work: work(1))
        let queued = Task {
            try await controller.acquireGeneration(work: work(2))
        }
        _ = try await waitForSnapshot(controller) {
            $0.queuedGenerationCount == 1
        }

        // Intentionally race waiter cancellation with the actor granting the
        // newly freed permit. Either legal ordering must unwind exactly once.
        queued.cancel()
        await controller.release(first, reason: "grantRace")
        await #expect(throws: CancellationError.self) {
            try await queued.value
        }

        let afterRace = await controller.snapshot()
        #expect(afterRace.activeGenerationLeaseCount == 1)
        #expect(afterRace.queuedGenerationCount == 0)

        await controller.release(second, reason: "test")
        let final = try await controller.finishRun(reason: "test")
        #expect(final.activeGenerationLeaseCount == 0)
        #expect(final.queuedGenerationCount == 0)
    }

    private func controller() throws -> TuringQwenNativeGPUAdmissionController {
        TuringQwenNativeGPUAdmissionController(
            policy: try .phase1Candidate
        )
    }

    private func work(_ index: Int) -> TuringQwenNativeGPUWorkIdentity {
        .init(
            runID: "test-run",
            segmentIndex: index,
            laneIndex: index % 2,
            instanceID: "fresh-\(index % 2)",
            decodeID: nil
        )
    }

    private func decodeWork(_ index: Int) -> TuringQwenNativeGPUWorkIdentity {
        .init(
            runID: "test-run",
            segmentIndex: index,
            laneIndex: nil,
            instanceID: "fresh-\(index % 2)",
            decodeID: index
        )
    }
}
