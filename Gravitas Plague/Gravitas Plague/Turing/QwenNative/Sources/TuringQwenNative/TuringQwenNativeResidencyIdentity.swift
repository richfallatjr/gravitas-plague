import Foundation

public struct TuringQwenNativeResidencyIdentity:
    Sendable,
    Equatable,
    Hashable,
    Codable
{
    public let ownerID: UUID
    public let generation: UInt64
    public let modelID: String
    public let quantization: String
    public let standardizedModelRootPath: String
    public let voiceID: String
    public let variantID: String
    public let weightStoreID: UUID
    public let cloneConditioningID: UUID

    public init(
        ownerID: UUID,
        generation: UInt64,
        modelID: String,
        quantization: String,
        standardizedModelRootPath: String,
        voiceID: String,
        variantID: String,
        weightStoreID: UUID,
        cloneConditioningID: UUID
    ) {
        self.ownerID = ownerID
        self.generation = generation
        self.modelID = modelID
        self.quantization = quantization
        self.standardizedModelRootPath = standardizedModelRootPath
        self.voiceID = voiceID
        self.variantID = variantID
        self.weightStoreID = weightStoreID
        self.cloneConditioningID = cloneConditioningID
    }
}
