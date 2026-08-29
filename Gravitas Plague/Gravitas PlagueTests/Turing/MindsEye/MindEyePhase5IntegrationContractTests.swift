import XCTest

@testable import Gravitas_Plague

final class MindEyePhase5IntegrationContractTests: XCTestCase {
    func testMotionMovesCompositedLayersAndNotWorldCard() throws {
        let surface = try source("MindEyeDynamicOutputSurface.swift")
        let model = try source("MindEyeMotionModel.swift")
        XCTAssertTrue(surface.contains("backgroundTransform: sample.backgroundTransform"))
        XCTAssertTrue(surface.contains("characterTransform: sample.characterTransform"))
        XCTAssertTrue(surface.contains("mouthSelection: currentMouthSelection"))
        XCTAssertTrue(surface.contains("maskMode: currentMaskMode"))
        XCTAssertFalse(model.contains("cardRoot"))
    }

    func testCoordinatorStartsAndStopsKeepAliveAtPresentationBoundary() throws {
        let coordinator = try String(
            contentsOf: mindEyeProjectRoot()
                .appendingPathComponent(
                    "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyePresentationCoordinator.swift"
                ),
            encoding: .utf8
        )
        XCTAssertTrue(coordinator.contains("prepared.visual.startKeepAlive"))
        XCTAssertTrue(coordinator.contains("active.visual.stopKeepAlive"))
        XCTAssertTrue(coordinator.contains("stage: \"startKeepAlive\""))
    }

    func testNoHeadFollowingOrBillboardWasAdded() throws {
        let root = mindEyeProjectRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye"
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        let body = try files.map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        for forbidden in [
            "BillboardComponent", "AnchorEntity(.head", "headAnchor",
            "queryDeviceAnchor", "devicePose", "currentPoseOrFallback"
        ] {
            XCTAssertFalse(body.contains(forbidden), "Forbidden placement path: \(forbidden)")
        }
    }

    private func source(_ name: String) throws -> String {
        try String(
            contentsOf: mindEyeProjectRoot()
                .appendingPathComponent("Gravitas Plague/Gravitas Plague/Turing/MindsEye")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}
