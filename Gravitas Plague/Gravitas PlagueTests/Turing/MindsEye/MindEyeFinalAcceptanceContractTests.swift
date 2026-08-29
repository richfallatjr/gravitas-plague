import Foundation
import XCTest

@testable import Gravitas_Plague

enum MindEyePhase11TestSource {
    static let projectRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static func read(_ path: String) throws -> String {
        try String(
            contentsOf: projectRoot.appendingPathComponent(path),
            encoding: .utf8
        )
    }
}

final class MindEyeFinalAcceptanceContractTests: XCTestCase {
    func testPhase11ProductionAndHostContractsExist() {
        let mindsEye = "Gravitas Plague/Gravitas Plague/Turing/MindsEye/"
        let required = [
            "MindEyeReleaseBudget.swift",
            "MindEyeReleaseScenario.swift",
            "MindEyeReleaseQualificationEvent.swift",
            "MindEyeReleaseQualificationRecorder.swift",
            "MindEyeReleaseQualificationCoordinator.swift",
            "MindEyeReleaseResourceSnapshot.swift",
            "MindEyeReleaseQualificationHooks.swift",
            "MindEyeReleaseQualificationReport.swift",
            "MindEyeLayerTexture.swift",
            "MindEyeAlphaBounds.swift",
            "MindEyePackedLayerTexture.swift",
            "MindEyePackedLayerBuilder.swift",
            "MindEyePackedLayerPolicy.swift"
        ].map { mindsEye + $0 } + [
            "Gravitas Plague/Scripts/qualify_mind_eye_release.py",
            "Gravitas Plague/Scripts/mind_eye_qualification/config/release_budget.json",
            "Gravitas Plague/Scripts/mind_eye_qualification/config/release_matrix.json"
        ]
        for path in required {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: MindEyePhase11TestSource.projectRoot
                        .appendingPathComponent(path).path
                ),
                path
            )
        }
    }

    func testPackedProductionPolicyRemainsDisabledPendingDeviceEvidence() {
        XCTAssertEqual(MindEyePackedLayerPolicy.production, .disabled)
    }
}
