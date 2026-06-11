import Foundation

struct JockAnimationManifest: Codable, Equatable {
    struct ClipSummary: Codable, Identifiable, Equatable {
        let clipID: String
        let displayName: String
        let relativePath: String
        let rigID: String
        let rigVersion: String
        let poseMode: String
        let clipType: String?
        let affectedJoints: [String]?
        let blendInFrames: Int?
        let blendOutFrames: Int?
        let baseAnimationContinues: Bool?
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
        let sourceRigID: String?
        let sourceCharacterID: String?
        let sourceSkeletonHash: String?
        let sourceRigRelativePath: String?
        let updatedAt: String?

        var id: String { clipID }

        enum CodingKeys: String, CodingKey {
            case clipID = "clip_id"
            case displayName = "display_name"
            case relativePath = "relative_path"
            case rigID = "rig_id"
            case rigVersion = "rig_version"
            case poseMode = "pose_mode"
            case clipType = "clip_type"
            case affectedJoints = "affected_joints"
            case blendInFrames = "blend_in_frames"
            case blendOutFrames = "blend_out_frames"
            case baseAnimationContinues = "base_animation_continues"
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
            case sourceRigID = "source_rig_id"
            case sourceCharacterID = "source_character_id"
            case sourceSkeletonHash = "source_skeleton_hash"
            case sourceRigRelativePath = "source_rig_relative_path"
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
