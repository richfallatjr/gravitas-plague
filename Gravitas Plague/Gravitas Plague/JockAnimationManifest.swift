import Foundation

struct JockAnimationManifest: Codable, Equatable {
    struct ClipSummary: Codable, Identifiable, Equatable {
        let clipID: String
        let displayName: String
        let relativePath: String
        let rigID: String
        let rigVersion: String
        let poseMode: String
        let category: [String]
        let emotion: [String]
        let threat: [String]
        let story: [String]
        let looping: Bool
        let durationSeconds: Double
        let locomotionType: String
        let worldSpaceMotion: String
        let locomotionEnabled: Bool?
        let locomotionStartMode: String?
        let approvedForRuntime: Bool
        let debugOnly: Bool
        let updatedAt: String?

        var id: String { clipID }

        enum CodingKeys: String, CodingKey {
            case clipID = "clip_id"
            case displayName = "display_name"
            case relativePath = "relative_path"
            case rigID = "rig_id"
            case rigVersion = "rig_version"
            case poseMode = "pose_mode"
            case category
            case emotion
            case threat
            case story
            case looping
            case durationSeconds = "duration_seconds"
            case locomotionType = "locomotion_type"
            case worldSpaceMotion = "world_space_motion"
            case locomotionEnabled = "locomotion_enabled"
            case locomotionStartMode = "locomotion_start_mode"
            case approvedForRuntime = "approved_for_runtime"
            case debugOnly = "debug_only"
            case updatedAt = "updated_at"
        }
    }

    let schema: String
    let libraryID: String
    let generatedAt: String
    let clips: [ClipSummary]

    enum CodingKeys: String, CodingKey {
        case schema
        case libraryID = "library_id"
        case generatedAt = "generated_at"
        case clips
    }
}
