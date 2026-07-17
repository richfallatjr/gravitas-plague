import Testing

@testable import TuringQwenNative

struct TuringQwenSegmentPipelineTests {
    @Test
    func renderedPayloadRoundTripsCPUCodebooks() {
        let releaseToken = TuringQwenRenderReleaseToken(
            runID: "test-run",
            segmentIndex: 2,
            instanceID: .init(index: 0)
        )
        let payload = TuringQwenRenderedCodebookSegment(
            runID: "test-run",
            instanceID: .init(index: 0),
            segmentIndex: 2,
            voiceID: "test-voice",
            referenceCodes: ContiguousArray([1, 2, 3, 4]),
            generatedCodes: ContiguousArray([5, 6, 7, 8]),
            referenceRowCount: 2,
            generatedRowCount: 2,
            codebookCount: 2,
            reachedEOS: true,
            performanceMode: .performance,
            renderMetrics: .init(
                elapsedSeconds: 1,
                initialPromptSeconds: 0.1,
                initialTalkerForwardSeconds: 0.2,
                talkerOneStepTotalSeconds: 0.3,
                codePredictorTotalSeconds: 0.4
            ),
            releaseToken: releaseToken
        )

        #expect(payload.rowsForDecode == [[1, 2], [3, 4], [5, 6], [7, 8]])
        #expect(payload.decodeReferenceRowCount == 2)
        #expect(payload.releaseToken == releaseToken)
    }

    @Test
    func decodeBeginsAfterThatSegmentsReleaseWithoutWaitingForOtherFreshInstance() async throws {
        let state = TuringQwenRenderPhaseState()
        let ledger = TuringQwenRenderReleaseLedger()
        let instance0 = TuringQwenNativeFreshInstanceID(index: 0)
        let instance1 = TuringQwenNativeFreshInstanceID(index: 1)
        let worker1EnteredRender = TuringQwenPipelineTestGate()
        let releaseWorker1 = TuringQwenPipelineTestGate()
        try await state.beginRun(runID: "test-run")

        let heldWorker = Task {
            await state.renderStarted(
                runID: "test-run",
                segmentIndex: 1,
                instanceID: instance1
            )
            await worker1EnteredRender.open()
            await releaseWorker1.wait()
            await state.renderReleased(
                runID: "test-run",
                segmentIndex: 1,
                instanceID: instance1
            )
        }

        await worker1EnteredRender.wait()
        await state.renderStarted(
            runID: "test-run",
            segmentIndex: 0,
            instanceID: instance0
        )

        let release0 = TuringQwenRenderReleaseToken(
            runID: "test-run",
            segmentIndex: 0,
            instanceID: instance0
        )
        await ledger.record(release0)
        await state.renderReleased(
            runID: "test-run",
            segmentIndex: 0,
            instanceID: instance0
        )

        try await ledger.requireReleased(release0)
        await state.decodeAcquired(runID: "test-run", segmentIndex: 0)

        let overlap = await state.snapshot()
        #expect(overlap.peakActiveRenderCount == 2)
        #expect(overlap.sameSegmentRenderDecodeOverlapCount == 0)
        #expect(overlap.crossSegmentRenderDecodeOverlapCount == 1)

        await releaseWorker1.open()
        await heldWorker.value
    }

    @Test
    func decodeRejectsAnUnreleasedSegmentToken() async {
        let ledger = TuringQwenRenderReleaseLedger()
        let token = TuringQwenRenderReleaseToken(
            runID: "test-run",
            segmentIndex: 0,
            instanceID: .init(index: 0)
        )

        await #expect(throws: Error.self) {
            try await ledger.requireReleased(token)
        }
    }

    @Test
    func dynamicWorkQueueClaimsEachRequestOnce() async {
        let queue = TuringQwenNativeFreshInstanceWorkQueue(totalCount: 3)

        #expect(await queue.nextIndex() == 0)
        #expect(await queue.nextIndex() == 1)
        #expect(await queue.nextIndex() == 2)
        #expect(await queue.nextIndex() == nil)
    }
}

private actor TuringQwenPipelineTestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard isOpen == false else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard isOpen == false else { return }
        isOpen = true
        let continuations = waiters
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.resume()
        }
    }
}
