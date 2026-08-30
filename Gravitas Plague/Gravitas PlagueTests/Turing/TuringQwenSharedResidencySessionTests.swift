import TuringQwenNative
import XCTest

@testable import Gravitas_Plague

final class TuringQwenSharedResidencySessionTests: XCTestCase {
    func testProductionDefaultRemainsIndependentFresh2() throws {
        let configuration = try TuringQwenResidencyExperimentConfiguration.current(
            arguments: ["--turing-qwen-residency=sharedImmutableFresh2"]
        )
        #if GR_TURING_SHARED_RESIDENCY
        XCTAssertEqual(configuration.mode, .sharedImmutableFresh2)
        #elseif GR_TURING_QUALIFICATION
        XCTAssertEqual(configuration.mode, .sharedImmutableFresh2)
        #else
        XCTAssertEqual(configuration.mode, .independentFresh2)
        #endif
    }

    func testSessionPassesExplicitResidencyModeToFresh2Factory() throws {
        let source = try Phase3AppSource.read(
            "Gravitas Plague/Gravitas Plague/Turing/Flow/" +
                "TuringCharacterQwenRenderSession.swift"
        )
        XCTAssertTrue(source.contains("residencyMode: resolvedResidencyConfiguration.mode"))
        XCTAssertTrue(source.contains("makeFresh2Scheduler"))
    }
}

enum Phase3AppSource {
    static func read(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return try String(
            contentsOf: root.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
