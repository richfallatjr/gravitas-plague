import Foundation

struct TuringModelDescriptor: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let displayName: String
    let sourceRepository: String
    let sourceRevision: String
    let resourcePath: String
    let tokenizerResourcePath: String
    let modelRevision: String
    let tokenizerRevision: String
    let quantization: String
    let license: String
    let checksumManifest: String
}

struct TuringModelRegistryPayload: Codable, Sendable {
    let schemaVersion: Int
    let models: [TuringModelDescriptor]
}

actor TuringModelRegistry {
    private let payload: TuringModelRegistryPayload

    init(bundle: Bundle = .main) throws {
        payload = try TuringResourceLoader.decodeResource(
            TuringModelRegistryPayload.self,
            resourcePath: "Turing/Config/model-registry.json",
            bundle: bundle
        )

        guard payload.schemaVersion == 1 else {
            throw TuringRuntimeError.invalidConfig(
                "Unsupported model-registry schemaVersion \(payload.schemaVersion)."
            )
        }
    }

    func model(id: String) throws -> TuringModelDescriptor {
        guard let descriptor = payload.models.first(where: { $0.id == id }) else {
            throw TuringRuntimeError.invalidConfig(
                "Unknown Turing model ID: \(id)."
            )
        }
        return descriptor
    }
}
