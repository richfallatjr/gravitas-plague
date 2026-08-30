import Foundation

public enum TuringQwenNativeResidencyAudit {
    public static func validate(
        _ report: TuringQwenNativeResidencyOwnershipReport
    ) throws {
        guard report.fallbackUsed == false else {
            throw TuringQwenNativeError.invalidConfig(
                "Residency topology used a forbidden lane fallback."
            )
        }
        switch report.mode {
        case .independentFresh2:
            guard report.requestedLaneCount == 2,
                  report.actualLaneCount == 2,
                  report.uniqueResidentResourceCount == 2,
                  report.uniqueWeightStoreCount == 2,
                  report.laneEngineCount == 2 else {
                throw TuringQwenNativeError.invalidConfig(
                    "Independent Fresh2 ownership report is invalid."
                )
            }
        case .sharedImmutableFresh2:
            guard report.requestedLaneCount == 2,
                  report.actualLaneCount == 2,
                  report.uniqueResidentResourceCount == 1,
                  report.uniqueWeightStoreCount == 1,
                  report.uniqueCloneConditioningCount == 1,
                  report.laneEngineCount == 2,
                  report.uniqueLaneMutableStateCount == 2,
                  report.uniqueStaticPromptCacheCount == 2,
                  report.uniqueTalkerKVCacheOwnerCount == 2,
                  report.uniqueCodePredictorKVCacheOwnerCount == 2,
                  report.uniqueSamplerStateOwnerCount == 2,
                  report.activeLeaseCountAtReady == 2 else {
                throw TuringQwenNativeError.invalidConfig(
                    "Shared immutable Fresh2 ownership report is invalid."
                )
            }
        case .singleLaneSharedControl:
            guard report.requestedLaneCount == 1,
                  report.actualLaneCount == 1,
                  report.uniqueResidentResourceCount == 1,
                  report.uniqueWeightStoreCount == 1,
                  report.laneEngineCount == 1 else {
                throw TuringQwenNativeError.invalidConfig(
                    "Single-lane shared control ownership report is invalid."
                )
            }
        }
    }
}
