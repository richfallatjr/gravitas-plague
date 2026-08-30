import Foundation

public struct TuringQwenRenderPhaseMetrics: Sendable, Equatable {
    public let elapsedSeconds: TimeInterval
    public let initialPromptSeconds: TimeInterval
    public let initialTalkerForwardSeconds: TimeInterval
    public let talkerOneStepTotalSeconds: TimeInterval
    public let codePredictorTotalSeconds: TimeInterval

    public init(
        elapsedSeconds: TimeInterval,
        initialPromptSeconds: TimeInterval,
        initialTalkerForwardSeconds: TimeInterval,
        talkerOneStepTotalSeconds: TimeInterval,
        codePredictorTotalSeconds: TimeInterval
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.initialPromptSeconds = initialPromptSeconds
        self.initialTalkerForwardSeconds = initialTalkerForwardSeconds
        self.talkerOneStepTotalSeconds = talkerOneStepTotalSeconds
        self.codePredictorTotalSeconds = codePredictorTotalSeconds
    }
}

public struct TuringQwenRenderReleaseToken: Hashable, Sendable {
    public let runID: String
    public let segmentIndex: Int
    public let instanceID: TuringQwenNativeFreshInstanceID
    public let releaseID: UUID
    public let recoveryGeneration: TuringQwenNativeRecoveryGeneration

    public init(
        runID: String,
        segmentIndex: Int,
        instanceID: TuringQwenNativeFreshInstanceID,
        releaseID: UUID = UUID(),
        recoveryGeneration: TuringQwenNativeRecoveryGeneration = .initial
    ) {
        self.runID = runID
        self.segmentIndex = segmentIndex
        self.instanceID = instanceID
        self.releaseID = releaseID
        self.recoveryGeneration = recoveryGeneration
    }
}

struct TuringQwenRenderedCodebookMaterialization: Sendable, Equatable {
    let runID: String
    let instanceID: TuringQwenNativeFreshInstanceID
    let segmentIndex: Int
    let voiceID: String
    let referenceCodes: ContiguousArray<Int32>
    let generatedCodes: ContiguousArray<Int32>
    let referenceRowCount: Int
    let generatedRowCount: Int
    let codebookCount: Int
    let reachedEOS: Bool
    let performanceMode: TuringQwenNativePerformanceMode
    let renderMetrics: TuringQwenRenderPhaseMetrics
}

public struct TuringQwenRenderedCodebookSegment: Sendable, Equatable {
    public let runID: String
    public let instanceID: TuringQwenNativeFreshInstanceID
    public let segmentIndex: Int
    public let voiceID: String
    public let referenceCodes: ContiguousArray<Int32>
    public let generatedCodes: ContiguousArray<Int32>
    public let referenceRowCount: Int
    public let generatedRowCount: Int
    public let codebookCount: Int
    public let reachedEOS: Bool
    public let performanceMode: TuringQwenNativePerformanceMode
    public let renderMetrics: TuringQwenRenderPhaseMetrics
    public let releaseToken: TuringQwenRenderReleaseToken
    public let recoveryGeneration: TuringQwenNativeRecoveryGeneration

    public init(
        runID: String,
        instanceID: TuringQwenNativeFreshInstanceID,
        segmentIndex: Int,
        voiceID: String,
        referenceCodes: ContiguousArray<Int32>,
        generatedCodes: ContiguousArray<Int32>,
        referenceRowCount: Int,
        generatedRowCount: Int,
        codebookCount: Int,
        reachedEOS: Bool,
        performanceMode: TuringQwenNativePerformanceMode,
        renderMetrics: TuringQwenRenderPhaseMetrics,
        releaseToken: TuringQwenRenderReleaseToken,
        recoveryGeneration: TuringQwenNativeRecoveryGeneration = .initial
    ) {
        self.runID = runID
        self.instanceID = instanceID
        self.segmentIndex = segmentIndex
        self.voiceID = voiceID
        self.referenceCodes = referenceCodes
        self.generatedCodes = generatedCodes
        self.referenceRowCount = referenceRowCount
        self.generatedRowCount = generatedRowCount
        self.codebookCount = codebookCount
        self.reachedEOS = reachedEOS
        self.performanceMode = performanceMode
        self.renderMetrics = renderMetrics
        self.releaseToken = releaseToken
        self.recoveryGeneration = recoveryGeneration
    }

    public func withRecoveryGeneration(
        _ generation: TuringQwenNativeRecoveryGeneration
    ) -> Self {
        .init(
            runID: runID,
            instanceID: instanceID,
            segmentIndex: segmentIndex,
            voiceID: voiceID,
            referenceCodes: referenceCodes,
            generatedCodes: generatedCodes,
            referenceRowCount: referenceRowCount,
            generatedRowCount: generatedRowCount,
            codebookCount: codebookCount,
            reachedEOS: reachedEOS,
            performanceMode: performanceMode,
            renderMetrics: renderMetrics,
            releaseToken: .init(
                runID: releaseToken.runID,
                segmentIndex: releaseToken.segmentIndex,
                instanceID: releaseToken.instanceID,
                releaseID: releaseToken.releaseID,
                recoveryGeneration: generation
            ),
            recoveryGeneration: generation
        )
    }

    public var rowsForDecode: [[Int]] {
        let decodeReferenceRowCount = min(
            referenceRowCount,
            TuringQwenDecodeConfiguration.referenceContextRows
        )
        let referenceRows = Self.rows(
            from: referenceCodes,
            rowRange: (referenceRowCount - decodeReferenceRowCount)..<referenceRowCount,
            codebookCount: codebookCount
        )
        let generatedRows = Self.rows(
            from: generatedCodes,
            rowRange: 0..<generatedRowCount,
            codebookCount: codebookCount
        )
        return referenceRows + generatedRows
    }

    public var decodeReferenceRowCount: Int {
        min(
            referenceRowCount,
            TuringQwenDecodeConfiguration.referenceContextRows
        )
    }

    private static func rows(
        from codes: ContiguousArray<Int32>,
        rowRange: Range<Int>,
        codebookCount: Int
    ) -> [[Int]] {
        guard rowRange.isEmpty == false, codebookCount > 0 else { return [] }
        precondition(rowRange.lowerBound >= 0)
        precondition(rowRange.upperBound * codebookCount <= codes.count)
        return rowRange.map { rowIndex in
            let start = rowIndex * codebookCount
            return (0..<codebookCount).map { offset in
                Int(codes[start + offset])
            }
        }
    }
}
