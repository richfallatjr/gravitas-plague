import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeGPUAdmissionControllerTests {
    @Test
    func candidateAllowsTwoGenerationLeasesAndBlocksAThird() async throws {
        let controller = try makeController(.decodeExclusive)
        await controller.beginRun(runID: "two-generation")
        let first = try await controller.acquireGeneration(work: work(0))
        let second = try await controller.acquireGeneration(work: work(1))

        let thirdTask = Task {
            try await controller.acquireGeneration(work: work(2))
        }
        let queued = try await waitForSnapshot(controller) {
            $0.queuedGenerationCount == 1
        }
        #expect(queued.activeGenerationLeaseCount == 2)
        #expect(queued.peakActiveGenerationLeaseCount == 2)

        await controller.release(first, reason: "test")
        let third = try await thirdTask.value
        await controller.release(second, reason: "test")
        await controller.release(third, reason: "test")

        let final = try await controller.finishRun(reason: "test")
        #expect(final.activeGenerationLeaseCount == 0)
        #expect(final.queuedGenerationCount == 0)
    }

    @Test
    func decodeWaitsForBothGenerationLeases() async throws {
        let controller = try makeController(.decodeExclusive)
        await controller.beginRun(runID: "decode-waits")
        let first = try await controller.acquireGeneration(work: work(0))
        let second = try await controller.acquireGeneration(work: work(1))
        let decodeTask = Task {
            try await controller.acquireDecode(work: decodeWork(0))
        }

        _ = try await waitForSnapshot(controller) {
            $0.queuedDecodeCount == 1
        }
        await controller.release(first, reason: "test")
        let afterOneRelease = await controller.snapshot()
        #expect(afterOneRelease.activeGenerationLeaseCount == 1)
        #expect(afterOneRelease.queuedDecodeCount == 1)
        #expect(afterOneRelease.activeDecodeLeaseCount == 0)

        await controller.release(second, reason: "test")
        let decode = try await decodeTask.value
        let acquired = await controller.snapshot()
        #expect(acquired.activeGenerationLeaseCount == 0)
        #expect(acquired.activeDecodeLeaseCount == 1)
        await controller.release(decode, reason: "test")
        _ = try await controller.finishRun(reason: "test")
    }

    @Test
    func queuedDecodeHasPriorityOverLaterGeneration() async throws {
        let controller = try makeController(.decodeExclusive)
        await controller.beginRun(runID: "decode-priority")
        let activeGeneration = try await controller.acquireGeneration(
            work: work(0)
        )
        let decodeTask = Task {
            try await controller.acquireDecode(work: decodeWork(0))
        }
        _ = try await waitForSnapshot(controller) {
            $0.queuedDecodeCount == 1
        }

        let laterGenerationTask = Task {
            try await controller.acquireGeneration(work: work(1))
        }
        _ = try await waitForSnapshot(controller) {
            $0.queuedGenerationCount == 1 && $0.queuedDecodeCount == 1
        }

        await controller.release(activeGeneration, reason: "test")
        let decode = try await decodeTask.value
        let whileDecoding = await controller.snapshot()
        #expect(whileDecoding.activeDecodeLeaseCount == 1)
        #expect(whileDecoding.queuedGenerationCount == 1)

        await controller.release(decode, reason: "test")
        let laterGeneration = try await laterGenerationTask.value
        await controller.release(laterGeneration, reason: "test")
        let final = try await controller.finishRun(reason: "test")
        #expect(final.blockedDecodeAcquisitionCount == 1)
        #expect(final.blockedGenerationAcquisitionCount == 1)
    }

    @Test
    func currentOverlapKeepsBaselineAdmissionAsNoOp() async throws {
        let controller = try makeController(.currentOverlap)
        await controller.beginRun(runID: "baseline")
        let first = try await controller.acquireGeneration(work: work(0))
        let second = try await controller.acquireGeneration(work: work(1))
        let decode = try await controller.acquireDecode(work: decodeWork(0))

        let simultaneous = await controller.snapshot()
        #expect(simultaneous.generationAcquisitionCount == 2)
        #expect(simultaneous.decodeAcquisitionCount == 1)
        #expect(simultaneous.activeGenerationLeaseCount == 0)
        #expect(simultaneous.activeDecodeLeaseCount == 0)
        #expect(simultaneous.blockedGenerationAcquisitionCount == 0)
        #expect(simultaneous.blockedDecodeAcquisitionCount == 0)

        await controller.release(first, reason: "test")
        await controller.release(second, reason: "test")
        await controller.release(decode, reason: "test")
        _ = try await controller.finishRun(reason: "test")
    }

    @Test
    func staleReleaseCannotFreeAnotherLease() async throws {
        let controller = try makeController(.decodeExclusive)
        await controller.beginRun(runID: "stale-release")
        let first = try await controller.acquireGeneration(work: work(0))
        let second = try await controller.acquireGeneration(work: work(1))

        await controller.release(first, reason: "first")
        await controller.release(first, reason: "duplicate")
        let afterDuplicate = await controller.snapshot()
        #expect(afterDuplicate.activeGenerationLeaseCount == 1)
        #expect(afterDuplicate.invariantViolationCount == 1)

        await controller.release(second, reason: "second")
        let final = try await controller.finishRun(reason: "test")
        #expect(final.invariantViolationCount == 1)
    }

    private func makeController(
        _ mode: TuringQwenNativeGPUAdmissionMode
    ) throws -> TuringQwenNativeGPUAdmissionController {
        TuringQwenNativeGPUAdmissionController(
            policy: try .init(mode: mode)
        )
    }

    private func work(_ index: Int) -> TuringQwenNativeGPUWorkIdentity {
        TuringQwenNativeGPUWorkIdentity(
            runID: "test-run",
            segmentIndex: index,
            laneIndex: index % 2,
            instanceID: "fresh-\(index % 2)",
            decodeID: nil
        )
    }

    private func decodeWork(_ index: Int) -> TuringQwenNativeGPUWorkIdentity {
        TuringQwenNativeGPUWorkIdentity(
            runID: "test-run",
            segmentIndex: index,
            laneIndex: nil,
            instanceID: "fresh-\(index % 2)",
            decodeID: index
        )
    }
}

func waitForSnapshot(
    _ controller: TuringQwenNativeGPUAdmissionController,
    matching predicate: (TuringQwenNativeGPUAdmissionSnapshot) -> Bool
) async throws -> TuringQwenNativeGPUAdmissionSnapshot {
    for _ in 0..<1_000 {
        let value = await controller.snapshot()
        if predicate(value) {
            return value
        }
        await Task.yield()
    }
    throw TuringQwenNativeError.invalidConfig(
        "Timed out waiting for deterministic admission-test state."
    )
}
