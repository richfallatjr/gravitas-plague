import Foundation

struct TuringModelDescriptor: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let huggingFaceRepo: String
    let revision: String
    let resourcePath: String
    let modelType: String
    let family: String
    let parameterClass: String
    let quantization: String
    let swiftSupportStatus: String
    let phase0RuntimeAllowed: Bool
    let requiresGPU: Bool
    let allowCPUFallback: Bool
    let voiceArgumentPolicy: String
    let refAudioPolicy: String
    let refTextPolicy: String
    let customVoiceAllowed: Bool
    let voiceDesignAllowed: Bool
    let cloneProfilesAllowed: Bool
    let requiresMetalCanaryPass: Bool
    let metalCanaryStatus: String
    let notes: String?

    var sourceRepository: String { huggingFaceRepo }
    var sourceRevision: String { revision }
    var modelRevision: String { revision }
    var tokenizerRevision: String { "\(revision):speech_tokenizer" }
    var checkpointKind: String {
        family.hasSuffix("-base") ? "base" : family
    }
}

struct TuringModelRegistryPayload: Decodable, Sendable {
    let schemaVersion: Int
    let activeModelID: String?
    let qwenModels: [TuringModelDescriptor]
    let blockedModels: [BlockedModel]

    struct BlockedModel: Codable, Sendable, Hashable {
        let id: String
        let reason: String
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case activeModelID
        case qwenModels
        case blockedModels
        case models
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        activeModelID = try container.decodeIfPresent(String.self, forKey: .activeModelID)
        qwenModels = try container.decodeIfPresent(
            [TuringModelDescriptor].self,
            forKey: .qwenModels
        ) ?? container.decodeIfPresent(
            [TuringModelDescriptor].self,
            forKey: .models
        ) ?? []
        blockedModels = try container.decodeIfPresent(
            [BlockedModel].self,
            forKey: .blockedModels
        ) ?? []
    }
}

actor TuringModelRegistry {
    private let payload: TuringModelRegistryPayload

    init(bundle: Bundle = .main) throws {
        payload = try TuringResourceLoader.decodeResource(
            TuringModelRegistryPayload.self,
            resourcePath: "Turing/Config/model-registry.json",
            bundle: bundle
        )

        guard payload.schemaVersion == 3 else {
            throw TuringRuntimeError.invalidConfig(
                "Unsupported model-registry schemaVersion \(payload.schemaVersion)."
            )
        }
    }

    func model(id: String) throws -> TuringModelDescriptor {
        guard let descriptor = payload.qwenModels.first(where: { $0.id == id }) else {
            throw TuringRuntimeError.invalidConfig(
                "Unknown Turing model ID: \(id)."
            )
        }
        return descriptor
    }
}
