import Foundation

nonisolated enum MindEyeReleaseQualificationError: Error, Sendable, Equatable {
    case runAlreadyActive
    case noActiveRun
    case invalidRun
    case invalidReport([String])
    case exportUnavailable
}

nonisolated struct MindEyeReleaseQualificationReport:
    Sendable, Codable, Equatable
{
    let schemaVersion: Int
    let reportVersion: String
    let run: MindEyeReleaseScenarioRun
    let events: [MindEyeReleaseQualificationEvent]
    let generatedAtUTC: String?

    func validationErrors() -> [String] {
        var errors: [String] = []
        if schemaVersion != 1 { errors.append("schemaVersion") }
        if reportVersion != "mind-eye-release-qualification/1" {
            errors.append("reportVersion")
        }
        if generatedAtUTC != nil { errors.append("generatedAtUTC") }
        if run.sequenceNumber < 0 { errors.append("run.sequenceNumber") }
        var previousNanoseconds: UInt64 = 0
        var seen = Set<MindEyeQualificationCheckpoint>()
        for (index, event) in events.enumerated() {
            if event.schemaVersion != 1 { errors.append("event.schemaVersion.\(index)") }
            if event.run != run { errors.append("event.run.\(index)") }
            if event.ordinal != UInt64(index) { errors.append("event.ordinal.\(index)") }
            if index > 0,
               event.continuousNanosecondsSinceRunStart < previousNanoseconds {
                errors.append("event.monotonicTime.\(index)")
            }
            previousNanoseconds = event.continuousNanosecondsSinceRunStart
            if !run.scenario.allowsRepeatedCheckpoints,
               !seen.insert(event.checkpoint).inserted {
                errors.append("event.duplicateCheckpoint.\(event.checkpoint.rawValue)")
            } else {
                seen.insert(event.checkpoint)
            }
            if !event.timing.containsOnlyFiniteValues {
                errors.append("event.nonfiniteTiming.\(index)")
            }
            if !event.resource.containsOnlyNonnegativeCounts {
                errors.append("event.negativeResourceCount.\(index)")
            }
            if event.notes != event.notes.sorted() {
                errors.append("event.notesOrdering.\(index)")
            }
            if Self.requiresReleasedOwnership(event.checkpoint),
               !event.resource.hasReleasedRuntimeOwnership {
                errors.append("event.ownershipAfterTeardown.\(index)")
            }
        }
        let missing = Self.requiredCheckpoints(for: run.scenario).subtracting(seen)
        errors += missing.map { "missingCheckpoint.\($0.rawValue)" }
        return errors.sorted()
    }

    func deterministicJSONData() throws -> Data {
        let errors = validationErrors()
        guard errors.isEmpty else {
            throw MindEyeReleaseQualificationError.invalidReport(errors)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    private static func requiresReleasedOwnership(
        _ checkpoint: MindEyeQualificationCheckpoint
    ) -> Bool {
        switch checkpoint {
        case .sourceReferencesReleased, .operationModeTornDown, .immersiveShutDown:
            true
        default:
            false
        }
    }

    private static func requiredCheckpoints(
        for scenario: MindEyeReleaseScenario
    ) -> Set<MindEyeQualificationCheckpoint> {
        switch scenario {
        case .controlStoryScene:
            [.appCold, .immersiveEntered, .storySystemsReady]
        case .coldPackagePrewarm:
            [.beforePackagePrewarm, .afterPackagePrewarm]
        case .authoredBigMikeAllTen, .authoredSecondRun:
            [.authoredAudioStarted, .authoredMouthStarted, .speechCompleted,
             .visualDismissed, .sourceReferencesReleased]
        case .generatedPromptVoice, .generatedConversationVoice, .generatedSecondRun:
            [.generatedPCMReady, .generatedAudioStarted, .generatedMouthStarted,
             .speechCompleted, .sourceReferencesReleased]
        case .qwenControlNoMindEye, .qwenOverlapWithMindEye:
            [.qwenPreflightBefore, .qwenPreflightAfter, .qwenGenerationPeak]
        case .operationModeTeardown:
            [.operationModeTornDown]
        case .immersiveShutdown:
            [.immersiveShutDown]
        default:
            []
        }
    }
}
