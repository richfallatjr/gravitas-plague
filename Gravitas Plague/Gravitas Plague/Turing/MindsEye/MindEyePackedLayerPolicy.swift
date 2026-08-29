import Foundation

nonisolated enum MindEyePackedLayerPolicy: String, Sendable, Codable, Equatable {
    case disabled
    case transparentOverlaysOnly

    static let production: MindEyePackedLayerPolicy = .disabled
}
