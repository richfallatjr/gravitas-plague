import Foundation

enum JockLoaderError: LocalizedError {
    case missingResource(String)
    case decodeFailed(String, Error)
    case invalidRelativePath(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let path):
            return "Missing JockAsset resource: \(path)"
        case .decodeFailed(let path, let error):
            return "Failed to decode \(path): \(error.localizedDescription)"
        case .invalidRelativePath(let path):
            return "Invalid animation library relative path: \(path)"
        }
    }
}

enum JockAnimationLibraryLoader {
    static func animationLibraryRootURL() throws -> URL {
        if let url = Bundle.main.url(
            forResource: "AnimationLibrary",
            withExtension: nil
        ) {
            return url
        }

        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL
                .appendingPathComponent("AnimationLibrary", isDirectory: true)

            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        throw JockLoaderError.missingResource("AnimationLibrary")
    }

    static func loadRigDefinition() throws -> JockRigDefinition {
        try loadJSON(
            fileName: "GravitasMeshyBiped24_v001.rig",
            extensionName: "json",
            subdirectory: "AnimationLibrary/Rigs",
            as: JockRigDefinition.self
        )
    }

    static func loadSkeletonMap() throws -> JockSkeletonMap {
        try loadJSON(
            fileName: "MeshyBiped24_identity.map",
            extensionName: "json",
            subdirectory: "AnimationLibrary/SkeletonMaps",
            as: JockSkeletonMap.self
        )
    }

    static func loadManifest() throws -> JockAnimationManifest {
        try loadJSON(
            fileName: "animation_library_manifest",
            extensionName: "json",
            subdirectory: "AnimationLibrary/Manifests",
            as: JockAnimationManifest.self
        )
    }

    static func loadRuntimeClipOverrides() throws -> JockRuntimeClipOverrides {
        try loadJSON(
            fileName: "jock_runtime_clip_overrides",
            extensionName: "json",
            subdirectory: "AnimationLibrary/Manifests",
            as: JockRuntimeClipOverrides.self
        )
    }

    static func loadRuntimeClipOverridesIfAvailable() -> JockRuntimeClipOverrides {
        do {
            return try loadRuntimeClipOverrides()
        } catch {
            print("[Gravitas JockAsset Overrides] Runtime clip overrides unavailable: \(error)")

            return JockRuntimeClipOverrides(
                schema: "com.gravitas.jock_runtime_clip_overrides.v0",
                clips: [:]
            )
        }
    }

    static func loadClip(summary: JockAnimationManifest.ClipSummary) throws -> JockAnimClip {
        try loadClip(relativePath: summary.relativePath)
    }

    static func loadClip(relativePath: String) throws -> JockAnimClip {
        let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
        let pathParts = normalized.split(separator: "/").map(String.init)

        guard let fileNameWithExtension = pathParts.last else {
            throw JockLoaderError.invalidRelativePath(relativePath)
        }

        let subdirectoryParts = Array(pathParts.dropLast())
        let subdirectory = (["AnimationLibrary"] + subdirectoryParts)
            .joined(separator: "/")

        let nsName = fileNameWithExtension as NSString
        let baseName = nsName.deletingPathExtension
        let extensionName = nsName.pathExtension

        guard !baseName.isEmpty, !extensionName.isEmpty else {
            throw JockLoaderError.invalidRelativePath(relativePath)
        }

        return try loadJSON(
            fileName: baseName,
            extensionName: extensionName,
            subdirectory: subdirectory,
            as: JockAnimClip.self
        )
    }

    static func loadAllRuntimeApprovedClips() throws -> [JockAnimClip] {
        let manifest = try loadManifest()

        return try manifest.clips
            .filter { $0.approvedForRuntime }
            .map { try loadClip(summary: $0) }
    }

    private static func loadJSON<T: Decodable>(
        fileName: String,
        extensionName: String,
        subdirectory: String,
        as type: T.Type
    ) throws -> T {
        guard let url = Bundle.main.url(
            forResource: fileName,
            withExtension: extensionName,
            subdirectory: subdirectory
        ) ?? Bundle.main.url(
            forResource: fileName,
            withExtension: extensionName
        ) else {
            throw JockLoaderError.missingResource("\(subdirectory)/\(fileName).\(extensionName)")
        }

        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw JockLoaderError.decodeFailed(url.lastPathComponent, error)
        }
    }
}
