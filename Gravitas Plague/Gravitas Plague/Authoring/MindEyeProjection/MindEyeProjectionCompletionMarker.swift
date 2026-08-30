#if DEBUG || GR_MIND_EYE_PROJECTION_AUTHORING
import Foundation

nonisolated struct MindEyeProjectionCompletionMarker: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let captureID: String
    let status: String
    let manifest: String?
    let cameraSHA256: String?
    let outputSetSHA256: String?
    let failureCode: String?
    let message: String?
}
#endif
