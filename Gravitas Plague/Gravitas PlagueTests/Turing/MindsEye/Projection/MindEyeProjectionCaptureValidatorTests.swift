import Foundation
import XCTest
@testable import Gravitas_Plague

final class MindEyeProjectionCaptureValidatorTests: XCTestCase {
    func testValidatorRejectsWrongCaptureIdentityBeforePublication() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try MindEyeProjectionCaptureValidator.validate(
            directory: directory,
            manifest: mindEyeProjectionManifestFixture(captureID: "wrong")
        ))
    }
}
