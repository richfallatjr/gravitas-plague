import Foundation

struct JockAnimClip: Codable, Equatable {
    struct Source: Codable, Equatable {
        let type: String
        let sourceFile: String
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case type
            case sourceFile = "source_file"
            case notes
        }
    }

    struct Timing: Codable, Equatable {
        let fps: Double
        let durationSeconds: Double
        let looping: Bool

        enum CodingKeys: String, CodingKey {
            case fps
            case durationSeconds = "duration_seconds"
            case looping
        }
    }

    struct Locomotion: Codable, Equatable {
        let locomotionType: String
        let worldSpaceMotion: String
        let recommendedSpeedMPS: Double
        let rootRotationDegrees: Double

        enum CodingKeys: String, CodingKey {
            case locomotionType = "locomotion_type"
            case worldSpaceMotion = "world_space_motion"
            case recommendedSpeedMPS = "recommended_speed_mps"
            case rootRotationDegrees = "root_rotation_degrees"
        }
    }

    struct Transition: Codable, Equatable {
        let defaultTransitionFrames: Int
        let transitionFPS: Double

        enum CodingKeys: String, CodingKey {
            case defaultTransitionFrames = "default_transition_frames"
            case transitionFPS = "transition_fps"
        }

        var transitionDurationSeconds: TimeInterval {
            guard transitionFPS > 0 else { return 5.0 / 24.0 }
            return Double(defaultTransitionFrames) / transitionFPS
        }
    }

    struct Tags: Codable, Equatable {
        let category: [String]
        let emotion: [String]
        let threat: [String]
        let story: [String]
        let allowedStates: [String]

        enum CodingKeys: String, CodingKey {
            case category
            case emotion
            case threat
            case story
            case allowedStates = "allowed_states"
        }
    }

    struct Quality: Codable, Equatable {
        let approvedForRuntime: Bool
        let approvedForEpisode: Bool
        let debugOnly: Bool

        enum CodingKeys: String, CodingKey {
            case approvedForRuntime = "approved_for_runtime"
            case approvedForEpisode = "approved_for_episode"
            case debugOnly = "debug_only"
        }
    }

    struct Track: Codable, Equatable {
        let joint: String
        let channel: String
        let keys: [Key]
    }

    struct Key: Codable, Equatable {
        let t: Double
        let value: [Float]
    }

    let schema: String
    let clipID: String
    let displayName: String
    let rigID: String
    let rigVersion: String
    let poseMode: String
    let source: Source
    let timing: Timing
    let joints: [String]
    let tracks: [Track]
    let locomotion: Locomotion
    let transition: Transition
    let tags: Tags
    let quality: Quality
    let notes: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case clipID = "clip_id"
        case displayName = "display_name"
        case rigID = "rig_id"
        case rigVersion = "rig_version"
        case poseMode = "pose_mode"
        case source
        case timing
        case joints
        case tracks
        case locomotion
        case transition
        case tags
        case quality
        case notes
    }

    var isAdditiveLocal: Bool {
        poseMode == "additiveLocal"
    }

    var isAbsoluteLocal: Bool {
        poseMode == "absoluteLocal"
    }
}
