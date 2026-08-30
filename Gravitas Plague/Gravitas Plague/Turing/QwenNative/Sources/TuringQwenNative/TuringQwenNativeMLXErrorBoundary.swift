import Foundation
import MLX

public enum TuringQwenNativeMLXErrorBoundary {
    public static func run<R>(
        context: TuringQwenNativeMLXExecutionContext,
        operation: () throws -> R
    ) throws -> R {
        let epochBefore = TuringMetalDiagnostics.failureEpoch

        do {
            let result = try withError {
                try TuringMetalDiagnostics.withContext(context.metalContext) {
                    try operation()
                }
            }
            try throwIfNewMetalFailure(after: epochBefore)
            return result
        } catch {
            if let failure = newMetalFailure(after: epochBefore) {
                throw TuringQwenNativeMetalFailure(record: failure)
            }
            throw error
        }
    }

    /// This overload scopes MLX's Swift error handler only. Thread-local command-buffer
    /// context must be installed by a synchronous `run` at each actual MLX operation.
    public static func run<R: Sendable>(
        context: TuringQwenNativeMLXExecutionContext,
        operation: @Sendable () async throws -> R
    ) async throws -> R {
        let epochBefore = TuringMetalDiagnostics.failureEpoch

        do {
            let result = try await withError {
                try await operation()
            }
            try throwIfNewMetalFailure(after: epochBefore)
            return result
        } catch {
            if let failure = newMetalFailure(after: epochBefore) {
                throw TuringQwenNativeMetalFailure(record: failure)
            }
            throw error
        }
    }

    private static func throwIfNewMetalFailure(after epoch: UInt64) throws {
        if let failure = newMetalFailure(after: epoch) {
            throw TuringQwenNativeMetalFailure(record: failure)
        }
    }

    private static func newMetalFailure(
        after epoch: UInt64
    ) -> TuringMetalCommandBufferFailure? {
        guard TuringMetalDiagnostics.failureEpoch > epoch else { return nil }
        return TuringMetalDiagnostics.lastFailure()
    }
}
