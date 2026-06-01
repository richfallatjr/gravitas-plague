import Foundation

struct JockSkeletonMap: Codable, Equatable {
    let schema: String
    let mapID: String
    let sourceRigID: String
    let sourceRigVersion: String
    let targetRigID: String
    let targetRigVersion: String
    let canonicalToSource: [String: String]

    enum CodingKeys: String, CodingKey {
        case schema
        case mapID = "map_id"
        case sourceRigID = "source_rig_id"
        case sourceRigVersion = "source_rig_version"
        case targetRigID = "target_rig_id"
        case targetRigVersion = "target_rig_version"
        case canonicalToSource = "canonical_to_source"
    }

    func sourceJointName(for canonicalJointName: String) -> String {
        canonicalToSource[canonicalJointName] ?? canonicalJointName
    }
}
