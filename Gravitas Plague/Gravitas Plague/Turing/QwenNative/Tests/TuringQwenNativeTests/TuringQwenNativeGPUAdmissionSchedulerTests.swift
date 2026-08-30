import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeGPUAdmissionSchedulerTests {
    private enum InjectedFailure: Error {
        case render
        case decode
        case publication
    }

    @Test
    func candidatePreservesTwoLaneGenerationAroundExclusiveDecode() async throws {
        let controller = TuringQwenNativeGPUAdmissionController(
            policy: try .phase1Candidate
        )
        await controller.beginRun(runID: "scheduler-integration")
        let lane0 = try await controller.acquireGeneration(
            work: generationWork(segment: 0, lane: 0)
        )
        let lane1 = try await controller.acquireGeneration(
            work: generationWork(segment: 1, lane: 1)
        )
        #expect((await controller.snapshot()).activeGenerationLeaseCount == 2)

        let decodeTask = Task {
            try await controller.acquireDecode(work: decodeWork(segment: 0))
        }
        _ = try await waitForSnapshot(controller) {
            $0.queuedDecodeCount == 1
        }
        await controller.release(lane0, reason: "render0Complete")

        let nextLane0Task = Task {
            try await controller.acquireGeneration(
                work: generationWork(segment: 2, lane: 0)
            )
        }
        _ = try await waitForSnapshot(controller) {
            $0.queuedGenerationCount == 1 && $0.queuedDecodeCount == 1
        }
        await controller.release(lane1, reason: "render1Complete")

        let decode = try await decodeTask.value
        let decodeSnapshot = await controller.snapshot()
        #expect(decodeSnapshot.activeDecodeLeaseCount == 1)
        #expect(decodeSnapshot.activeGenerationLeaseCount == 0)
        #expect(decodeSnapshot.queuedGenerationCount == 1)

        await controller.release(decode, reason: "decodeComplete")
        let nextLane0 = try await nextLane0Task.value
        let resumed = await controller.snapshot()
        #expect(resumed.activeDecodeLeaseCount == 0)
        #expect(resumed.activeGenerationLeaseCount == 1)
        #expect(resumed.peakActiveGenerationLeaseCount == 2)

        await controller.release(nextLane0, reason: "test")
        let final = try await controller.finishRun(reason: "test")
        #expect(final.maximumDecodeWaitNanoseconds > 0)
        #expect(final.maximumGenerationWaitNanoseconds > 0)
    }

    @Test
    func renderThrowReleasesGenerationLease() async throws {
        let controller = try await makeController(runID: "render-throw")
        do {
            let lease = try await controller.acquireGeneration(
                work: generationWork(segment: 0, lane: 0, runID: "render-throw")
            )
            do {
                throw InjectedFailure.render
            } catch {
                await controller.release(lease, reason: "renderFailed")
                throw error
            }
        } catch InjectedFailure.render {
            // Expected injection.
        }

        try await expectEmptyFinish(controller)
    }

    @Test
    func decodeThrowReleasesExclusiveDecodeLease() async throws {
        let controller = try await makeController(runID: "decode-throw")
        do {
            let lease = try await controller.acquireDecode(
                work: decodeWork(segment: 0, runID: "decode-throw")
            )
            do {
                throw InjectedFailure.decode
            } catch {
                await controller.release(lease, reason: "decodeFailed")
                throw error
            }
        } catch InjectedFailure.decode {
            // Expected injection.
        }

        try await expectEmptyFinish(controller)
    }

    @Test
    func publicationThrowOccursAfterBothGPULeasesAreReleased() async throws {
        let controller = try await makeController(runID: "publication-throw")
        do {
            let generation = try await controller.acquireGeneration(
                work: generationWork(
                    segment: 0,
                    lane: 0,
                    runID: "publication-throw"
                )
            )
            await controller.release(generation, reason: "renderCompleted")

            let decode = try await controller.acquireDecode(
                work: decodeWork(segment: 0, runID: "publication-throw")
            )
            await controller.release(decode, reason: "decodeCompleted")
            throw InjectedFailure.publication
        } catch InjectedFailure.publication {
            // Publication is deliberately outside GPU ownership.
        }

        try await expectEmptyFinish(controller)
    }

    private func makeController(
        runID: String
    ) async throws -> TuringQwenNativeGPUAdmissionController {
        let controller = TuringQwenNativeGPUAdmissionController(
            policy: try .phase1Candidate
        )
        await controller.beginRun(runID: runID)
        return controller
    }

    private func expectEmptyFinish(
        _ controller: TuringQwenNativeGPUAdmissionController
    ) async throws {
        let final = try await controller.finishRun(reason: "test")
        #expect(final.activeGenerationLeaseCount == 0)
        #expect(final.activeDecodeLeaseCount == 0)
        #expect(final.queuedGenerationCount == 0)
        #expect(final.queuedDecodeCount == 0)
    }

    private func generationWork(
        segment: Int,
        lane: Int,
        runID: String = "scheduler-integration"
    ) -> TuringQwenNativeGPUWorkIdentity {
        .init(
            runID: runID,
            segmentIndex: segment,
            laneIndex: lane,
            instanceID: "fresh-\(lane)",
            decodeID: nil
        )
    }

    private func decodeWork(
        segment: Int,
        runID: String = "scheduler-integration"
    ) -> TuringQwenNativeGPUWorkIdentity {
        .init(
            runID: runID,
            segmentIndex: segment,
            laneIndex: nil,
            instanceID: "fresh-0",
            decodeID: segment
        )
    }
}
