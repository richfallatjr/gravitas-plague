import Foundation
import XCTest

final class MindEyeProjectionSceneFactoryTests: XCTestCase {
    func testProductionAndAuthoringUseOneSceneFactory() throws {
        let root = mindEyeProjectionRepositoryRoot(file: #filePath)
        let presenter = try String(contentsOf:
            root.appendingPathComponent("Gravitas Plague/Gravitas Plague/Story/Chapter/Chapter03/LightTunnel/Chapter03LightTunnelPresenter.swift"),
            encoding: .utf8)
        let runner = try String(contentsOf:
            root.appendingPathComponent("Gravitas Plague/Gravitas Plague/Authoring/MindEyeProjection/MindEyeProjectionAuthoringJobRunner.swift"),
            encoding: .utf8)
        XCTAssertTrue(presenter.contains("Chapter03LightTunnelSceneFactory"))
        XCTAssertTrue(runner.contains("Chapter03LightTunnelSceneFactory"))
        XCTAssertFalse(runner.contains("updateAngelFloatMotion"))
    }
}
