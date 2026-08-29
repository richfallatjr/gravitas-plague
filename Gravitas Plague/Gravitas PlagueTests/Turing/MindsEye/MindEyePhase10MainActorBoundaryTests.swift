import XCTest

@testable import Gravitas_Plague

final class MindEyePhase10MainActorBoundaryTests: XCTestCase {
    func testDispatchPressureSourceOwnsAProductionBackgroundQueue() throws {
        let source = try MindEyePhase10Source.read(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye/MindEyeMemoryPressure.swift"
        )
        XCTAssertTrue(source.contains("DispatchSource.makeMemoryPressureSource"))
        XCTAssertTrue(source.contains("DispatchQueue("))
        XCTAssertTrue(source.contains("qos: .userInitiated"))
        XCTAssertFalse(source.contains("@MainActor"))
    }

    func testPhase10AddsNoCPUImageComposition() throws {
        let paths = MindEyePhase10Source.phase10AddedFiles
        let source = try paths.map(MindEyePhase10Source.read).joined(separator: "\n")
        for forbidden in ["CGContext", "UIImage", "CGImage", "CVPixelBuffer"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }
}
