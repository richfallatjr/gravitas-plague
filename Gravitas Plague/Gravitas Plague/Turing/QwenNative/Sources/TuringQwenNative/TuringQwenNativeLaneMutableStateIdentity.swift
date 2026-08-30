import Foundation

public struct TuringQwenNativeLaneMutableStateIdentity:
    Sendable,
    Equatable,
    Hashable,
    Codable
{
    public let laneInstanceID: String
    public let engineID: UUID
    public let mutableStateID: UUID
    public let staticPromptCacheID: UUID
    public let talkerKVCacheOwnerID: UUID
    public let codePredictorKVCacheOwnerID: UUID
    public let samplerStateOwnerID: UUID

    public init(
        laneInstanceID: String,
        engineID: UUID,
        mutableStateID: UUID,
        staticPromptCacheID: UUID,
        talkerKVCacheOwnerID: UUID,
        codePredictorKVCacheOwnerID: UUID,
        samplerStateOwnerID: UUID
    ) {
        self.laneInstanceID = laneInstanceID
        self.engineID = engineID
        self.mutableStateID = mutableStateID
        self.staticPromptCacheID = staticPromptCacheID
        self.talkerKVCacheOwnerID = talkerKVCacheOwnerID
        self.codePredictorKVCacheOwnerID = codePredictorKVCacheOwnerID
        self.samplerStateOwnerID = samplerStateOwnerID
    }
}
