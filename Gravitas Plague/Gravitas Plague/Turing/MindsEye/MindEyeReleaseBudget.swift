import Foundation

nonisolated struct MindEyeReleaseBudget: Sendable, Codable, Equatable {
    struct Memory: Sendable, Codable, Equatable {
        let maximumActiveIncrementMiB: Double
        let maximumQwenOverlapIncrementVersusQwenControlMiB: Double
        let maximumPostDismissResidualMiB: Double
        let maximumSecondRunResidualGrowthMiB: Double
        let maximumTenCycleResidualGrowthMiB: Double
        let releaseObservationSeconds: [Double]
    }

    struct Latency: Sendable, Codable, Equatable {
        let maximumActualAudioStartP95RegressionMilliseconds: Double
        let maximumLateJoinVisualWorkOnAudioCriticalPathMilliseconds: Double
    }

    struct CPU: Sendable, Codable, Equatable {
        let maximumMindEyeSystemP95Milliseconds: Double
        let maximumMainThreadP95RegressionMilliseconds: Double
        let maximumCompositorEncodeP95Milliseconds: Double
    }

    struct GPU: Sendable, Codable, Equatable {
        let maximumCompositorGPUFractionOfFrameInterval: Double
        let maximumRoutineCropClampRate: Double
    }

    struct Stability: Sendable, Codable, Equatable {
        let maximumUnexpectedMemoryWarningsReleaseRun: Int
        let maximumCriticalMemoryEventsReleaseRun: Int
        let maximumCrashes: Int
        let maximumJetsamTerminations: Int
        let maximumOrphanEntities: Int
        let maximumRegistryEntriesAfterTeardown: Int
        let maximumLeasesAfterTeardown: Int
    }

    struct BundleBudget: Sendable, Codable, Equatable {
        let maximumDuplicateMindEyeResourceCopies: Int
        let maximumAuthoringArtifactsInApp: Int
        let maximumUnexpectedMindEyeAudioCopies: Int
    }

    let schemaVersion: Int
    let budgetVersion: String
    let memory: Memory
    let latency: Latency
    let cpu: CPU
    let gpu: GPU
    let stability: Stability
    let bundle: BundleBudget

    func validationErrors() -> [String] {
        var errors: [String] = []
        if schemaVersion != 1 { errors.append("schemaVersion") }
        if budgetVersion != "mind-eye-release-budget/1" { errors.append("budgetVersion") }
        let doubles = [
            memory.maximumActiveIncrementMiB,
            memory.maximumQwenOverlapIncrementVersusQwenControlMiB,
            memory.maximumPostDismissResidualMiB,
            memory.maximumSecondRunResidualGrowthMiB,
            memory.maximumTenCycleResidualGrowthMiB,
            latency.maximumActualAudioStartP95RegressionMilliseconds,
            latency.maximumLateJoinVisualWorkOnAudioCriticalPathMilliseconds,
            cpu.maximumMindEyeSystemP95Milliseconds,
            cpu.maximumMainThreadP95RegressionMilliseconds,
            cpu.maximumCompositorEncodeP95Milliseconds,
            gpu.maximumCompositorGPUFractionOfFrameInterval,
            gpu.maximumRoutineCropClampRate
        ] + memory.releaseObservationSeconds
        if doubles.contains(where: { !$0.isFinite || $0 < 0 }) {
            errors.append("nonnegativeFiniteBudgets")
        }
        let integers = [
            stability.maximumUnexpectedMemoryWarningsReleaseRun,
            stability.maximumCriticalMemoryEventsReleaseRun,
            stability.maximumCrashes,
            stability.maximumJetsamTerminations,
            stability.maximumOrphanEntities,
            stability.maximumRegistryEntriesAfterTeardown,
            stability.maximumLeasesAfterTeardown,
            bundle.maximumDuplicateMindEyeResourceCopies,
            bundle.maximumAuthoringArtifactsInApp,
            bundle.maximumUnexpectedMindEyeAudioCopies
        ]
        if integers.contains(where: { $0 < 0 }) { errors.append("nonnegativeCountBudgets") }
        if memory.releaseObservationSeconds != [0, 2, 5, 15, 30] {
            errors.append("releaseObservationSeconds")
        }
        return errors.sorted()
    }
}
