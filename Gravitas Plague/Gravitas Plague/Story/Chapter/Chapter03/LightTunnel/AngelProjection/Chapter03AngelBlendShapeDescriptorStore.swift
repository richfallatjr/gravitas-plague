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

    func loadOffsetPayload(
        descriptor: Chapter03AngelBlendShapeDescriptor,
        payloadURL: URL
    ) async throws -> Chapter03AngelBlendShapeOffsetPayload {
        try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: payloadURL, options: .mappedIfSafe)
            let actualSHA = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            guard actualSHA == descriptor.offsetPayloadSHA256.lowercased() else {
                throw Chapter03AngelBlendShapeError.offsetPayloadHashMismatch(
                    expected: descriptor.offsetPayloadSHA256,
                    actual: actualSHA
                )
            }
            return try Chapter03AngelBlendShapeOffsetPayload(
                data: data,
                expectedMeshCount: descriptor.offsetPayloadMeshCount,
                expectedRecordCount: descriptor.offsetPayloadRecordCount
            )
        }.value
    }
}
