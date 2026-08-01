import Foundation

struct Chapter01AntigenRewardDescriptor: Codable, Sendable, Equatable {
    enum ModelKind: String, Codable, Sendable {
        case resource
        case proceduralCube
    }

    static let temporaryCubeSizeMeters: Float = 0.127

    let schemaVersion: Int
    let modelKind: ModelKind
    let modelResourcePath: String?
    let proceduralCubeSizeMeters: Float?
    let rollingCartAnchorName: String
    let hudDurationSeconds: Double
    let hudText: String
    let rewardSoundResourcePath: String?

    static func load() throws -> Self {
        let value = try TuringResourceLoader.decodeResource(
            Self.self,
            resourcePath: "Turing/Story/Chapter01/chapter01.antigenReward.001.json"
        )
        guard value.schemaVersion == 1,
              !value.rollingCartAnchorName.isEmpty,
              value.hudDurationSeconds > 0,
              value.hudText == "You received an antigen pack" else {
            throw Chapter01RobotError.invalidDefinition("invalid antigen reward descriptor")
        }

        switch value.modelKind {
        case .resource:
            guard let path = value.modelResourcePath, !path.isEmpty else {
                throw Chapter01RobotError.invalidDefinition("reward model resource path is missing")
            }
            _ = try TuringResourceLoader.resourceURL(resourcePath: path)
        case .proceduralCube:
            guard let size = value.proceduralCubeSizeMeters,
                  abs(size - temporaryCubeSizeMeters) < 0.0001 else {
                throw Chapter01RobotError.invalidDefinition("temporary antigen cube must be exactly five inches")
            }
        }

        if let sound = value.rewardSoundResourcePath {
            _ = try TuringResourceLoader.resourceURL(resourcePath: sound)
        }
        return value
    }
}
