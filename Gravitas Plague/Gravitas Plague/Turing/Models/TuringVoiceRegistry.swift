import Foundation

struct TuringVoiceDescriptor: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let kind: Kind
    let resourcePath: String
    let revision: String?

    enum Kind: String, Codable, Sendable {
        case library
        case cloned
    }
}

struct TuringVoiceRegistryPayload: Codable, Sendable {
    let schemaVersion: Int
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

        guard payload.schemaVersion == 1 else {
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
