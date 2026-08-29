import XCTest

@testable import Gravitas_Plague

final class MindEyePhase3IntegrationContractTests: XCTestCase {
    func testImmersiveOwnerWiresLifecycleAndBothProviders() throws {
        let coordinator = try source("PlagueImmersiveCoordinator.swift")
        XCTAssertEqual(
            coordinator.components(separatedBy: "lazy var mindEyePresentationCoordinator").count - 1,
            1
        )
        XCTAssertTrue(coordinator.contains("bindPlacementProviders"))
        XCTAssertTrue(coordinator.contains("storyWalkieBundleController"))
        XCTAssertTrue(coordinator.contains("rollingBenchBundleController"))
        XCTAssertTrue(coordinator.contains("mindEyePresentationCoordinator.start()"))
        XCTAssertTrue(coordinator.contains("mindEyePresentationCoordinator.arm"))
        XCTAssertTrue(coordinator.contains("mindEyePresentationCoordinator.reset"))
        XCTAssertTrue(coordinator.contains("mindEyePresentationCoordinator.shutdown"))
    }

    func testProvidersOwnExactSurfacePairsAndInvalidateBeforeRemoval() throws {
        let wall = try source(
            "Turing/Props/TuringStoryWalkieBundleController.swift"
        )
        let rolling = try source(
            "Turing/Props/TuringRollingBenchBundleController.swift"
        )
        XCTAssertTrue(wall.contains("[.walkie, .dadFrame]"))
        XCTAssertTrue(rolling.contains("[.crankRadio, .hamReceiver]"))
        assertInvalidationPrecedesRemoval(in: wall)
        assertInvalidationPrecedesRemoval(in: rolling)
    }

    func testWallSurfacesShareWalkieIconPlacement() throws {
        let wall = try source(
            "Turing/Props/TuringStoryWalkieBundleController.swift"
        )
        XCTAssertTrue(wall.contains("let sharedIconTopCenter"))
        XCTAssertTrue(wall.contains("of: anchors.walkieIconAnchor"))
        XCTAssertTrue(wall.contains("fallbackCenter: sharedIconTopCenter"))
        XCTAssertFalse(wall.contains("of: anchors.dadFrameIconAnchor"))
    }

    private func assertInvalidationPrecedesRemoval(
        in source: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let invalidation = source.range(of: "mindEyePlacementProviderDidInvalidate")
        let removal = source.range(of: "root.children.removeAll")
        XCTAssertNotNil(invalidation, file: file, line: line)
        XCTAssertNotNil(removal, file: file, line: line)
        if let invalidation, let removal {
            XCTAssertLessThan(invalidation.lowerBound, removal.lowerBound, file: file, line: line)
        }
    }

    private func source(_ relativePath: String) throws -> String {
        try String(
            contentsOf: mindEyeProjectRoot()
                .appendingPathComponent("Gravitas Plague/Gravitas Plague")
                .appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
