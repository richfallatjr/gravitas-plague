import Foundation

struct TuringQwenNativeResidencyLeaseRegistry: Sendable, Equatable {
    private(set) var lanesByLeaseID:
        [UUID: TuringQwenNativeFreshInstanceID] = [:]

    var count: Int { lanesByLeaseID.count }
    var isEmpty: Bool { lanesByLeaseID.isEmpty }

    mutating func acquire(
        laneInstanceID: TuringQwenNativeFreshInstanceID
    ) throws -> UUID {
        guard lanesByLeaseID.count < 2 else {
            throw TuringQwenNativeError.invalidConfig(
                "Shared residency already has two active lane leases."
            )
        }
        guard lanesByLeaseID.values.contains(laneInstanceID) == false else {
            throw TuringQwenNativeError.invalidConfig(
                "Shared residency already has a lease for \(laneInstanceID.rawValue)."
            )
        }
        let leaseID = UUID()
        lanesByLeaseID[leaseID] = laneInstanceID
        return leaseID
    }

    mutating func release(
        leaseID: UUID,
        laneInstanceID: TuringQwenNativeFreshInstanceID
    ) throws {
        guard lanesByLeaseID[leaseID] == laneInstanceID else {
            throw TuringQwenNativeError.invalidConfig(
                "Duplicate shared residency lease release."
            )
        }
        lanesByLeaseID.removeValue(forKey: leaseID)
    }
}
