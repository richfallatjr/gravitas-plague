import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeAssetValidatorContractTests: XCTestCase {
    func testValidatorSourceLocksPNGAndTeethContracts() throws {
        let source = try String(contentsOf: validatorURL(), encoding: .utf8)
        for required in [
            "MOUTH_POSES = (\"rest\", \"small\", \"wide\", \"round\", \"teeth\")",
            "PNG_SIGNATURE",
            "bitDepth",
            "colorType",
            "invalidFeatherMask",
            "duplicateSourceAsset",
            "orphanAsset",
            "ffprobe",
            "ffmpeg"
        ] {
            XCTAssertTrue(source.contains(required), required)
        }
    }

    #if os(macOS)
    func testProductionPackagePassesHostValidator() throws {
        let result = try runValidator([])
        XCTAssertEqual(result.status, 0, result.output)
    }

    func testManifestWithoutTeethReturnsValidationFailure() throws {
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let resources = temporaryRoot.appendingPathComponent("Turing/MindsEye")
        let package = resources.appendingPathComponent("Vignettes/test", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let catalog: [String: Any] = [
            "schemaVersion": 1,
            "entries": [[
                "characterID": "big_mike",
                "defaultVignetteID": "test",
                "vignettes": [[
                    "vignetteID": "test",
                    "manifestResourcePath": "Turing/MindsEye/Vignettes/test/manifest.json"
                ]]
            ]]
        ]
        var manifest = try productionManifestObject()
        manifest["vignetteID"] = "test"
        var layers = try XCTUnwrap(manifest["layers"] as? [String: Any])
        var mouths = try XCTUnwrap(layers["mouths"] as? [String: Any])
        mouths.removeValue(forKey: "teeth")
        layers["mouths"] = mouths
        manifest["layers"] = layers
        try JSONSerialization.data(withJSONObject: catalog)
            .write(to: resources.appendingPathComponent("catalog.json"))
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: package.appendingPathComponent("manifest.json"))

        let result = try runValidator([
            "--project-root", temporaryRoot.path,
            "--resources-root", temporaryRoot.path,
            "--no-check-duplicates"
        ])
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("missingMouthTeeth"), result.output)
    }
    #endif

    private func validatorURL() -> URL {
        mindEyeProjectRoot().appendingPathComponent(
            "Gravitas Plague/Scripts/validate_mind_eye_assets.py"
        )
    }

    #if os(macOS)
    private func productionManifestObject() throws -> [String: Any] {
        let url = mindEyeProductionVignetteRoot()
            .appendingPathComponent("manifest.json")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
    }

    private func runValidator(
        _ arguments: [String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/python3")
        process.arguments = [validatorURL().path, *arguments]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8) ?? ""
        )
    }
    #endif
}
