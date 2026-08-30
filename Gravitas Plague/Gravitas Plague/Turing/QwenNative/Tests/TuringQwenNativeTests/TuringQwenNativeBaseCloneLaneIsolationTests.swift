import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeBaseCloneLaneIsolationTests {
    @Test
    func laneMutableOwnershipIdentitiesAreDistinct() {
        let first = phase3MutableIdentity(lane: 0)
        let second = phase3MutableIdentity(lane: 1)
        #expect(first.engineID != second.engineID)
        #expect(first.mutableStateID != second.mutableStateID)
        #expect(first.staticPromptCacheID != second.staticPromptCacheID)
        #expect(first.talkerKVCacheOwnerID != second.talkerKVCacheOwnerID)
        #expect(first.codePredictorKVCacheOwnerID != second.codePredictorKVCacheOwnerID)
        #expect(first.samplerStateOwnerID != second.samplerStateOwnerID)
    }
}

func phase3MutableIdentity(lane: Int) -> TuringQwenNativeLaneMutableStateIdentity {
    .init(
        laneInstanceID: "fresh-\(lane)",
        engineID: UUID(),
        mutableStateID: UUID(),
        staticPromptCacheID: UUID(),
        talkerKVCacheOwnerID: UUID(),
        codePredictorKVCacheOwnerID: UUID(),
        samplerStateOwnerID: UUID()
    )
}
