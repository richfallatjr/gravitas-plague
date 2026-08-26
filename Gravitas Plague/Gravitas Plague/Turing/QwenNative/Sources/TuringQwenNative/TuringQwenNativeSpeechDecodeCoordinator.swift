import Foundation

public actor TuringQwenNativeSpeechDecodeCoordinator {
    public struct RunToken: Hashable, Sendable {
        public let id: UUID
        public let runID: String

        public init(id: UUID, runID: String) {
            self.id = id
            self.runID = runID
        }
    }

    private struct ActiveRun {
        let token: RunToken
        let session: TuringQwenNativeSpeechDecoderSession
        var cancelled: Bool
    }

    private var activeRun: ActiveRun?
    private var nextDecodeID = 0
    private let releaseLedger: TuringQwenRenderReleaseLedger
    private let renderPhaseState: TuringQwenRenderPhaseState

    public init(
        releaseLedger: TuringQwenRenderReleaseLedger,
        renderPhaseState: TuringQwenRenderPhaseState
    ) {
        self.releaseLedger = releaseLedger
        self.renderPhaseState = renderPhaseState
    }

    public func beginRun(runID: String, modelRoot: URL) throws -> RunToken {
        guard activeRun == nil else {
            throw TuringQwenNativeError.invalidConfig(
                "Speech decoder already owns an active run."
            )
        }
        let token = RunToken(id: UUID(), runID: runID)
        activeRun = ActiveRun(
            token: token,
            session: try TuringQwenNativeSpeechDecoderSession(
                modelRoot: modelRoot
            ),
            cancelled: false
        )
        nextDecodeID = 0
        print("""
        [TuringSegmentPipeline] decoder run started
          runID: \(runID)
          tokenID: \(token.id.uuidString)
          concurrentDecoderLimit: 1
        """)
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "speechDecoder.run.started",
            runID: runID,
            details: ["tokenID": token.id.uuidString]
        )
        return token
    }

    public func decode(
        _ rendered: TuringQwenRenderedCodebookSegment,
        token: RunToken
    ) async throws -> TuringQwenDecodedSegment {
        guard let activeRun, activeRun.token == token else {
            throw TuringQwenNativeError.invalidConfig(
                "Decode token does not own the active run."
            )
        }
        guard activeRun.cancelled == false else {
            throw CancellationError()
        }
        guard rendered.runID == token.runID else {
            throw TuringQwenNativeError.invalidConfig(
                "Rendered segment belongs to a different run."
            )
        }
        try await releaseLedger.requireReleased(rendered.releaseToken)
        await renderPhaseState.decodeAcquired(
            runID: rendered.runID,
            segmentIndex: rendered.segmentIndex
        )
        let rowsForDecode = rendered.rowsForDecode

        let decodeID = nextDecodeID
        nextDecodeID += 1
        let before = TuringQwenNativeProcessMemoryProbe.snapshot()
        let startedAt = Date()
        print("""
        [TuringSegmentPipeline] decode acquired
          runID: \(rendered.runID)
          segmentIndex: \(rendered.segmentIndex)
          instanceID: \(rendered.instanceID.rawValue)
          releaseID: \(rendered.releaseToken.releaseID.uuidString)
          decodeID: \(decodeID)
          totalRows: \(rowsForDecode.count)
          physFootprintBeforeMB: \(String(format: "%.1f", before.physFootprintMB))
          residentSizeBeforeMB: \(String(format: "%.1f", before.residentSizeMB))
          concurrentDecoderLimit: 1
          segmentRenderReleasedBeforeDecode: true
          waitedForOtherFreshWorker: false
          freshPathUsesLegacyDecodeGate: false
        """)
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "speechDecoder.segment.started",
            runID: rendered.runID,
            instanceID: rendered.instanceID.rawValue,
            segmentIndex: rendered.segmentIndex,
            details: [
                "decodeID": String(decodeID),
                "totalRows": String(rowsForDecode.count)
            ]
        )

        do {
            let fullAudio = try activeRun.session.decode(
                rows: rowsForDecode,
                performanceMode: rendered.performanceMode
            )
            let trimmed = try TuringQwenNativeBaseCloneDecodeTrimmer
                .trimReferencePrefix(
                    from: fullAudio.samples,
                    referenceRowCount: rendered.decodeReferenceRowCount,
                    totalRowCount: rowsForDecode.count
                )
            let audio = TuringQwenNativeAudio(
                samples: trimmed,
                sampleRate: fullAudio.sampleRate
            )
            TuringQwenNativeMemoryControl.clearCache(
                label: "speechDecoder.segmentCompleted.\(rendered.runID).\(rendered.segmentIndex)",
                shouldLogSnapshot: true
            )
            let completed = TuringQwenNativeProcessMemoryProbe.snapshot()
            let result = TuringQwenDecodedSegment(
                runID: rendered.runID,
                instanceID: rendered.instanceID,
                segmentIndex: rendered.segmentIndex,
                voiceID: rendered.voiceID,
                audio: audio,
                renderMetrics: rendered.renderMetrics,
                decodeSeconds: Date().timeIntervalSince(startedAt)
            )
            print("""
            [TuringSegmentPipeline] decode completed
              runID: \(rendered.runID)
              segmentIndex: \(rendered.segmentIndex)
              instanceID: \(rendered.instanceID.rawValue)
              decodeID: \(decodeID)
              samples: \(audio.samples.count)
              elapsedSeconds: \(String(format: "%.3f", result.decodeSeconds))
              physFootprintAfterMB: \(String(format: "%.1f", completed.physFootprintMB))
              residentSizeAfterMB: \(String(format: "%.1f", completed.residentSizeMB))
            """)
            print("""
            [TuringSegmentPipeline] decode working set released
              runID: \(rendered.runID)
              segmentIndex: \(rendered.segmentIndex)
              decodeID: \(decodeID)
            """)
            TuringQwenNativeDiagnostics.recordBreadcrumb(
                "speechDecoder.segment.completed",
                runID: rendered.runID,
                instanceID: rendered.instanceID.rawValue,
                segmentIndex: rendered.segmentIndex,
                details: [
                    "decodeID": String(decodeID),
                    "samples": String(audio.samples.count)
                ]
            )
            return result
        } catch {
            TuringQwenNativeMemoryControl.clearCache(
                label: "speechDecoder.segmentFailed.\(rendered.runID).\(rendered.segmentIndex)",
                shouldLogSnapshot: true
            )
            print("""
            [TuringSegmentPipeline] decode failed
              runID: \(rendered.runID)
              segmentIndex: \(rendered.segmentIndex)
              instanceID: \(rendered.instanceID.rawValue)
              decodeID: \(decodeID)
              error: \(error.localizedDescription)
            """)
            TuringQwenNativeDiagnostics.recordBreadcrumb(
                "speechDecoder.segment.failed",
                runID: rendered.runID,
                instanceID: rendered.instanceID.rawValue,
                segmentIndex: rendered.segmentIndex,
                details: [
                    "decodeID": String(decodeID),
                    "error": error.localizedDescription
                ]
            )
            throw error
        }
    }

    public func cancelRun(_ token: RunToken, reason: String) {
        guard var activeRun, activeRun.token == token else { return }
        activeRun.cancelled = true
        self.activeRun = activeRun
        print("""
        [TuringSegmentPipeline] decoder run cancelled
          runID: \(token.runID)
          tokenID: \(token.id.uuidString)
          reason: \(reason)
        """)
    }

    public func finishRun(_ token: RunToken) {
        guard activeRun?.token == token else { return }
        activeRun = nil
        TuringQwenNativeMemoryControl.clearCache(
            label: "speechDecoder.runFinished.\(token.runID)",
            shouldLogSnapshot: true
        )
        print("""
        [TuringSegmentPipeline] decoder run finished
          runID: \(token.runID)
          tokenID: \(token.id.uuidString)
        """)
    }
}
