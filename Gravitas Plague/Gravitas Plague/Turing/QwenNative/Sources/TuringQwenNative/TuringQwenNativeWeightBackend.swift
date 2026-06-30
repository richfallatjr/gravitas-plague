import Foundation

public enum QwenNativeWeightBackend: String, Codable, Sendable {
    case denseBF16 = "dense_bf16"
    case mlx4bit
}

public struct TuringQwenNativeWeightBackend: Sendable {
    public let kind: QwenNativeWeightBackend

    public init(kind: QwenNativeWeightBackend) {
        self.kind = kind
    }

    public static let baseCloneRuntime = TuringQwenNativeWeightBackend(kind: .mlx4bit)
}
