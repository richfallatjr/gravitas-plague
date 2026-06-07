import Foundation

struct JockAnimClip: Codable, Equatable {
    struct Source: Codable, Equatable {
        let type: String
        let sourceFile: String
        let sourcePath: String?
        let notes: String?

        enum CodingKeys: String, CodingKey {
            case type
            case sourceFile = "source_file"
            case sourcePath = "source_path"
            case notes
        }
    }

    struct SourceRig: Codable, Equatable {
        struct RestLocalTransform: Codable, Equatable {
            let translationXYZ: [Float]
            let rotationQuatWXYZ: [Float]
            let scaleXYZ: [Float]

            enum CodingKeys: String, CodingKey {
                case translationXYZ = "translation_xyz"
                case rotationQuatWXYZ = "rotation_quat_wxyz"
                case scaleXYZ = "scale_xyz"
            }
        }

        let schema: String?
        let characterID: String?
        let sourceUSDZ: String?
        let sourceUSDZPath: String?
        let skeletonHash: String?
        let jointPaths: [String]
        let restLocalTransforms: [String: RestLocalTransform]

        enum CodingKeys: String, CodingKey {
            case schema
            case characterID = "character_id"
            case sourceUSDZ = "source_usdz"
            case sourceUSDZPath = "source_usdz_path"
            case skeletonHash = "skeleton_hash"
            case jointPaths = "joint_paths"
            case restLocalTransforms = "rest_local_transforms"
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
        struct ScalarKey: Codable, Equatable {
            let frame: Int?
            let t: Double
            let value: Float
        }

        struct Tracks: Codable, Equatable {
            let forwardMeters: [ScalarKey]
            let sideMeters: [ScalarKey]
            let verticalMeters: [ScalarKey]
            let yawDegrees: [ScalarKey]

            enum CodingKeys: String, CodingKey {
                case forwardMeters = "forward_meters"
                case sideMeters = "side_meters"
                case verticalMeters = "vertical_meters"
                case yawDegrees = "yaw_degrees"
            }

            static let empty = Tracks(
                forwardMeters: [],
                sideMeters: [],
                verticalMeters: [],
                yawDegrees: []
            )
        }

        let enabled: Bool?
        let locomotionType: String
        let worldSpaceMotion: String
        let space: String?
        let translationUnits: String?
        let rotationUnits: String?
        let runtimeForwardAxis: String?
        let runtimeUpAxis: String?
        let authoringUpAxis: String?
        let locomotionStartMode: String?
        let recommendedSpeedMPS: Double
        let rootRotationDegrees: Double
        let rootTranslationPolicy: String?
        let tracks: Tracks?

        enum CodingKeys: String, CodingKey {
            case enabled
            case locomotionType = "locomotion_type"
            case worldSpaceMotion = "world_space_motion"
            case space
            case translationUnits = "translation_units"
            case rotationUnits = "rotation_units"
            case runtimeForwardAxis = "runtime_forward_axis"
            case runtimeUpAxis = "runtime_up_axis"
            case authoringUpAxis = "authoring_up_axis"
            case locomotionStartMode = "locomotion_start_mode"
            case recommendedSpeedMPS = "recommended_speed_mps"
            case rootRotationDegrees = "root_rotation_degrees"
            case rootTranslationPolicy = "root_translation_policy"
            case tracks
        }

        var isEnabled: Bool {
            enabled ?? false
        }

        var resolvedTracks: Tracks {
            tracks ?? .empty
        }

        var startsAfterTransition: Bool {
            (locomotionStartMode ?? "after_transition") == "after_transition"
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

    struct AttackMetadata: Codable, Equatable {
        let attackingJoint: String
        let attackWindowStartFrame: Int
        let attackWindowEndFrame: Int
        let damageRadiusMeters: Float
        let damageAmount: Int
        let canDamageOncePerPlayback: Bool
        let postAttackState: String?

        enum CodingKeys: String, CodingKey {
            case attackingJoint = "attacking_joint"
            case attackWindowStartFrame = "attack_window_start_frame"
            case attackWindowEndFrame = "attack_window_end_frame"
            case damageRadiusMeters = "damage_radius_meters"
            case damageAmount = "damage_amount"
            case canDamageOncePerPlayback = "can_damage_once_per_playback"
            case postAttackState = "post_attack_state"
        }
    }

    let schema: String
    let clipID: String
    let displayName: String
    let rigID: String
    let rigVersion: String
    let poseMode: String
    let clipType: String?
    let affectedJoints: [String]?
    let blendInFrames: Int?
    let blendOutFrames: Int?
    let baseAnimationContinues: Bool?
    let attack: AttackMetadata?
    let source: Source
    let sourceRig: SourceRig?
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
        case clipType = "clip_type"
        case affectedJoints = "affected_joints"
        case blendInFrames = "blend_in_frames"
        case blendOutFrames = "blend_out_frames"
        case baseAnimationContinues = "base_animation_continues"
        case attack
        case source
        case sourceRig = "source_rig"
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

    var isSubAnimationOverride: Bool {
        clipType == "sub_animation_override"
    }

    var resolvedAffectedJoints: [String] {
        affectedJoints ?? []
    }

    var resolvedBlendInFrames: Int {
        blendInFrames ?? 0
    }

    var resolvedBlendOutFrames: Int {
        blendOutFrames ?? 0
    }

    var resolvedBaseAnimationContinues: Bool {
        baseAnimationContinues ?? false
    }

    var isAttackClip: Bool {
        clipType == "attack" || attack != nil
    }

    func resolvedAttackMetadata(
        fallbackJoint: String = "RightHand",
        fallbackFPS: Double = 24.0
    ) -> AttackMetadata {
        if let attack {
            return attack
        }

        let fps = timing.fps > 0
            ? timing.fps
            : fallbackFPS

        let totalFrames = max(Int(round(timing.durationSeconds * fps)), 1)
        let start = max(1, Int(Float(totalFrames) * 0.35))
        let end = max(start + 1, Int(Float(totalFrames) * 0.65))

        return AttackMetadata(
            attackingJoint: fallbackJoint,
            attackWindowStartFrame: start,
            attackWindowEndFrame: end,
            damageRadiusMeters: 0.30,
            damageAmount: 50,
            canDamageOncePerPlayback: true,
            postAttackState: "CloseRangeReady"
        )
    }
}
