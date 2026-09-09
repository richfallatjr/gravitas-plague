import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeExperimentalStreamingTests {
    @Test
    func streamingIsExplicitlyDisabledByDefault() throws {
        let configuration =
            TuringQwenNativeExperimentalStreamingConfiguration()

        #expect(configuration == .disabled)
        #expect(configuration.isEnabled == false)
        #expect(
            TuringQwenNativeExperimentalStreamingConfiguration
                .generatedRowsPerWindow == 8
        )
        #expect(
            TuringQwenNativeExperimentalStreamingConfiguration
                .samplesPerGeneratedRow == 1_920
        )
        #expect(
            TuringQwenNativeExperimentalStreamingConfiguration
                .generatedAudioSecondsPerWindow == 0.64
        )

        #expect(throws: Error.self) {
            try configuration.validate(eventSinkIsPresent: true)
        }
        #expect(throws: Error.self) {
            try TuringQwenNativeExperimentalStreamingConfiguration
                .qualificationGrowingPrefix
                .validate(eventSinkIsPresent: false)
        }
        try TuringQwenNativeExperimentalStreamingConfiguration
            .qualificationGrowingPrefix
            .validate(eventSinkIsPresent: true)
    }

    @Test
    func emitterPublishesOrderedWindowsWithoutDuplicatesAndFlushesPartial()
        async throws
    {
        let channel = TuringQwenNativeIncrementalCodebookEventSink
            .makePerRenderStream()
        let identity = makeIdentity()
        var emitter = try TuringQwenNativeIncrementalCodebookWindowEmitter(
            identity: identity,
            referenceRows: makeRows(count: 2, offset: -2),
            codebookCount: 2,
            performanceMode: .performance,
            sink: channel.sink
        )

        for row in makeRows(count: 19) {
            try emitter.commit(row)
        }
        try emitter.flushFinalPartialWindow()
        channel.sink.yield(
            .finished(
                .init(
                    identity: identity,
                    generatedRowCount: 19,
                    reachedEOS: true
                )
            )
        )

        let windows = await collectWindows(from: channel.events)
        #expect(windows.count == 3)
        #expect(
            windows.map(\.newGeneratedRowRange) == [
                0..<8,
                8..<16,
                16..<19
            ]
        )
        #expect(windows.map(\.generatedPrefixRows.count) == [8, 16, 19])
        #expect(windows.last?.newGeneratedRowRange.count == 3)

        let emittedIndices = windows.flatMap {
            Array($0.newGeneratedRowRange)
        }
        #expect(emittedIndices == Array(0..<19))
        #expect(Set(emittedIndices).count == 19)
    }

    @Test
    func finalFlushDoesNotDuplicateAnExactWindowBoundary() async throws {
        let channel = TuringQwenNativeIncrementalCodebookEventSink
            .makePerRenderStream()
        let identity = makeIdentity()
        var emitter = try TuringQwenNativeIncrementalCodebookWindowEmitter(
            identity: identity,
            referenceRows: makeRows(count: 1, offset: -1),
            codebookCount: 2,
            performanceMode: .performance,
            sink: channel.sink
        )

        for row in makeRows(count: 16) {
            try emitter.commit(row)
        }
        try emitter.flushFinalPartialWindow()
        channel.sink.yield(
            .finished(
                .init(
                    identity: identity,
                    generatedRowCount: 16,
                    reachedEOS: true
                )
            )
        )

        let windows = await collectWindows(from: channel.events)
        #expect(windows.map(\.newGeneratedRowRange) == [0..<8, 8..<16])
    }

    @Test
    func growingPrefixPlannerSelectsOnlyNewRowAlignedSuffixes() throws {
        let identity = makeIdentity()
        let referenceRows = makeRows(count: 24, offset: -24)
        let firstWindow = try makeWindow(
            identity: identity,
            range: 0..<8,
            prefixCount: 8,
            referenceRows: referenceRows
        )
        let secondWindow = try makeWindow(
            identity: identity,
            range: 8..<16,
            prefixCount: 16,
            referenceRows: referenceRows
        )

        let firstPlan = try TuringQwenNativeGrowingPrefixDecodePlan.make(
            window: firstWindow,
            previouslyEmittedGeneratedPrefixRows: []
        )
        let secondPlan = try TuringQwenNativeGrowingPrefixDecodePlan.make(
            window: secondWindow,
            previouslyEmittedGeneratedPrefixRows:
                firstWindow.generatedPrefixRows
        )

        #expect(firstPlan.rowsForDecode.count == 32)
        #expect(firstPlan.fullDecodeSampleRange == 46_080..<61_440)
        #expect(firstPlan.generatedOutputSampleRange == 0..<15_360)
        #expect(secondPlan.rowsForDecode.count == 40)
        #expect(secondPlan.fullDecodeSampleRange == 61_440..<76_800)
        #expect(secondPlan.generatedOutputSampleRange == 15_360..<30_720)
        #expect(
            firstPlan.generatedOutputSampleRange.count +
                secondPlan.generatedOutputSampleRange.count == 30_720
        )

        #expect(throws: Error.self) {
            try TuringQwenNativeGrowingPrefixDecodePlan.make(
                window: firstWindow,
                previouslyEmittedGeneratedPrefixRows:
                    firstWindow.generatedPrefixRows
            )
        }

        let skippedWindow = try makeWindow(
            identity: identity,
            range: 9..<16,
            prefixCount: 16,
            referenceRows: referenceRows
        )
        #expect(throws: Error.self) {
            try TuringQwenNativeGrowingPrefixDecodePlan.make(
                window: skippedWindow,
                previouslyEmittedGeneratedPrefixRows:
                    firstWindow.generatedPrefixRows
            )
        }

        var rewrittenPrefix = makeRows(count: 16)
        rewrittenPrefix[0] = [999, 999]
        let rewrittenWindow = try TuringQwenNativeIncrementalCodebookWindow(
            identity: identity,
            newGeneratedRowRange: 8..<16,
            referenceRows: referenceRows,
            generatedPrefixRows: rewrittenPrefix,
            codebookCount: 2,
            performanceMode: .performance
        )
        #expect(throws: Error.self) {
            try TuringQwenNativeGrowingPrefixDecodePlan.make(
                window: rewrittenWindow,
                previouslyEmittedGeneratedPrefixRows:
                    firstWindow.generatedPrefixRows
            )
        }
    }

    @Test
    func capturedCadenceRequiresWholeUtteranceAtEightRowArrivals() throws {
        let eightRows = try TuringQwenNativeStreamingQueueEconomicsGate.assess(
            startupRowCount: 8,
            totalGeneratedRowCount: 31,
            observedSecondsPerRow: 0.515
        )
        let tenRows = try TuringQwenNativeStreamingQueueEconomicsGate.assess(
            startupRowCount: 10,
            totalGeneratedRowCount: 31,
            observedSecondsPerRow: 0.515
        )
        let twentyFourRows =
            try TuringQwenNativeStreamingQueueEconomicsGate.assess(
                startupRowCount: 24,
                totalGeneratedRowCount: 31,
                observedSecondsPerRow: 0.515
            )
        let twentySevenRows =
            try TuringQwenNativeStreamingQueueEconomicsGate.assess(
                startupRowCount: 27,
                totalGeneratedRowCount: 31,
                observedSecondsPerRow: 0.515
            )

        #expect(eightRows.canAvoidUnderrunOptimistically == false)
        #expect(tenRows.canAvoidUnderrunOptimistically == false)
        #expect(twentyFourRows.canAvoidUnderrunOptimistically == false)
        #expect(twentySevenRows.canAvoidUnderrunOptimistically == false)
        #expect(twentySevenRows.isStartupEmissionBoundary == false)
        #expect(eightRows.emittedCumulativeRowCounts == [8, 16, 24, 31])
        #expect(eightRows.minimumStreamingStartupRowCount == nil)
        #expect(tenRows.minimumStreamingStartupRowCount == nil)
        #expect(twentySevenRows.minimumStreamingStartupRowCount == nil)
        #expect(eightRows.minimumPlaybackStartupRowCount == 31)
        #expect(twentyFourRows.minimumPlaybackStartupRowCount == 31)
        #expect(abs(eightRows.maximumSustainableSecondsPerRow - 0.08) <
            0.000_000_001)
        #expect(twentyFourRows.firstArrivalSurplusSeconds < 0)
        #expect(twentyFourRows.preFinalArrivalSurplusSeconds < 0)
        #expect(twentySevenRows.beginsBeforeGenerationCompletes)
        #expect(twentySevenRows.qualifiesForExperimentalPlaybackActivation == false)

        #expect(throws: Error.self) {
            try TuringQwenNativeStreamingQueueEconomicsGate
                .requirePlaybackActivationViability(
                    startupRowCount: 10,
                    totalGeneratedRowCount: 31,
                    observedSecondsPerRow: 0.515
                )
        }
        #expect(throws: Error.self) {
            try TuringQwenNativeStreamingQueueEconomicsGate
                .requirePlaybackActivationViability(
                    startupRowCount: 27,
                    totalGeneratedRowCount: 31,
                    observedSecondsPerRow: 0.515
                )
        }

        let wholeUtterance =
            try TuringQwenNativeStreamingQueueEconomicsGate.assess(
                startupRowCount: 31,
                totalGeneratedRowCount: 31,
                observedSecondsPerRow: 0.515
            )
        #expect(wholeUtterance.canAvoidUnderrunOptimistically)
        #expect(wholeUtterance.beginsBeforeGenerationCompletes == false)
        #expect(
            wholeUtterance.qualifiesForExperimentalPlaybackActivation == false
        )
        #expect(wholeUtterance.minimumPlaybackStartupRowCount == 31)
        #expect(throws: Error.self) {
            try TuringQwenNativeStreamingQueueEconomicsGate
                .requirePlaybackActivationViability(
                    startupRowCount: 31,
                    totalGeneratedRowCount: 31,
                    observedSecondsPerRow: 0.515
                )
        }
    }

    @Test
    func perRenderAndSharedCollectorsCloseOnlyAfterOwnedTerminals()
        async throws
    {
        let firstIdentity = makeIdentity()
        let secondIdentity = TuringQwenNativeIncrementalCodebookStreamIdentity(
            streamID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000005"
            )!,
            runID: "stage-4-test",
            segmentIndex: 1,
            instanceID: .init(index: 1),
            voiceID: "test-voice"
        )
        let shared = try TuringQwenNativeIncrementalCodebookEventSink
            .makeSharedStream(expectedTerminalCount: 2)

        shared.sink.yield(
            .finished(
                .init(
                    identity: firstIdentity,
                    generatedRowCount: 8,
                    reachedEOS: true
                )
            )
        )
        // A duplicate terminal cannot spend the sibling render's terminal.
        shared.sink.yield(
            .finished(
                .init(
                    identity: firstIdentity,
                    generatedRowCount: 8,
                    reachedEOS: true
                )
            )
        )
        shared.sink.yield(
            .failed(identity: secondIdentity, message: "controlled failure")
        )

        let events = await collectEvents(from: shared.events)
        #expect(events.count == 2)
        #expect(events.first == .finished(.init(
            identity: firstIdentity,
            generatedRowCount: 8,
            reachedEOS: true
        )))
        #expect(events.last == .failed(
            identity: secondIdentity,
            message: "controlled failure"
        ))

        #expect(throws: Error.self) {
            try TuringQwenNativeIncrementalCodebookEventSink
                .makeSharedStream(expectedTerminalCount: 0)
        }
    }

    private func makeIdentity()
        -> TuringQwenNativeIncrementalCodebookStreamIdentity
    {
        TuringQwenNativeIncrementalCodebookStreamIdentity(
            streamID: UUID(
                uuidString: "00000000-0000-0000-0000-000000000004"
            )!,
            runID: "stage-4-test",
            segmentIndex: 0,
            instanceID: .init(index: 0),
            voiceID: "test-voice"
        )
    }

    private func makeRows(count: Int, offset: Int = 0) -> [[Int]] {
        (0..<count).map { index in
            let value = index + offset
            return [value, value + 10_000]
        }
    }

    private func makeWindow(
        identity: TuringQwenNativeIncrementalCodebookStreamIdentity,
        range: Range<Int>,
        prefixCount: Int,
        referenceRows: [[Int]]
    ) throws -> TuringQwenNativeIncrementalCodebookWindow {
        try TuringQwenNativeIncrementalCodebookWindow(
            identity: identity,
            newGeneratedRowRange: range,
            referenceRows: referenceRows,
            generatedPrefixRows: makeRows(count: prefixCount),
            codebookCount: 2,
            performanceMode: .performance
        )
    }

    private func collectWindows(
        from events: AsyncStream<TuringQwenNativeIncrementalCodebookEvent>
    ) async -> [TuringQwenNativeIncrementalCodebookWindow] {
        var windows: [TuringQwenNativeIncrementalCodebookWindow] = []
        for await event in events {
            if case .window(let window) = event {
                windows.append(window)
            }
        }
        return windows
    }

    private func collectEvents(
        from events: AsyncStream<TuringQwenNativeIncrementalCodebookEvent>
    ) async -> [TuringQwenNativeIncrementalCodebookEvent] {
        var result: [TuringQwenNativeIncrementalCodebookEvent] = []
        for await event in events {
            result.append(event)
        }
        return result
    }
}
