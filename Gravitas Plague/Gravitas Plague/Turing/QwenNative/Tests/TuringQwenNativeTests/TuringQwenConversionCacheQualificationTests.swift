import Testing
@testable import TuringQwenNative

struct TuringQwenConversionCacheQualificationTests {
    private func snapshot(_ owner: String, hits: UInt64 = 0, model: String = "model",
                          generation: UInt64 = 1, budget: Int = 16_777_216,
                          bytes: Int = 14_024_704) -> TuringQwenNativeConversionCacheSnapshot {
        var value = TuringQwenNativeConversionCacheSnapshot(
            status: "materialized", reason: nil, weightStoreID: owner,
            modelRevision: model, recoveryGeneration: generation,
            executionContext: "gpu.0", materializationContext: "cpu",
            hotsetID: "c1.predictor-affine-bf16-companions.v1",
            byteBudget: budget, plannedTensorCount: 102, materializedTensorCount: 102,
            retainedBytes: bytes, sourceCompanionBytes: bytes / 2,
            coldMaterializationSeconds: 0.01, processFootprintBeforeMB: 100,
            processFootprintAfterMB: 114, inventory: [])
        value.cacheHits = hits
        value.eligibilityChecks = hits
        return value
    }

    @Test func twoOwnersMustActuallyBeUsedAfterLoad() {
        let load = [snapshot("a", hits: 9), snapshot("b", hits: 9)]
        #expect(TuringQwenConversionCacheQualification.validLoad(load))
        #expect(!TuringQwenConversionCacheQualification.validRender(load: load, end: load))
        #expect(!TuringQwenConversionCacheQualification.validRender(load: load,
            end: [snapshot("a", hits: 10), snapshot("b", hits: 9)]))
        #expect(TuringQwenConversionCacheQualification.validRender(load: load,
            end: [snapshot("b", hits: 10), snapshot("a", hits: 10)]))
    }

    @Test func replacedOwnerModelOrGenerationCannotMasqueradeAsTheSameCache() {
        let load = [snapshot("a"), snapshot("b")]
        for changed in [snapshot("c", hits: 2), snapshot("a", hits: 2, model: "other"),
                        snapshot("a", hits: 2, generation: 2)] {
            #expect(!TuringQwenConversionCacheQualification.validRender(load: load,
                end: [changed, snapshot("b", hits: 2)]))
        }
        #expect(!TuringQwenConversionCacheQualification.validLoad([snapshot("a"), snapshot("a")]))
        #expect(!TuringQwenConversionCacheQualification.validLoad([]))
    }

    @Test func invalidBudgetAndFallbackNeverQualify() {
        #expect(!TuringQwenConversionCacheQualification.validLoad([
            snapshot("a", budget: 1), snapshot("b")]))
        #expect(!TuringQwenConversionCacheQualification.validLoad([
            snapshot("a", budget: 33_554_432), snapshot("b")]))
        #expect(!TuringQwenConversionCacheQualification.validLoad([
            snapshot("a", bytes: 0), snapshot("b")]))
        let load = [snapshot("a"), snapshot("b")]
        var changed = snapshot("a", hits: 2)
        changed.contextMisses = 1
        #expect(!TuringQwenConversionCacheQualification.validRender(load: load, end: [changed, snapshot("b", hits: 2)]))
        changed.contextMisses = 0
        changed.staleGenerationMisses = 1
        #expect(!TuringQwenConversionCacheQualification.validRender(load: load, end: [changed, snapshot("b", hits: 2)]))
        changed.staleGenerationMisses = 0
        changed.unavailableMisses = 1
        #expect(!TuringQwenConversionCacheQualification.validRender(load: load, end: [changed, snapshot("b", hits: 2)]))
    }

    @Test func originalDTypePathIsAllowedAndRemainsVisible() {
        var after = snapshot("a", hits: 2)
        after.dtypeMisses = 3
        after.eligibilityChecks = 5
        #expect(TuringQwenConversionCacheQualification.validRender(
            load: [snapshot("a"), snapshot("b")], end: [after, snapshot("b", hits: 2)]))
    }
}
