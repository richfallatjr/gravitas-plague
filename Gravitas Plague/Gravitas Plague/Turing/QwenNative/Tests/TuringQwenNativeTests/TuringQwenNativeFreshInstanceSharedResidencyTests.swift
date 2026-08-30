import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeFreshInstanceSharedResidencyTests {
    @Test
    func sharedOwnershipReportRequiresOneOwnerAndTwoMutableLanes() throws {
        let report = phase3OwnershipReport(mode: .sharedImmutableFresh2)
        try TuringQwenNativeResidencyAudit.validate(report)
        #expect(report.uniqueResidentResourceCount == 1)
        #expect(report.uniqueLaneMutableStateCount == 2)
    }
}

func phase3OwnershipReport(
    mode: TuringQwenNativeResidencyMode
) -> TuringQwenNativeResidencyOwnershipReport {
    let shared = mode != .independentFresh2
    let lanes = mode.laneCount
    return .init(
        mode: mode,
        requestedLaneCount: lanes,
        actualLaneCount: lanes,
        uniqueResidentResourceCount: shared ? 1 : lanes,
        uniqueWeightStoreCount: shared ? 1 : lanes,
        uniqueCloneConditioningCount: shared ? 1 : 0,
        laneEngineCount: lanes,
        uniqueLaneMutableStateCount: lanes,
        uniqueStaticPromptCacheCount: lanes,
        uniqueTalkerKVCacheOwnerCount: lanes,
        uniqueCodePredictorKVCacheOwnerCount: lanes,
        uniqueSamplerStateOwnerCount: lanes,
        activeLeaseCountAtReady: shared ? lanes : 0,
        activeLeaseCountAtFinish: shared ? lanes : 0,
        decoderSessionCount: 1,
        fallbackUsed: false
    )
}
