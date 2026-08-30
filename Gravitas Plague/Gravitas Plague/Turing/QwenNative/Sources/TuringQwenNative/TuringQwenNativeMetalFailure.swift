import Foundation
import MLX

/// A run-fatal MLX/Metal failure carrying the exact bounded command-buffer record.
/// This type must remain intact until the final Turing UI/log boundary.
public struct TuringQwenNativeMetalFailure:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    public let record: TuringMetalCommandBufferFailure

    public init(record: TuringMetalCommandBufferFailure) {
        self.record = record
    }

    public var errorDescription: String? {
        record.errorDescription
    }
}
