import Foundation

nonisolated struct MindEyeReleaseTimingSnapshot: Sendable, Codable, Equatable {
    let actualAudioStartLatencyMilliseconds: Double?
    let visualReadyAfterActualStartMilliseconds: Double?
    let generatedAnalysisMilliseconds: Double?
    let motionSystemCPUP50Milliseconds: Double?
    let motionSystemCPUP95Milliseconds: Double?
    let authoredSystemCPUP50Milliseconds: Double?
    let authoredSystemCPUP95Milliseconds: Double?
    let generatedSystemCPUP50Milliseconds: Double?
    let generatedSystemCPUP95Milliseconds: Double?
    let compositorEncodeP50Milliseconds: Double?
    let compositorEncodeP95Milliseconds: Double?
    let compositorGPUP50Milliseconds: Double?
    let compositorGPUP95Milliseconds: Double?
    let frameIntervalMilliseconds: Double?
    let mainThreadFrameP95Milliseconds: Double?

    init(
        actualAudioStartLatencyMilliseconds: Double? = nil,
        visualReadyAfterActualStartMilliseconds: Double? = nil,
        generatedAnalysisMilliseconds: Double? = nil,
        motionSystemCPUP50Milliseconds: Double? = nil,
        motionSystemCPUP95Milliseconds: Double? = nil,
        authoredSystemCPUP50Milliseconds: Double? = nil,
        authoredSystemCPUP95Milliseconds: Double? = nil,
        generatedSystemCPUP50Milliseconds: Double? = nil,
        generatedSystemCPUP95Milliseconds: Double? = nil,
        compositorEncodeP50Milliseconds: Double? = nil,
        compositorEncodeP95Milliseconds: Double? = nil,
        compositorGPUP50Milliseconds: Double? = nil,
        compositorGPUP95Milliseconds: Double? = nil,
        frameIntervalMilliseconds: Double? = nil,
        mainThreadFrameP95Milliseconds: Double? = nil
    ) {
        self.actualAudioStartLatencyMilliseconds = actualAudioStartLatencyMilliseconds
        self.visualReadyAfterActualStartMilliseconds = visualReadyAfterActualStartMilliseconds
        self.generatedAnalysisMilliseconds = generatedAnalysisMilliseconds
        self.motionSystemCPUP50Milliseconds = motionSystemCPUP50Milliseconds
        self.motionSystemCPUP95Milliseconds = motionSystemCPUP95Milliseconds
        self.authoredSystemCPUP50Milliseconds = authoredSystemCPUP50Milliseconds
        self.authoredSystemCPUP95Milliseconds = authoredSystemCPUP95Milliseconds
        self.generatedSystemCPUP50Milliseconds = generatedSystemCPUP50Milliseconds
        self.generatedSystemCPUP95Milliseconds = generatedSystemCPUP95Milliseconds
        self.compositorEncodeP50Milliseconds = compositorEncodeP50Milliseconds
        self.compositorEncodeP95Milliseconds = compositorEncodeP95Milliseconds
        self.compositorGPUP50Milliseconds = compositorGPUP50Milliseconds
        self.compositorGPUP95Milliseconds = compositorGPUP95Milliseconds
        self.frameIntervalMilliseconds = frameIntervalMilliseconds
        self.mainThreadFrameP95Milliseconds = mainThreadFrameP95Milliseconds
    }

    static let empty = MindEyeReleaseTimingSnapshot(
        actualAudioStartLatencyMilliseconds: nil,
        visualReadyAfterActualStartMilliseconds: nil,
        generatedAnalysisMilliseconds: nil,
        motionSystemCPUP50Milliseconds: nil,
        motionSystemCPUP95Milliseconds: nil,
        authoredSystemCPUP50Milliseconds: nil,
        authoredSystemCPUP95Milliseconds: nil,
        generatedSystemCPUP50Milliseconds: nil,
        generatedSystemCPUP95Milliseconds: nil,
        compositorEncodeP50Milliseconds: nil,
        compositorEncodeP95Milliseconds: nil,
        compositorGPUP50Milliseconds: nil,
        compositorGPUP95Milliseconds: nil,
        frameIntervalMilliseconds: nil,
        mainThreadFrameP95Milliseconds: nil
    )

    var containsOnlyFiniteValues: Bool {
        let values = [
            actualAudioStartLatencyMilliseconds,
            visualReadyAfterActualStartMilliseconds,
            generatedAnalysisMilliseconds,
            motionSystemCPUP50Milliseconds,
            motionSystemCPUP95Milliseconds,
            authoredSystemCPUP50Milliseconds,
            authoredSystemCPUP95Milliseconds,
            generatedSystemCPUP50Milliseconds,
            generatedSystemCPUP95Milliseconds,
            compositorEncodeP50Milliseconds,
            compositorEncodeP95Milliseconds,
            compositorGPUP50Milliseconds,
            compositorGPUP95Milliseconds,
            frameIntervalMilliseconds,
            mainThreadFrameP95Milliseconds
        ]
        return values.compactMap { $0 }.allSatisfy(\.isFinite)
    }

    func fillingMissingValues(
        from fallback: MindEyeReleaseTimingSnapshot
    ) -> MindEyeReleaseTimingSnapshot {
        MindEyeReleaseTimingSnapshot(
            actualAudioStartLatencyMilliseconds:
                actualAudioStartLatencyMilliseconds ?? fallback.actualAudioStartLatencyMilliseconds,
            visualReadyAfterActualStartMilliseconds:
                visualReadyAfterActualStartMilliseconds ?? fallback.visualReadyAfterActualStartMilliseconds,
            generatedAnalysisMilliseconds:
                generatedAnalysisMilliseconds ?? fallback.generatedAnalysisMilliseconds,
            motionSystemCPUP50Milliseconds:
                motionSystemCPUP50Milliseconds ?? fallback.motionSystemCPUP50Milliseconds,
            motionSystemCPUP95Milliseconds:
                motionSystemCPUP95Milliseconds ?? fallback.motionSystemCPUP95Milliseconds,
            authoredSystemCPUP50Milliseconds:
                authoredSystemCPUP50Milliseconds ?? fallback.authoredSystemCPUP50Milliseconds,
            authoredSystemCPUP95Milliseconds:
                authoredSystemCPUP95Milliseconds ?? fallback.authoredSystemCPUP95Milliseconds,
            generatedSystemCPUP50Milliseconds:
                generatedSystemCPUP50Milliseconds ?? fallback.generatedSystemCPUP50Milliseconds,
            generatedSystemCPUP95Milliseconds:
                generatedSystemCPUP95Milliseconds ?? fallback.generatedSystemCPUP95Milliseconds,
            compositorEncodeP50Milliseconds:
                compositorEncodeP50Milliseconds ?? fallback.compositorEncodeP50Milliseconds,
            compositorEncodeP95Milliseconds:
                compositorEncodeP95Milliseconds ?? fallback.compositorEncodeP95Milliseconds,
            compositorGPUP50Milliseconds:
                compositorGPUP50Milliseconds ?? fallback.compositorGPUP50Milliseconds,
            compositorGPUP95Milliseconds:
                compositorGPUP95Milliseconds ?? fallback.compositorGPUP95Milliseconds,
            frameIntervalMilliseconds:
                frameIntervalMilliseconds ?? fallback.frameIntervalMilliseconds,
            mainThreadFrameP95Milliseconds:
                mainThreadFrameP95Milliseconds ?? fallback.mainThreadFrameP95Milliseconds
        )
    }
}

nonisolated struct MindEyeReleaseQualificationEvent:
    Sendable, Codable, Equatable
{
    let schemaVersion: Int
    let run: MindEyeReleaseScenarioRun
    let ordinal: UInt64
    let checkpoint: MindEyeQualificationCheckpoint
    let continuousNanosecondsSinceRunStart: UInt64
    let playbackRunID: String?
    let mediaIdentity: String?
    let speakerCharacterID: String?
    let interactionSurface: String?
    let resource: MindEyeReleaseResourceSnapshot
    let timing: MindEyeReleaseTimingSnapshot
    let notes: [String]
}
