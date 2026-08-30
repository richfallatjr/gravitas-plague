import Foundation

public actor TuringQwenNativeSpeechDecodeCoordinator {
    public struct RunToken: Hashable, Sendable {
        public let id: UUID
        public let runID: String
        public let generation: TuringQwenNativeRecoveryGeneration

        public init(
            id: UUID,
            runID: String,
            generation: TuringQwenNativeRecoveryGeneration = .initial
        ) {
            self.id = id
            self.runID = runID
            self.generation = generation
        }
    }

    private struct ActiveRun {
        let token: RunToken
        let session: TuringQwenNativeSpeechDecoderSession
        var cancelled: Bool
    }

    private var activeRun: ActiveRun?
    private var nextDecodeID = 0
    private var activeDecodeID: Int?
    private var activeStageCount = 0
    private let releaseLedger: TuringQwenRenderReleaseLedger
    private let renderPhaseState: TuringQwenRenderPhaseState
    private let gpuAdmission: TuringQwenNativeGPUAdmissionController
    private let residencySnapshotsByInstanceID:
        [String: TuringQwenNativeFreshInstanceResidencySnapshot]

    public init(
        releaseLedger: TuringQwenRenderReleaseLedger,
        renderPhaseState: TuringQwenRenderPhaseState,
        gpuAdmission: TuringQwenNativeGPUAdmissionController,
        residencySnapshots: [TuringQwenNativeFreshInstanceResidencySnapshot] = []
    ) {
        self.releaseLedger = releaseLedger
        self.renderPhaseState = renderPhaseState
        self.gpuAdmission = gpuAdmission
        self.residencySnapshotsByInstanceID = Dictionary(
            uniqueKeysWithValues: residencySnapshots.map { ($0.instanceID, $0) }
        )
    }

    public func beginRun(
        runID: String,
        modelRoot: URL,
        generation: TuringQwenNativeRecoveryGeneration = .initial
    ) async throws -> RunToken {
        try await TuringQwenNativeMetalCircuitBreaker.shared.requireHealthy()
        guard activeRun == nil else {
            throw TuringQwenNativeError.invalidConfig(
                "Speech decoder already owns an active run."
            )
        }
        let token = RunToken(
            id: UUID(),
            runID: runID,
            generation: generation
        )
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

        let decodeID = nextDecodeID
        nextDecodeID += 1
        let decodeLease = try await gpuAdmission.acquireDecode(
            work: TuringQwenNativeGPUWorkIdentity(
                runID: rendered.runID,
                segmentIndex: rendered.segmentIndex,
                laneIndex: nil,
                instanceID: rendered.instanceID.rawValue,
                decodeID: decodeID
            )
        )
        let overlap = await renderPhaseState.decodeAcquired(
            runID: rendered.runID,
            segmentIndex: rendered.segmentIndex
        )
        activeDecodeID = decodeID
        activeStageCount = 1
        let rowsForDecode = rendered.rowsForDecode

        let admissionAtAcquire = await gpuAdmission.snapshot()
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
          gpuAdmissionMode: \(admissionAtAcquire.mode.rawValue)
          gpuAdmissionGenerationQueue: \(admissionAtAcquire.queuedGenerationCount)
          gpuAdmissionDecodeQueue: \(admissionAtAcquire.queuedDecodeCount)
          activeRenderCountAtDecodeAcquire: \(overlap.activeRenderCount)
          sameSegmentRenderActive: \(overlap.sameSegmentRenderActive)
          crossSegmentRenderActive: \(overlap.crossSegmentRenderActive)
          activeRenderKeys: \(overlap.activeRenderKeys)
        """)
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "speechDecoder.segment.started",
            runID: rendered.runID,
            instanceID: rendered.instanceID.rawValue,
            segmentIndex: rendered.segmentIndex,
            details: [
                "decodeID": String(decodeID),
                "totalRows": String(rowsForDecode.count),
                "gpuAdmissionMode": admissionAtAcquire.mode.rawValue,
                "gpuAdmissionGenerationQueue": String(admissionAtAcquire.queuedGenerationCount),
                "gpuAdmissionDecodeQueue": String(admissionAtAcquire.queuedDecodeCount),
                "activeRenderCountAtDecodeAcquire": String(overlap.activeRenderCount),
                "sameSegmentRenderActive": String(overlap.sameSegmentRenderActive),
                "crossSegmentRenderActive": String(overlap.crossSegmentRenderActive),
                "activeRenderKeys": overlap.activeRenderKeys.joined(separator: ",")
            ]
        )

        do {
            let residency = residencySnapshotsByInstanceID[rendered.instanceID.rawValue]
            let fullAudio = try activeRun.session.decode(
                rows: rowsForDecode,
                performanceMode: rendered.performanceMode,
                diagnosticContext: TuringQwenNativeSpeechDecoderDiagnosticContext(
                    runID: rendered.runID,
                    instanceID: rendered.instanceID.rawValue,
                    segmentIndex: rendered.segmentIndex,
                    decodeID: decodeID,
                    residencyOwnerID: residency?.ownerID?.uuidString,
                    weightStoreID: residency?.weightStoreID.uuidString,
                    laneMutableStateID: residency?.laneMutableStateIdentity.mutableStateID.uuidString
                )
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
                decodeSeconds: Date().timeIntervalSince(startedAt),
                recoveryGeneration: rendered.recoveryGeneration
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
            activeDecodeID = nil
            activeStageCount = 0
            await gpuAdmission.release(
                decodeLease,
                reason: "decodeCompleted"
            )
            return result
        } catch {
            activeDecodeID = nil
            activeStageCount = 0
            await gpuAdmission.release(
                decodeLease,
                reason: "decodeFailed"
            )
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

    public func cancelAndReleaseForRecovery(
        token: RunToken,
        failure: TuringQwenNativeMetalFailure
    ) -> TuringQwenNativeDecoderReleaseReceipt {
        cancelRun(
            token,
            reason: "metalRecovery.commandBuffer.\(failure.record.record.commandBufferID)"
        )
        if activeDecodeID == nil && activeStageCount == 0 {
            activeRun = nil
        }
        return .init(
            runID: token.runID,
            tokenID: token.id,
            generation: token.generation,
            sessionReleased: activeRun == nil,
            activeDecodeCount: activeDecodeID == nil ? 0 : 1,
            activeStageCount: activeStageCount
        )
    }
}
