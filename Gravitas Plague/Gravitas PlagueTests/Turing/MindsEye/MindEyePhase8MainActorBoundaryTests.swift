import XCTest

@testable import Gravitas_Plague

final class MindEyePhase8MainActorBoundaryTests: XCTestCase {
    func testBlockingRuntimeWorkLivesOnlyInSerialWorker() throws {
        let directory = mindEyeProjectRoot().appendingPathComponent(
            "Gravitas Plague/Gravitas Plague/Turing/MindsEye",
            isDirectory: true
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("MindEyeAuthored") }
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            if source.contains("Data(contentsOf:") || source.contains("JSONDecoder()") {
                XCTAssertEqual(file.lastPathComponent, "MindEyeAuthoredFrameRuntimeWorker.swift")
            }
        }
        let worker = try String(
            contentsOf: directory.appendingPathComponent("MindEyeAuthoredFrameRuntimeWorker.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(worker.contains("Thread.isMainThread == false"))
        XCTAssertTrue(worker.contains("DispatchSpecificKey"))
    }
}
