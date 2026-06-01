import Foundation

struct JockRigDefinition: Codable, Equatable {
    let schema: String
    let rigID: String
    let version: String
    let displayName: String
    let jointCount: Int
    let upAxis: String
    let sourceQuaternionOrder: String
    let jointPaths: [String]
    let landmarks: [String: String]

    enum CodingKeys: String, CodingKey {
        case schema
        case rigID = "rig_id"
        case version
        case displayName = "display_name"
        case jointCount = "joint_count"
        case upAxis = "up_axis"
        case sourceQuaternionOrder = "source_quaternion_order"
        case jointPaths = "joint_paths"
        case landmarks
    }

    var canonicalLeafNames: [String] {
        jointPaths.map { path in
            path.split(separator: "/").last.map(String.init) ?? path
        }
    }
}
