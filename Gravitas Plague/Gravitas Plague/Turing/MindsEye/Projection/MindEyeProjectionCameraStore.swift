import CryptoKit
import Foundation

nonisolated struct MindEyeProjectionCameraStore: Sendable {
    let locator: MindEyeResourceLocator

    init(locator: MindEyeResourceLocator) { self.locator = locator }

    func loadProfile(resourcePath: String) throws -> MindEyeProjectionProfile {
        let value: MindEyeProjectionProfile = try decode(resourcePath)
        try value.validate()
        return value
    }

    func loadCamera(resourcePath: String) throws -> MindEyeProjectionCameraDescriptor {
        let value: MindEyeProjectionCameraDescriptor = try decode(resourcePath)
        try value.validate()
        return value
    }

    func loadTarget(resourcePath: String) throws -> MindEyeProjectionTargetDescriptor {
        let value: MindEyeProjectionTargetDescriptor = try decode(resourcePath)
        try value.validate()
        return value
    }

    func dataAndSHA256(resourcePath: String) throws -> (Data, String) {
        let url = try locator.resolve(resourcePath: resourcePath)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return (data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private func decode<T: Decodable>(_ resourcePath: String) throws -> T {
        do {
            let (data, _) = try dataAndSHA256(resourcePath: resourcePath)
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as MindEyeProjectionError {
            throw error
        } catch {
            throw MindEyeProjectionError.missingResource(resourcePath)
        }
    }
}
