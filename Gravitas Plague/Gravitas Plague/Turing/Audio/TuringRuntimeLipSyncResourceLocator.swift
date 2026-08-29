import Foundation

nonisolated struct TuringRuntimeLipSyncResourceManifest: Codable, Sendable, Equatable {
    let schemaVersion: Int
    let engineID: String
    let engineVersion: String
    let engineCommit: String
    let alignmentSampleRate: Int
    let alignmentFrameRate: Int
    let acousticModelResourcePath: String
    let dictionaryResourcePath: String
    let allPhoneLanguageModelResourcePath: String
    let pronunciationOverridesResourcePath: String
    let resourceTreeSHA256: String
    let selectedResourceBytes: Int
}

nonisolated struct TuringRuntimeLipSyncPronunciationOverrides: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let word: String
        let phones: [String]
    }

    let schemaVersion: Int
    let phoneSet: String
    let entries: [Entry]
}

nonisolated struct TuringRuntimeLipSyncResolvedResources: Sendable {
    let manifest: TuringRuntimeLipSyncResourceManifest
    let acousticModelURL: URL
    let dictionaryURL: URL
    let allPhoneLanguageModelURL: URL
    let pronunciationOverrides: TuringRuntimeLipSyncPronunciationOverrides
}

nonisolated struct TuringRuntimeLipSyncResourceLocator: @unchecked Sendable {
    static let manifestPath = "Turing/RuntimeLipSync/manifest.json"
    static let requiredResourceBytes = 10_742_421
    static let requiredCommit = "511126b492dcb267cf30d49d631946d7b61a9530"

    private let bundle: Bundle
    private let resourceRootURL: URL?

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        resourceRootURL = nil
    }

    /// Direct source-resource root used by host/unit qualification. Production
    /// composition always uses the bundle initializer above.
    init(resourceRootURL: URL) {
        bundle = .main
        self.resourceRootURL = resourceRootURL
    }

    func resolveAndValidate() throws -> TuringRuntimeLipSyncResolvedResources {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let manifest: TuringRuntimeLipSyncResourceManifest
        if let resourceRootURL {
            manifest = try Self.decode(
                TuringRuntimeLipSyncResourceManifest.self,
                at: resourceRootURL.appendingPathComponent("manifest.json")
            )
        } else {
            manifest = try TuringResourceLoader.decodeResource(
                TuringRuntimeLipSyncResourceManifest.self,
                resourcePath: Self.manifestPath,
                bundle: bundle
            )
        }
        guard manifest.schemaVersion == 1,
              manifest.engineID == "pocketsphinx-forced-align",
              manifest.engineVersion == "5.1.1",
              manifest.engineCommit == Self.requiredCommit,
              manifest.alignmentSampleRate == 16_000,
              manifest.alignmentFrameRate == 100,
              manifest.selectedResourceBytes == Self.requiredResourceBytes else {
            throw TuringRuntimeLipSyncFailure.resourceInvalid(
                "PocketSphinx runtime manifest does not match the source lock."
            )
        }

        let acoustic = try resolveResource(
            manifest.acousticModelResourcePath
        )
        let dictionary = try resolveResource(
            manifest.dictionaryResourcePath
        )
        let allPhone = try resolveResource(
            manifest.allPhoneLanguageModelResourcePath
        )
        let overrides: TuringRuntimeLipSyncPronunciationOverrides
        if resourceRootURL != nil {
            overrides = try Self.decode(
                TuringRuntimeLipSyncPronunciationOverrides.self,
                at: try resolveResource(
                    manifest.pronunciationOverridesResourcePath
                )
            )
        } else {
            overrides = try TuringResourceLoader.decodeResource(
                TuringRuntimeLipSyncPronunciationOverrides.self,
                resourcePath: manifest.pronunciationOverridesResourcePath,
                bundle: bundle
            )
        }
        guard overrides.schemaVersion == 1,
              overrides.phoneSet == "PocketSphinx-en-us",
              FileManager.default.fileExists(atPath: acoustic.path),
              FileManager.default.fileExists(atPath: dictionary.path),
              FileManager.default.fileExists(atPath: allPhone.path) else {
            throw TuringRuntimeLipSyncFailure.resourceMissing(
                "One or more PocketSphinx runtime resources are missing."
            )
        }

        let enUSRoot = acoustic.deletingLastPathComponent()
        let resourceHash = try TuringRuntimeLipSyncSHA256.tree(enUSRoot)
        guard resourceHash == manifest.resourceTreeSHA256 else {
            throw TuringRuntimeLipSyncFailure.resourceInvalid(
                "PocketSphinx resource tree hash mismatch."
            )
        }
        let bytes = try Self.regularFileBytes(in: enUSRoot)
        guard bytes == manifest.selectedResourceBytes,
              !FileManager.default.fileExists(
                atPath: enUSRoot.appendingPathComponent("en-us.lm.bin").path
              ) else {
            throw TuringRuntimeLipSyncFailure.resourceInvalid(
                "PocketSphinx resource payload is incomplete or contains the large word LM."
            )
        }
        return .init(
            manifest: manifest,
            acousticModelURL: acoustic,
            dictionaryURL: dictionary,
            allPhoneLanguageModelURL: allPhone,
            pronunciationOverrides: overrides
        )
    }

    private func resolveResource(_ resourcePath: String) throws -> URL {
        guard let resourceRootURL else {
            return try TuringResourceLoader.resourceURL(
                resourcePath: resourcePath,
                bundle: bundle
            )
        }
        let prefix = "Turing/RuntimeLipSync/"
        let relativePath = resourcePath.hasPrefix(prefix)
            ? String(resourcePath.dropFirst(prefix.count))
            : resourcePath
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/") else {
            throw TuringRuntimeLipSyncFailure.resourceInvalid(
                "Runtime lip-sync resource path escapes its source root."
            )
        }
        return resourceRootURL.appendingPathComponent(relativePath)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        at url: URL
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(contentsOf: url))
        } catch {
            throw TuringRuntimeLipSyncFailure.resourceInvalid(
                "Cannot decode runtime lip-sync resource \(url.lastPathComponent)."
            )
        }
    }

    private static func regularFileBytes(in root: URL) throws -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw TuringRuntimeLipSyncFailure.resourceInvalid(
                "Cannot enumerate PocketSphinx resources."
            )
        }
        var total = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            if values.isRegularFile == true {
                let result = total.addingReportingOverflow(values.fileSize ?? 0)
                guard !result.overflow else {
                    throw TuringRuntimeLipSyncFailure.resourceInvalid(
                        "PocketSphinx resource byte count overflowed."
                    )
                }
                total = result.partialValue
            }
        }
        return total
    }
}
