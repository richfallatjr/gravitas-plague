import CryptoKit
import Foundation

nonisolated struct Chapter03AngelBlendShapeDescriptorStore {
    static let resourcePath =
        "Turing/Chapter03/AngelProjection/angel_jaw_open_projection.json"

    func loadProduction(
        descriptorURL: URL,
        assetURL: URL
    ) async throws -> Chapter03AngelBlendShapeDescriptor {
        try await Task.detached(priority: .userInitiated) {
            let descriptorData = try Data(contentsOf: descriptorURL, options: .mappedIfSafe)
            let descriptor = try JSONDecoder().decode(
                Chapter03AngelBlendShapeDescriptor.self,
                from: descriptorData
            )
            try descriptor.validate()
            let assetData = try Data(contentsOf: assetURL, options: .mappedIfSafe)
            let actualSHA = SHA256.hash(data: assetData).map {
                String(format: "%02x", $0)
            }.joined()
            guard actualSHA == descriptor.assetSHA256.lowercased() else {
                throw Chapter03AngelBlendShapeError.assetHashMismatch(
                    expected: descriptor.assetSHA256,
                    actual: actualSHA
                )
            }
            return descriptor
        }.value
    }
}
