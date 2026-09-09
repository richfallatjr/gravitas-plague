import Foundation
import MLX

public enum TuringQwenNativeLaneStreamMode: String, Sendable {
    case defaultOnly
    case dedicatedGPU

    /// Shipping Fresh2 continues to use MLX's existing default stream. A
    /// dedicated stream is an explicit qualification-only opt-in until device
    /// measurements demonstrate that it is both stable and faster.
    public static let productionDefault: Self = .defaultOnly
}

public struct TuringQwenNativeLaneStream: Sendable {
    public let laneID: Int
    public let mode: TuringQwenNativeLaneStreamMode
    public let mlxStream: MLX.Stream?

    public init(
        laneID: Int,
        mode: TuringQwenNativeLaneStreamMode = .productionDefault
    ) {
        self.init(
            laneID: laneID,
            mode: mode,
            makeDedicatedGPUStream: {
                MLX.Stream(.gpu)
            }
        )
    }

    init(
        laneID: Int,
        mode: TuringQwenNativeLaneStreamMode,
        makeDedicatedGPUStream: () -> MLX.Stream
    ) {
        self.laneID = laneID
        self.mode = mode
        switch mode {
        case .defaultOnly:
            mlxStream = nil
        case .dedicatedGPU:
            mlxStream = makeDedicatedGPUStream()
        }
    }

    public var ownsDedicatedStream: Bool {
        mlxStream != nil
    }

    /// Runs MLX operations with this lane's stable stream installed as MLX's
    /// task-local default. The production default path deliberately performs no
    /// override and therefore retains its pre-Phase-5 behavior.
    public func withExecutionContext<R>(
        _ operation: () throws -> R
    ) rethrows -> R {
        guard let mlxStream else {
            return try operation()
        }
        return try MLX.Stream.withDefaultStream(mlxStream, operation)
    }

    /// Asynchronous counterpart to ``withExecutionContext(_:)``. MLX's
    /// TaskLocal stream follows structured concurrency and actor hops, then is
    /// restored automatically when the operation exits.
    public func withExecutionContext<R: Sendable>(
        _ operation: @Sendable () async throws -> R
    ) async rethrows -> R {
        guard let mlxStream else {
            return try await operation()
        }
        return try await MLX.Stream.withDefaultStream(mlxStream, operation)
    }
}
