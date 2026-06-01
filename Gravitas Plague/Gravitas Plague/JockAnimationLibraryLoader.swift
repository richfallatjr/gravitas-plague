import Foundation

enum JockLoaderError: LocalizedError {
    case missingResource(String)
    case decodeFailed(String, Error)

    var errorDescription: String? {
        switch self {
        case .missingResource(let path):
            return "Missing Jock resource: \(path)"
        case .decodeFailed(let path, let error):
            return "Failed to decode \(path): \(error.localizedDescription)"
        }
    }
}

enum JockAnimationLibraryLoader {
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

    static func loadDummyClip() throws -> JockAnimClip {
        try loadJSON(
            fileName: "dummy_calisthenics_v001.jockanim",
            extensionName: "json",
            subdirectory: "AnimationLibrary/Clips/Dummy",
            as: JockAnimClip.self
        )
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
