import Foundation

public final class TuringQwenNativeMLXExecutor: @unchecked Sendable {
    public static let shared = TuringQwenNativeMLXExecutor()

    private let queue = DispatchQueue(
        label: "com.gravitas.turing.qwen.native.mlx",
        qos: .userInitiated
    )

    private init() {}

    public func run<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try operation())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
