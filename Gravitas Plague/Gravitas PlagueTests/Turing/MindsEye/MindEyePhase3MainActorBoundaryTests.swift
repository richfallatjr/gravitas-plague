import XCTest

@testable import Gravitas_Plague

final class MindEyePhase3MainActorBoundaryTests: XCTestCase {
    func testPhaseThreeActorAndGpuBoundaries() throws {
        let root = mindEyeProjectRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye"
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { ["swift", "metal"].contains($0.pathExtension) }
        let source = try files
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertTrue(source.contains("@MainActor\nfinal class MindEyePresentationCoordinator"))
        XCTAssertTrue(source.contains("@MainActor\nfinal class MindEyeDynamicOutputSurface"))
        XCTAssertTrue(source.contains("dispatchPrecondition(condition: .notOnQueue(.main))"))
        XCTAssertTrue(source.contains("Thread.isMainThread == false"))
        for prohibited in [
            "CGContext", "UIImage(", "waitUntilCompleted()",
            "TextureResource.load", "SceneEvents.Update", "System.registerSystem"
        ] {
            XCTAssertFalse(source.contains(prohibited), prohibited)
        }
    }
}
