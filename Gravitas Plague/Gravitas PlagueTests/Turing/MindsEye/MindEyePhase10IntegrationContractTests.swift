import Foundation
import XCTest

@testable import Gravitas_Plague

enum MindEyePhase10Source {
    static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let phase10AddedFiles = [
        "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePhysicalCharacterPresence.swift",
        "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeVisualSuspension.swift",
        "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeApplicationLifecycle.swift",
        "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeMemoryPressure.swift",
        "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeHighMemoryPreparing.swift",
        "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeTeardownReport.swift",
        "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeRuntimeSnapshot.swift",
        "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeRuntimeLifecycleCoordinator.swift"
    ]

    static func read(_ path: String) throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}

final class MindEyePhase10IntegrationContractTests: XCTestCase {
    func testEveryPhase10ProductionContractExists() {
        for path in MindEyePhase10Source.phase10AddedFiles {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: MindEyePhase10Source.projectRoot
                        .appendingPathComponent(path).path
                ),
                path
            )
        }
    }

    func testThereIsExactlyOneImmersiveScenePhaseBridge() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/PlagueImmersiveView.swift"
        )
        XCTAssertEqual(source.components(separatedBy: "@Environment(\\.scenePhase)").count - 1, 1)
        XCTAssertEqual(source.components(separatedBy: ".onChange(of: scenePhase").count - 1, 1)
        XCTAssertTrue(source.contains("MindEyeApplicationLifecycleState(scenePhase: newValue)"))
    }

    func testTeleportTeardownPrecedesStoryCancellation() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/PlagueImmersiveCoordinator.swift"
        )
        let method = try XCTUnwrap(source.range(of: "func quiesceStoryRuntime(teleportID:"))
        let tail = String(source[method.lowerBound...])
        let mindEye = try XCTUnwrap(tail.range(of: "scope: .storyTeleport"))
        let chapter = try XCTUnwrap(tail.range(of: "chapter03Coordinator?.cancel"))
        XCTAssertLessThan(mindEye.lowerBound, chapter.lowerBound)
    }

    func testAuthoredManifestsAndImageSchemaAreOutsidePhase10() throws {
        let source = try MindEyePhase10Source.phase10AddedFiles
            .map(MindEyePhase10Source.read)
            .joined(separator: "\n")
        XCTAssertFalse(source.contains("mouthframes.json"))
        XCTAssertFalse(source.contains("feather-mask.png"))
        XCTAssertFalse(source.contains("2304"))
        XCTAssertFalse(source.contains("1920"))
    }
}
