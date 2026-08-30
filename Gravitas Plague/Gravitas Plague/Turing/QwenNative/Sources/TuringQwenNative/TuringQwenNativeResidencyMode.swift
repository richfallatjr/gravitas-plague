import Foundation

public enum TuringQwenNativeResidencyMode:
    String,
    Codable,
    Sendable,
    Equatable,
    CaseIterable
{
    case independentFresh2
    case sharedImmutableFresh2
    case singleLaneSharedControl

    public var isShippingTopology: Bool {
        switch self {
        case .independentFresh2, .sharedImmutableFresh2:
            return true
        case .singleLaneSharedControl:
            return false
        }
    }

    public var laneCount: Int {
        switch self {
        case .independentFresh2, .sharedImmutableFresh2:
            return 2
        case .singleLaneSharedControl:
            return 1
        }
    }
}
