import Foundation

nonisolated struct MindEyeCatalogDescriptor:
    Codable,
    Sendable,
    Equatable
{
    struct Entry: Codable, Sendable, Equatable {
        struct Vignette: Codable, Sendable, Equatable {
            let vignetteID: String
            let manifestResourcePath: String
        }

        let characterID: TuringConversationCharacterID
        let defaultVignetteID: String
        let vignettes: [Vignette]
    }

    let schemaVersion: Int
    let entries: [Entry]
}

nonisolated struct MindEyeResolvedVignette:
    Sendable,
    Equatable,
    Hashable
{
    let characterID: TuringConversationCharacterID
    let vignetteID: String
    let manifestResourcePath: String
}

nonisolated protocol MindEyeCatalogResolving: Sendable {
    func defaultVignette(
        for characterID: TuringConversationCharacterID
    ) async -> MindEyeResolvedVignette?
}

actor MindEyeCatalogStore: MindEyeCatalogResolving {
    static let defaultCatalogResourcePath = "Turing/MindsEye/catalog.json"

    private let locator: MindEyeResourceLocator
    private let worker: any MindEyeAssetWorking
    private var cached: [TuringConversationCharacterID: MindEyeResolvedVignette]?
    private var loadTask: Task<[TuringConversationCharacterID: MindEyeResolvedVignette]?, Never>?
    private var didLogFailure = false

    init(
        locator: MindEyeResourceLocator,
        worker: any MindEyeAssetWorking
    ) {
        self.locator = locator
        self.worker = worker
    }

    func defaultVignette(
        for characterID: TuringConversationCharacterID
    ) async -> MindEyeResolvedVignette? {
        if let cached {
            return cached[characterID]
        }
        if let loadTask {
            return await loadTask.value?[characterID]
        }

        let locator = locator
        let worker = worker
        let task = Task<[TuringConversationCharacterID: MindEyeResolvedVignette]?, Never> {
            do {
                let url = try locator.resolve(
                    resourcePath: Self.defaultCatalogResourcePath
                )
                let descriptor = try await worker.decodeJSON(
                    MindEyeCatalogDescriptor.self,
                    from: url
                )
                return try Self.validate(descriptor)
            } catch {
                return nil
            }
        }
        loadTask = task
        let result = await task.value
        loadTask = nil
        if let result {
            cached = result
        } else if !didLogFailure {
            didLogFailure = true
            print("[MindEye] catalog invalid or unavailable")
        }
        return result?[characterID]
    }

    private nonisolated static func validate(
        _ descriptor: MindEyeCatalogDescriptor
    ) throws -> [TuringConversationCharacterID: MindEyeResolvedVignette] {
        guard descriptor.schemaVersion == MindEyeDescriptorConstants.catalogSchemaVersion else {
            throw catalogFailure("Unsupported catalog schema version.")
        }

        var entries = [TuringConversationCharacterID: MindEyeResolvedVignette]()
        var vignetteIDs = Set<String>()
        var manifestPaths = Set<String>()
        for entry in descriptor.entries {
            guard entries[entry.characterID] == nil,
                  !entry.vignettes.isEmpty else {
                throw catalogFailure("Duplicate character or empty vignette list.")
            }
            var resolvedDefault: MindEyeResolvedVignette?
            for vignette in entry.vignettes {
                guard MindEyeVignetteManifestValidator.validID(vignette.vignetteID),
                      MindEyeSafeRelativePath.validates(
                          vignette.manifestResourcePath,
                          requiredExtension: "json"
                      ),
                      vignetteIDs.insert(vignette.vignetteID).inserted,
                      manifestPaths.insert(vignette.manifestResourcePath).inserted else {
                    throw catalogFailure("Catalog has an invalid or duplicate vignette.")
                }
                if vignette.vignetteID == entry.defaultVignetteID {
                    resolvedDefault = MindEyeResolvedVignette(
                        characterID: entry.characterID,
                        vignetteID: vignette.vignetteID,
                        manifestResourcePath: vignette.manifestResourcePath
                    )
                }
            }
            guard let resolvedDefault else {
                throw catalogFailure("Catalog default vignette is not declared.")
            }
            entries[entry.characterID] = resolvedDefault
        }
        return entries
    }

    private nonisolated static func catalogFailure(_ message: String) -> MindEyeFailure {
        MindEyeFailure(
            code: .catalogInvalid,
            characterID: nil,
            vignetteID: nil,
            resourcePath: defaultCatalogResourcePath,
            message: message
        )
    }
}
