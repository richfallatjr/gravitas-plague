import Foundation

nonisolated enum MindEyeReleaseScenario: String, Sendable, Codable, CaseIterable {
    case controlStoryScene
    case coldPackagePrewarm
    case authoredBigMikeAllTen
    case generatedPromptVoice
    case generatedConversationVoice
    case qwenControlNoMindEye
    case qwenOverlapWithMindEye
    case authoredSecondRun
    case generatedSecondRun
    case pauseResume
    case inactiveActive
    case backgroundActive
    case memoryWarning
    case memoryCritical
    case physicalMikeSuppression
    case operationModeTeardown
    case immersiveShutdown
    case tenCycleStress
    case xcodeDebugOverhead
    case videoCaptureOverhead
    case testFlightEquivalent

    var allowsRepeatedCheckpoints: Bool {
        switch self {
        case .authoredBigMikeAllTen, .generatedPromptVoice,
             .generatedConversationVoice, .tenCycleStress:
            true
        default:
            false
        }
    }
}

nonisolated enum MindEyeQualificationBuildConfiguration:
    String, Sendable, Codable, Equatable
{
    case releaseNoDebugger
    case releaseWithCapture
    case debugWithXcode
    case testFlight
}

nonisolated struct MindEyeReleaseScenarioRun:
    Sendable, Codable, Equatable, Hashable
{
    let id: UUID
    let scenario: MindEyeReleaseScenario
    let configuration: MindEyeQualificationBuildConfiguration
    let sequenceNumber: Int
}

nonisolated enum MindEyeQualificationCheckpoint:
    String, Sendable, Codable, CaseIterable, Hashable
{
    case appCold
    case immersiveEntered
    case storySystemsReady
    case beforePackagePrewarm
    case afterPackagePrewarm
    case beforeVisualAttach
    case afterVisualAttach
    case authoredAudioStarted
    case authoredMouthStarted
    case generatedPCMReady
    case generatedAnalysisReady
    case generatedAudioStarted
    case generatedMouthStarted
    case qwenPreflightBefore
    case qwenPreflightAfter
    case qwenGenerationPeak
    case speechCompleted
    case visualDismissed
    case sourceReferencesReleased
    case twoSecondsAfterRelease
    case fiveSecondsAfterRelease
    case fifteenSecondsAfterRelease
    case thirtySecondsAfterRelease
    case operationModeTornDown
    case immersiveShutDown
}

nonisolated enum MindEyeQualificationFeatureMode:
    String, Sendable, Codable, Equatable
{
    case enabled
    case disabledControl
}

nonisolated enum MindEyeQualificationFeatureControl {
    static var mode: MindEyeQualificationFeatureMode {
        #if GR_MIND_EYE_QUALIFICATION
        let prefix = "--mind-eye-qualification-mode="
        guard let value = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix(prefix)
        }).map({ String($0.dropFirst(prefix.count)) }),
        let mode = MindEyeQualificationFeatureMode(rawValue: value) else {
            return .enabled
        }
        return mode
        #else
        return .enabled
        #endif
    }

    static var isMindEyeEnabled: Bool { mode == .enabled }
}
