import Foundation
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
        let acquisition = await state.decodeAcquired(
            runID: "test-run",
            segmentIndex: 0
        )

        let overlap = await state.snapshot()
        #expect(acquisition.activeRenderCount == 1)
        #expect(acquisition.sameSegmentRenderActive == false)
        #expect(acquisition.crossSegmentRenderActive)
        #expect(acquisition.activeRenderKeys == ["test-run.1.fresh-1"])
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

    @Test
    func openQueueAcceptsWorkAfterWorkersBeginWaiting() async throws {
        let queue = TuringQwenOpenSegmentQueue()
        let waiter = Task {
            try await queue.next()
        }

        try await queue.append([makeRequest(segmentIndex: 4)])
        let request = try await waiter.value
        #expect(request?.segmentIndex == 4)
        #expect(await queue.submittedCount() == 1)

        await queue.seal()
        #expect(try await queue.next() == nil)
    }

    @Test
    func openQueueAcceptsAndDrainsElevenOrderedRequests() async throws {
        let queue = TuringQwenOpenSegmentQueue()
        let requests = (0..<11).map {
            makeRequest(segmentIndex: $0)
        }

        try await queue.append(requests)
        #expect(await queue.submittedCount() == 11)
        #expect(await queue.depth() == 11)

        var drainedIndices: [Int] = []
        for _ in requests.indices {
            let request = try await queue.next()
            if let request {
                drainedIndices.append(request.segmentIndex)
            }
        }

        #expect(drainedIndices == Array(0..<11))
        await queue.seal()
        #expect(try await queue.next() == nil)
    }

    @Test
    func duplicateOpenQueueAppendIsAtomic() async throws {
        let queue = TuringQwenOpenSegmentQueue()
        try await queue.append([makeRequest(segmentIndex: 0)])

        await #expect(throws: Error.self) {
            try await queue.append([
                makeRequest(segmentIndex: 1),
                makeRequest(segmentIndex: 1)
            ])
        }

        #expect(await queue.submittedCount() == 1)
        #expect(await queue.depth() == 1)
        #expect(try await queue.next()?.segmentIndex == 0)
        await queue.seal()
    }

    private func makeRequest(
        segmentIndex: Int
    ) -> TuringQwenNativeBaseCloneSegmentRequest {
        let root = URL(fileURLWithPath: "/tmp/turing-open-queue-test")
        let variant = TuringQwenNativeCloneProfile.Variant(
            variantID: "test",
            rootURL: root,
            manifestURL: root,
            originalReferenceAudioURL: root,
            normalizedReferenceAudioURL: root,
            refTextURL: root,
            clonePromptManifestURL: root,
            referenceCodesURL: root,
            referenceTextTokensURL: root,
            speakerEmbeddingURL: root,
            sampleRate: 24_000,
            channels: 1
        )
        let profile = TuringQwenNativeCloneProfile(
            voiceID: "test-voice",
            speakerID: "test-speaker",
            modelID: "test-model",
            profileKind: "test",
            rootURL: root,
            referenceAudioURL: root,
            originalReferenceAudioURL: root,
            referenceText: "test",
            defaultVariantID: variant.variantID,
            allowFallback: false,
            variants: [variant.variantID: variant]
        )
        return TuringQwenNativeBaseCloneSegmentRequest(
            segmentIndex: segmentIndex,
            text: "Test segment \(segmentIndex).",
            language: "english",
            cloneProfile: profile,
            maxNewRows: 16,
            performanceMode: .performance,
            referenceRowLimit: nil,
            referenceWindowStrategy: .full
        )
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
