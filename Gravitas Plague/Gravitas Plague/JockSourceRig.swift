import Foundation
import RealityKit
import simd

struct JockLocalJointTransform: Codable, Equatable {
    var translation: SIMD3<Float>
    var rotation: simd_quatf
    var scale: SIMD3<Float>

    enum CodingKeys: String, CodingKey {
        case translationXYZ = "translation_xyz"
        case rotationQuatWXYZ = "rotation_quat_wxyz"
        case scaleXYZ = "scale_xyz"
    }

    init(
        translation: SIMD3<Float>,
        rotation: simd_quatf,
        scale: SIMD3<Float>
    ) {
        self.translation = translation
        self.rotation = rotation
        self.scale = scale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let t = try container.decodeIfPresent([Float].self, forKey: .translationXYZ) ?? [0, 0, 0]
        let r = try container.decodeIfPresent([Float].self, forKey: .rotationQuatWXYZ) ?? [1, 0, 0, 0]
        let s = try container.decodeIfPresent([Float].self, forKey: .scaleXYZ) ?? [1, 1, 1]

        translation = SIMD3<Float>(
            t.indices.contains(0) ? t[0] : 0,
            t.indices.contains(1) ? t[1] : 0,
            t.indices.contains(2) ? t[2] : 0
        )

        rotation = simd_normalize(
            simd_quatf(
                vector: SIMD4<Float>(
                    r.indices.contains(1) ? r[1] : 0,
                    r.indices.contains(2) ? r[2] : 0,
                    r.indices.contains(3) ? r[3] : 0,
                    r.indices.contains(0) ? r[0] : 1
                )
            )
        )

        scale = SIMD3<Float>(
            s.indices.contains(0) ? s[0] : 1,
            s.indices.contains(1) ? s[1] : 1,
            s.indices.contains(2) ? s[2] : 1
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(
            [translation.x, translation.y, translation.z],
            forKey: .translationXYZ
        )
        try container.encode(
            [rotation.real, rotation.imag.x, rotation.imag.y, rotation.imag.z],
            forKey: .rotationQuatWXYZ
        )
        try container.encode(
            [scale.x, scale.y, scale.z],
            forKey: .scaleXYZ
        )
    }

    var realityKitTransform: Transform {
        Transform(
            scale: scale,
            rotation: rotation,
            translation: translation
        )
    }

    static func == (
        lhs: JockLocalJointTransform,
        rhs: JockLocalJointTransform
    ) -> Bool {
        lhs.translation == rhs.translation &&
            lhs.rotation.vector == rhs.rotation.vector &&
            lhs.scale == rhs.scale
    }
}

struct JockSourceRigReference: Codable, Equatable {
    let schema: String?
    let sourceRigID: String
    let characterID: String?
    let skeletonHash: String
    let relativePath: String
    let dedupeStatus: String?
    let sourceAssetFile: String?

    enum CodingKeys: String, CodingKey {
        case schema
        case sourceRigID = "source_rig_id"
        case characterID = "character_id"
        case skeletonHash = "skeleton_hash"
        case relativePath = "relative_path"
        case dedupeStatus = "dedupe_status"
        case sourceAssetFile = "source_asset_file"
    }
}

struct JockSourceRigEntry: Codable, Equatable {
    let schema: String
    let sourceRigID: String
    let characterID: String
    let displayName: String?
    let skeletonHash: String
    let jointPaths: [String]
    let parentByJoint: [String: String?]
    let restLocalTransforms: [String: JockLocalJointTransform]

    enum CodingKeys: String, CodingKey {
        case schema
        case sourceRigID = "source_rig_id"
        case characterID = "character_id"
        case displayName = "display_name"
        case skeletonHash = "skeleton_hash"
        case jointPaths = "joint_paths"
        case parentByJoint = "parent_by_joint"
        case restLocalTransforms = "rest_local_transforms"
    }
}

@MainActor
final class JockSourceRigCache {
    static let shared = JockSourceRigCache()

    private var cacheByID: [String: JockSourceRigEntry] = [:]

    private init() {}

    func resolve(
        reference: JockSourceRigReference?,
        animationLibraryRoot: URL
    ) throws -> JockSourceRigEntry {
        guard let reference else {
            throw NSError(
                domain: "JockSourceRigCache",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Clip has no source_rig reference. Run Blender backfill or re-export."
                ]
            )
        }

        if let cached = cacheByID[reference.sourceRigID] {
            return cached
        }

        let url = try sourceRigURL(
            reference: reference,
            animationLibraryRoot: animationLibraryRoot
        )
        let data = try Data(contentsOf: url)
        let entry = try JSONDecoder().decode(JockSourceRigEntry.self, from: data)

        guard entry.skeletonHash == reference.skeletonHash else {
            throw NSError(
                domain: "JockSourceRigCache",
                code: 409,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Source rig hash mismatch for \(reference.sourceRigID)."
                ]
            )
        }

        cacheByID[reference.sourceRigID] = entry

        print(
            """
            [JockSourceRigCache] loaded source rig
              id: \(entry.sourceRigID)
              character: \(entry.characterID)
              joints: \(entry.jointPaths.count)
              hash: \(entry.skeletonHash.prefix(12))
            """
        )

        return entry
    }

    private func sourceRigURL(
        reference: JockSourceRigReference,
        animationLibraryRoot: URL
    ) throws -> URL {
        let directURL = animationLibraryRoot
            .appendingPathComponent(reference.relativePath)

        if FileManager.default.fileExists(atPath: directURL.path) {
            return directURL
        }

        let normalized = reference.relativePath
            .replacingOccurrences(of: "\\", with: "/")
        let parts = normalized.split(separator: "/").map(String.init)

        guard let fileNameWithExtension = parts.last else {
            throw JockLoaderError.invalidRelativePath(reference.relativePath)
        }

        let subdirectory = (["AnimationLibrary"] + Array(parts.dropLast()))
            .joined(separator: "/")
        let nsName = fileNameWithExtension as NSString
        let baseName = nsName.deletingPathExtension
        let extensionName = nsName.pathExtension

        if let bundleURL = Bundle.main.url(
            forResource: baseName,
            withExtension: extensionName,
            subdirectory: subdirectory
        ) {
            return bundleURL
        }

        throw JockLoaderError.missingResource(
            "\(subdirectory)/\(fileNameWithExtension)"
        )
    }
}
