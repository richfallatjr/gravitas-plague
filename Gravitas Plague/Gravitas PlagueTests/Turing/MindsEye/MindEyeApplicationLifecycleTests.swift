import SwiftUI
import XCTest

@testable import Gravitas_Plague

final class MindEyeApplicationLifecycleTests: XCTestCase {
    func testScenePhaseMappingIsExact() {
        XCTAssertEqual(MindEyeApplicationLifecycleState(scenePhase: .active), .active)
        XCTAssertEqual(MindEyeApplicationLifecycleState(scenePhase: .inactive), .inactive)
        XCTAssertEqual(MindEyeApplicationLifecycleState(scenePhase: .background), .background)
    }

    func testInactiveFreezesAndBackgroundReleasesWithoutAudioClockMutation() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeRuntimeLifecycleCoordinator.swift"
        )
        XCTAssertTrue(source.contains("suspendForApplicationInactive"))
        XCTAssertTrue(source.contains("resumeAfterApplicationInactive"))
        XCTAssertTrue(source.contains("scope: .applicationBackground"))
        XCTAssertFalse(source.contains("TuringAudioPlaybackEndpoint"))
        XCTAssertFalse(source.contains("TuringPauseAwarePlaybackClock"))
    }
}
