import Metal
import RealityKit
import XCTest

@testable import Gravitas_Plague

final class MindEyePremultipliedMaterialFactoryTests: XCTestCase {
    @MainActor
    func testVisionOSMaterialGraphLoadsAndBindsDynamicTexture() async throws {
        let lowLevelTexture = try LowLevelTexture(descriptor: .init(
            textureType: .type2D,
            pixelFormat: .bgra8Unorm_srgb,
            width: 1,
            height: 1,
            depth: 1,
            mipmapLevelCount: 1,
            arrayLength: 1,
            textureUsage: [.shaderRead, .shaderWrite]
        ))
        let textureResource = try await TextureResource(from: lowLevelTexture)

        switch await MindEyePremultipliedMaterialFactory.make(
            textureResource: textureResource
        ) {
        case .success(let material):
            XCTAssertEqual(material.faceCulling, .none)
            XCTAssertTrue(material.readsDepth)
            XCTAssertFalse(material.writesDepth)
        case .failure(let failure):
            XCTFail(failure.message)
        }
    }
}
