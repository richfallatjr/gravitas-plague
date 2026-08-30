public enum TuringQwenNativeTargetedBoundaryPolicy:
    String,
    Codable,
    Sendable,
    Equatable,
    CaseIterable
{
    case none
    case dynamicRowCheckpoint
    case codePredictorGroup
    case decoderStage
}
