import Foundation

struct TuringVoiceDescriptor: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let displayName: String?
    let kind: Kind
    let speakerID: String?
    let modelID: String?
    let resourcePath: String?
    let profilePath: String?
    let profileKind: String?
    let revision: String?
    let qwenVoiceArgument: String?
    let refAudioPath: String?
    let refText: String?
    let enabled: Bool?
    let allowFallback: Bool?
    let phase0RuntimeAllowed: Bool?
    let notes: String?

    enum Kind: String, Codable, Sendable {
        case library
        case cloned
        case baseClone
        case baseCloneProfile
    }

    init(
        id: String,
        displayName: String? = nil,
        kind: Kind,
        speakerID: String? = nil,
        modelID: String? = nil,
        resourcePath: String?,
        profilePath: String? = nil,
        profileKind: String? = nil,
        revision: String?,
        qwenVoiceArgument: String? = nil,
        refAudioPath: String? = nil,
        refText: String? = nil,
        enabled: Bool? = nil,
        allowFallback: Bool? = nil,
        phase0RuntimeAllowed: Bool? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.speakerID = speakerID
        self.modelID = modelID
        self.resourcePath = resourcePath
        self.profilePath = profilePath
        self.profileKind = profileKind
        self.revision = revision
        self.qwenVoiceArgument = qwenVoiceArgument
        self.refAudioPath = refAudioPath
        self.refText = refText
        self.enabled = enabled
        self.allowFallback = allowFallback
        self.phase0RuntimeAllowed = phase0RuntimeAllowed
        self.notes = notes
    }
}

struct TuringVoiceRegistryPayload: Decodable, Sendable {
    let schemaVersion: Int
    let activeVoiceID: String?
    let voices: [TuringVoiceDescriptor]
}

actor TuringVoiceRegistry {
    private let payload: TuringVoiceRegistryPayload

    init(bundle: Bundle = .main) throws {
        payload = try TuringResourceLoader.decodeResource(
            TuringVoiceRegistryPayload.self,
            resourcePath: "Turing/Config/voice-registry.json",
            bundle: bundle
        )

        guard payload.schemaVersion == 3 else {
            throw TuringRuntimeError.invalidConfig(
                "Unsupported voice-registry schemaVersion \(payload.schemaVersion)."
            )
        }
    }

    func voice(id: String) throws -> TuringVoiceDescriptor {
        guard let descriptor = payload.voices.first(where: { $0.id == id }) else {
            throw TuringRuntimeError.invalidConfig(
                "Unknown Turing voice ID: \(id)."
            )
        }
        return descriptor
    }
}
