import Foundation

public struct TuringQwenNativeSharedResidencyLease:
    @unchecked Sendable,
    Equatable,
    Hashable
{
    public let leaseID: UUID
    public let ownerToken: TuringQwenNativeSharedResidencyOwner.Token
    public let laneInstanceID: TuringQwenNativeFreshInstanceID
    let snapshot: TuringQwenNativeSharedResidencySnapshot

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.leaseID == rhs.leaseID &&
            lhs.ownerToken == rhs.ownerToken &&
            lhs.laneInstanceID == rhs.laneInstanceID
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(leaseID)
        hasher.combine(ownerToken)
        hasher.combine(laneInstanceID)
    }
}
