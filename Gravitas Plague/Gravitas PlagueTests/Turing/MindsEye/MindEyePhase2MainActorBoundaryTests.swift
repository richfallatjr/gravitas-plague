import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyePhase2MainActorBoundaryTests: XCTestCase {
    func testHeavyRuntimeTypesAreNotMainActorIsolated() throws {
        let declarations = [
            "MindEyeSerialAssetWorker",
            "MindEyeAssetPackageLoader",
            "MindEyeAssetMemoryManager",
            "MindEyeCatalogStore",
            "MindEyeSerialTextureLoader"
        ]
        let source = try mindEyeRuntimeSource()
        for declaration in declarations {
            XCTAssertFalse(
                source.contains("@MainActor\nactor \(declaration)") ||
                    source.contains("@MainActor\nfinal class \(declaration)") ||
                    source.contains("@MainActor.*\(declaration)"),
                "Heavy runtime type is MainActor isolated: \(declaration)"
            )
        }
    }

    func testOnlyDedicatedWorkerPerformsBlockingReadsAndImageInspection() throws {
        let files = try mindEyeRuntimeFiles()
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("UIImage"), file.lastPathComponent)
            XCTAssertFalse(source.contains("TextureResource.load"), file.lastPathComponent)
            XCTAssertFalse(source.contains("TextureResource(contentsOf"), file.lastPathComponent)
            if source.contains("Data(contentsOf:") {
                XCTAssertEqual(
                    file.lastPathComponent,
                    "MindEyeAssetInspectionWorker.swift"
                )
            }
        }
    }

    func testPackageLoadingIsSequentialAndProvesOffMainExecution() throws {
        let source = try mindEyeRuntimeSource()
        XCTAssertFalse(source.contains("withTaskGroup"))
        XCTAssertFalse(source.contains("withThrowingTaskGroup"))
        XCTAssertFalse(source.contains("async let"))
        XCTAssertFalse(source.contains("newTextures("))
        XCTAssertTrue(source.contains("dispatchPrecondition(condition: .notOnQueue(.main))"))
        XCTAssertTrue(source.contains("Thread.isMainThread == false"))
        XCTAssertTrue(source.contains("generateMipmaps: NSNumber(value: false)"))
    }

    func testPhaseTwoContainsNoPresentationOrCompositorIntegration() throws {
        let phaseTwoFiles: Set<String> = [
            "MindEyeAssetInspectionWorker.swift",
            "MindEyeAssetMemoryManager.swift",
            "MindEyeAssetPackage.swift",
            "MindEyeAssetPackageLoader.swift",
            "MindEyeCatalogStore.swift",
            "MindEyeDescriptor.swift",
            "MindEyeFailure.swift",
            "MindEyeResourceLocator.swift",
            "MindEyeTextureLoader.swift",
            "MindEyeVignetteManifest.swift"
        ]
        let source = try mindEyeRuntimeFiles()
            .filter { phaseTwoFiles.contains($0.lastPathComponent) }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        for prohibited in [
            "TuringSpokenPresentationHub",
            "ModelEntity",
            "MeshResource",
            "UnlitMaterial",
            "RealityKit",
            "LowLevelTexture",
            "DrawableQueue"
        ] {
            XCTAssertFalse(source.contains(prohibited), prohibited)
        }
    }

    private func mindEyeRuntimeSource() throws -> String {
        try mindEyeRuntimeFiles()
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func mindEyeRuntimeFiles() throws -> [URL] {
        let root = mindEyeProjectRoot()
            .appendingPathComponent("Gravitas Plague/Gravitas Plague/Turing/MindsEye")
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
