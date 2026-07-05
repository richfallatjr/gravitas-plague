import Foundation

public struct TuringQwenNativeFreshInstanceConfig: Sendable, Equatable {
    public static let exactTwo = TuringQwenNativeFreshInstanceConfig(
        requestedInstanceCount: 2,
        allowSharedWeightLaneFallback: false,
        allowSingleInstanceFallback: false,
        warmLoadBeforeRun: true
    )

    public let requestedInstanceCount: Int
    public let allowSharedWeightLaneFallback: Bool
    public let allowSingleInstanceFallback: Bool
    public let warmLoadBeforeRun: Bool

    public init(
        requestedInstanceCount: Int,
        allowSharedWeightLaneFallback: Bool,
        allowSingleInstanceFallback: Bool,
        warmLoadBeforeRun: Bool
    ) {
        self.requestedInstanceCount = requestedInstanceCount
        self.allowSharedWeightLaneFallback = allowSharedWeightLaneFallback
        self.allowSingleInstanceFallback = allowSingleInstanceFallback
        self.warmLoadBeforeRun = warmLoadBeforeRun
    }

    public func validateExactTwoFreshInstances() throws {
        guard requestedInstanceCount == 2,
              allowSharedWeightLaneFallback == false,
              allowSingleInstanceFallback == false,
              warmLoadBeforeRun else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Qwen fresh-instance scheduler requires exactly two warm fresh instances with no fallback."
            )
        }
    }
}
