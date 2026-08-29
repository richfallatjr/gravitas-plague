import Foundation

nonisolated struct MindEyeResourceLocator: Sendable {
    let resourceRootURL: URL

    init(resourceRootURL: URL) {
        self.resourceRootURL = resourceRootURL.standardizedFileURL
    }

    static func applicationBundle(
        _ bundle: Bundle = .main
    ) throws -> MindEyeResourceLocator {
        guard let resourceURL = bundle.resourceURL else {
            throw MindEyeFailure(
                code: .catalogMissing,
                characterID: nil,
                vignetteID: nil,
                resourcePath: nil,
                message: "Application bundle has no resource URL."
            )
        }
        return MindEyeResourceLocator(resourceRootURL: resourceURL)
    }

    func resolve(resourcePath: String) throws -> URL {
        try resolve(resourcePath: resourcePath, under: resourceRootURL)
    }

    func resolve(resourcePath: String, under rootURL: URL) throws -> URL {
        guard MindEyeSafeRelativePath.validates(resourcePath) else {
            throw MindEyeFailure(
                code: .unsafePath,
                characterID: nil,
                vignetteID: nil,
                resourcePath: resourcePath,
                message: "Unsafe Mind's Eye resource path."
            )
        }

        let root = rootURL.standardizedFileURL
        let candidate = root
            .appendingPathComponent(resourcePath)
            .standardizedFileURL
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else {
            throw MindEyeFailure(
                code: .unsafePath,
                characterID: nil,
                vignetteID: nil,
                resourcePath: resourcePath,
                message: "Mind's Eye resource escaped its root."
            )
        }
        return candidate
    }
}
