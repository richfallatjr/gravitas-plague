import Foundation

struct CharacterAttributes: Codable, Identifiable {
    var id: String { characterID }

    let schema: String
    let characterID: String
    let displayName: String
    let archetype: PlagueCharacterArchetype
    let asset: CharacterAssetAttributes
    let runtime: CharacterRuntimeAttributes
    let horde: CharacterHordeAttributes
    let animations: CharacterAnimationAttributes
    let audio: CharacterAudioAttributes
    let extensions: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case schema
        case characterID = "character_id"
        case displayName = "display_name"
        case archetype
        case asset
        case runtime
        case horde
        case animations
        case audio
        case extensions
    }
}

struct CharacterAssetAttributes: Codable {
    let usdz: String
    let bundleSubdirectory: String?

    enum CodingKeys: String, CodingKey {
        case usdz
        case bundleSubdirectory = "bundle_subdirectory"
    }
}

struct CharacterRuntimeAttributes: Codable {
    let poseApplicationPolicy: JockPoseApplicationPolicy
    let forwardAxis: String
    let upAxis: String

    enum CodingKeys: String, CodingKey {
        case poseApplicationPolicy = "pose_application_policy"
        case forwardAxis = "forward_axis"
        case upAxis = "up_axis"
    }
}

struct CharacterHordeAttributes: Codable {
    let enabled: Bool
    let hitsToKill: IntRange
    let spawnWeight: Float

    enum CodingKeys: String, CodingKey {
        case enabled
        case hitsToKill = "hits_to_kill"
        case spawnWeight = "spawn_weight"
    }
}

struct IntRange: Codable {
    let min: Int
    let max: Int

    func random() -> Int {
        Int.random(in: min...max)
    }
}

struct CharacterAnimationAttributes: Codable {
    let idle: [AnimationClipRef]
    let walk: [AnimationClipRef]
    let turn: CharacterTurnAnimationAttributes
    let attack: [AnimationClipRef]
    let damage: [AnimationClipRef]
    let death: [AnimationClipRef]
    let extensions: [String: JSONValue]?
}

struct CharacterTurnAnimationAttributes: Codable {
    let left90: [AnimationClipRef]
    let right90: [AnimationClipRef]

    enum CodingKeys: String, CodingKey {
        case left90 = "left_90"
        case right90 = "right_90"
    }
}

struct AnimationClipRef: Codable {
    let clipID: String
    let weight: Float
    let loop: Bool
    let transitionFrames: Int?

    enum CodingKeys: String, CodingKey {
        case clipID = "clip_id"
        case weight
        case loop
        case transitionFrames = "transition_frames"
    }
}

struct CharacterAudioAttributes: Codable {
    let presenceLoop: SoundRef?
    let damageHits: [SoundRef]
    let faceHits: [SoundRef]
    let death: [SoundRef]
    let attack: [SoundRef]
    let extensions: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case presenceLoop = "presence_loop"
        case damageHits = "damage_hits"
        case faceHits = "face_hits"
        case death
        case attack
        case extensions
    }
}

struct SoundRef: Codable, Hashable {
    let file: String
    let weight: Float?
    let volumeDB: Float?
    let spatial: Bool?
    let loop: Bool?

    enum CodingKeys: String, CodingKey {
        case file
        case weight
        case volumeDB = "volume_db"
        case spatial
        case loop
    }

    var basename: String {
        let url = URL(fileURLWithPath: file)
        return url.deletingPathExtension().lastPathComponent
    }

    var ext: String {
        URL(fileURLWithPath: file).pathExtension
    }
}

extension Array where Element == AnimationClipRef {
    func weightedPickStrict(
        role: String,
        characterID: String
    ) throws -> AnimationClipRef {
        guard !isEmpty else {
            throw CharacterAttributeError.missingAnimationRole(
                characterID: characterID,
                role: role
            )
        }

        let total = reduce(Float(0)) {
            $0 + Swift.max(0, $1.weight)
        }

        guard total > 0 else {
            throw CharacterAttributeError.invalidWeights(
                characterID: characterID,
                role: role
            )
        }

        var pick = Float.random(in: 0..<total)

        for item in self {
            pick -= Swift.max(0, item.weight)
            if pick <= 0 {
                return item
            }
        }

        return self[count - 1]
    }
}

extension Array where Element == SoundRef {
    func weightedPickStrict(
        role: String,
        characterID: String
    ) throws -> SoundRef {
        guard !isEmpty else {
            throw CharacterAttributeError.missingAudioRole(
                characterID: characterID,
                role: role
            )
        }

        let total = reduce(Float(0)) {
            $0 + Swift.max(0, $1.weight ?? 1)
        }

        guard total > 0 else {
            throw CharacterAttributeError.invalidWeights(
                characterID: characterID,
                role: role
            )
        }

        var pick = Float.random(in: 0..<total)

        for item in self {
            pick -= Swift.max(0, item.weight ?? 1)
            if pick <= 0 {
                return item
            }
        }

        return self[count - 1]
    }
}

enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSONValue"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

enum CharacterAttributeError: Error, LocalizedError {
    case missingManifest
    case missingSidecar(characterID: String)
    case badSchema(characterID: String, schema: String)
    case duplicateCharacterID(String)
    case archetypeMismatch(characterID: String, archetype: String)
    case disabledCharacter(characterID: String)
    case missingUSDZ(characterID: String, file: String)
    case missingAnimationRole(characterID: String, role: String)
    case missingAnimationClip(characterID: String, role: String, clipID: String)
    case missingAudioRole(characterID: String, role: String)
    case missingAudioFile(characterID: String, role: String, file: String)
    case invalidWeights(characterID: String, role: String)
    case invalidHitsToKill(characterID: String, min: Int, max: Int)

    var errorDescription: String? {
        switch self {
        case .missingManifest:
            return "Character manifest missing."
        case .missingSidecar(let characterID):
            return "Missing character sidecar for \(characterID)."
        case .badSchema(let characterID, let schema):
            return "Bad schema for \(characterID): \(schema)."
        case .duplicateCharacterID(let characterID):
            return "Duplicate character ID: \(characterID)."
        case .archetypeMismatch(let characterID, let archetype):
            return "\(characterID) has mismatched archetype \(archetype)."
        case .disabledCharacter(let characterID):
            return "\(characterID) is disabled for Horde."
        case .missingUSDZ(let characterID, let file):
            return "\(characterID) missing USDZ asset: \(file)."
        case .missingAnimationRole(let characterID, let role):
            return "\(characterID) missing animation role \(role)."
        case .missingAnimationClip(let characterID, let role, let clipID):
            return "\(characterID) missing animation clip \(clipID) for role \(role)."
        case .missingAudioRole(let characterID, let role):
            return "\(characterID) missing audio role \(role)."
        case .missingAudioFile(let characterID, let role, let file):
            return "\(characterID) missing audio file \(file) for role \(role)."
        case .invalidWeights(let characterID, let role):
            return "\(characterID) invalid weights for \(role)."
        case .invalidHitsToKill(let characterID, let min, let max):
            return "\(characterID) invalid hit range \(min)-\(max)."
        }
    }
}
