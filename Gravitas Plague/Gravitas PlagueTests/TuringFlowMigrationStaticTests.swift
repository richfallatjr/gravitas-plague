import Foundation
import XCTest
@testable import Gravitas_Plague

final class TuringFlowMigrationStaticTests:
    XCTestCase {

    func testPlaybackCoordinatorHasOnePrerecordingAdmissionGuard()
        throws {
        let source = try appSource(
            "Turing/Audio/TuringStoryWalkiePlaybackCoordinator.swift"
        )

        XCTAssertTrue(
            source.contains(
                "acceptedPrerecordingID"
            )
        )
        XCTAssertTrue(
            source.contains(
                "duplicate prerecording enqueue ignored"
            )
        )
    }

    func testOldPointSpecificOrchestrationIsDeleted()
        throws {
        let oldController = try appSourceURL(
            "Turing/Story/TuringScriptPoint02And03FlowController.swift"
        )
        let oldRenderer = try appSourceURL(
            "Turing/TTS/TuringBaseCloneCharacterRenderer.swift"
        )
        let oldDescriptor = try appSourceURL(
            "Turing/Story/TuringWalkieScriptPointDescriptor.swift"
        )

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    oldController.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    oldRenderer.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    oldDescriptor.path
            )
        )
    }

    func testGenericRendererContainsNoCharacterSwitch()
        throws {
        let source = try appSource(
            "Turing/Flow/TuringCharacterQwenRenderer.swift"
        )

        XCTAssertFalse(
            source.contains(
                "case .rich"
            )
        )
        XCTAssertFalse(
            source.contains(
                "case .bigMike"
            )
        )
        XCTAssertFalse(
            source.contains(
                "richRetry"
            )
        )
    }


    func testGenericRendererUsesExactFresh2Factory()
        throws {
        let source = try appSource(
            "Turing/Flow/TuringCharacterQwenRenderer.swift"
        )

        XCTAssertTrue(
            source.contains(
                "makeFresh2Pool()"
            )
        )
        XCTAssertTrue(
            source.contains(
                "makeFresh2Scheduler"
            )
        )
        XCTAssertFalse(
            source.contains(
                "fallbackAllowed: true"
            )
        )
        XCTAssertFalse(
            source.contains(
                "sharedWeights: true"
            )
        )
    }

    func testEngineDoesNotUseDebugCanary()
        throws {
        let source = try appSource(
            "Turing/Flow/TuringFlowEngine.swift"
        )

        XCTAssertFalse(
            source.contains(
                "TuringNativeQwenHelloWorldCanary"
            )
        )
        XCTAssertFalse(
            source.contains(
                "TuringScriptPoint02And03FlowController"
            )
        )
    }

    private func appSource(
        _ relativePath: String
    ) throws -> String {
        try String(
            contentsOf:
                try appSourceURL(
                    relativePath
                ),
            encoding: .utf8
        )
    }

    private func appSourceURL(
        _ relativePath: String
    ) throws -> URL {
        let testFile = URL(
            fileURLWithPath: #filePath
        )
        let productRoot =
            testFile
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        return productRoot
            .appendingPathComponent(
                "Gravitas Plague"
            )
            .appendingPathComponent(
                relativePath
            )
    }
}
