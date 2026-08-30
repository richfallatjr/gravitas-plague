import Foundation

public struct TuringQwenNativeRecoveryGeneration:
    RawRepresentable,
    Codable,
    Hashable,
    Comparable,
    Sendable
{
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let initial = Self(rawValue: 1)

    public static func < (
        lhs: Self,
        rhs: Self
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public func successor() throws -> Self {
        guard rawValue < UInt64.max else {
            throw TuringQwenNativeError.invalidConfig(
                "Turing recovery generation overflow."
            )
        }
        return Self(rawValue: rawValue + 1)
    }
}

public struct TuringQwenNativeRecoverySessionAdmission: Sendable {
    public let sessionID: UUID
    public let runID: String
    public let generation: TuringQwenNativeRecoveryGeneration
}
