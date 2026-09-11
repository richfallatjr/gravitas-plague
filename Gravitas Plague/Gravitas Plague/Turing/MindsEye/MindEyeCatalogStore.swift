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

private nonisolated struct MindEyeResolvedCatalog: Sendable {
    let defaults: [TuringConversationCharacterID: MindEyeResolvedVignette]
    let vignettes: [
        TuringConversationCharacterID: [String: MindEyeResolvedVignette]
    ]
}

nonisolated protocol MindEyeCatalogResolving: Sendable {
    func vignette(
        for characterID: TuringConversationCharacterID,
        preferredVignetteID: String?
    ) async -> MindEyeResolvedVignette?
}

nonisolated extension MindEyeCatalogResolving {
    func defaultVignette(
        for characterID: TuringConversationCharacterID
    ) async -> MindEyeResolvedVignette? {
        await vignette(for: characterID, preferredVignetteID: nil)
    }
}

actor MindEyeCatalogStore: MindEyeCatalogResolving {
    static let defaultCatalogResourcePath = "Turing/MindsEye/catalog.json"

    private let locator: MindEyeResourceLocator
    private let worker: any MindEyeAssetWorking
    private var cached: MindEyeResolvedCatalog?
    private var loadTask: Task<MindEyeResolvedCatalog?, Never>?
    private var didLogFailure = false

    init(
        locator: MindEyeResourceLocator,
        worker: any MindEyeAssetWorking
    ) {
        self.locator = locator
        self.worker = worker
    }

    func vignette(
        for characterID: TuringConversationCharacterID,
        preferredVignetteID: String?
    ) async -> MindEyeResolvedVignette? {
        guard let catalog = await resolvedCatalog() else { return nil }
        if let preferredVignetteID {
            return catalog.vignettes[characterID]?[preferredVignetteID]
        }
        return catalog.defaults[characterID]
    }

    private func resolvedCatalog() async -> MindEyeResolvedCatalog? {
        if let cached {
            return cached
        }
        if let loadTask {
            return await loadTask.value
        }

        let locator = locator
        let worker = worker
        let task = Task<MindEyeResolvedCatalog?, Never> {
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
        return result
    }

    private nonisolated static func validate(
        _ descriptor: MindEyeCatalogDescriptor
    ) throws -> MindEyeResolvedCatalog {
        guard descriptor.schemaVersion == MindEyeDescriptorConstants.catalogSchemaVersion else {
            throw catalogFailure("Unsupported catalog schema version.")
        }

        var defaults = [TuringConversationCharacterID: MindEyeResolvedVignette]()
        var entries = [
            TuringConversationCharacterID: [String: MindEyeResolvedVignette]
        ]()
        var vignetteIDs = Set<String>()
        var manifestPaths = Set<String>()
        for entry in descriptor.entries {
            guard entries[entry.characterID] == nil,
                  !entry.vignettes.isEmpty else {
                throw catalogFailure("Duplicate character or empty vignette list.")
            }
            var resolvedDefault: MindEyeResolvedVignette?
            var resolvedVignettes = [String: MindEyeResolvedVignette]()
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
                let resolved = MindEyeResolvedVignette(
                    characterID: entry.characterID,
                    vignetteID: vignette.vignetteID,
                    manifestResourcePath: vignette.manifestResourcePath
                )
                resolvedVignettes[vignette.vignetteID] = resolved
                if vignette.vignetteID == entry.defaultVignetteID {
                    resolvedDefault = resolved
                }
            }
            guard let resolvedDefault else {
                throw catalogFailure("Catalog default vignette is not declared.")
            }
            defaults[entry.characterID] = resolvedDefault
            entries[entry.characterID] = resolvedVignettes
        }
        return MindEyeResolvedCatalog(defaults: defaults, vignettes: entries)
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
