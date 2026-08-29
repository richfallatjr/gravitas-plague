import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeReleaseScenarioTests: XCTestCase {
    func testRequiredScenarioMatrixUsesKnownScenarioAndFeatureValues() throws {
        let url = MindEyePhase11TestSource.projectRoot.appendingPathComponent(
            "Gravitas Plague/Scripts/mind_eye_qualification/config/release_matrix.json"
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url))
                as? [String: Any]
        )
        let runs = try XCTUnwrap(object["requiredRuns"] as? [[String: Any]])
        XCTAssertFalse(runs.isEmpty)
        for run in runs {
            XCTAssertNotNil(
                MindEyeReleaseScenario(rawValue: try XCTUnwrap(run["scenario"] as? String))
            )
            XCTAssertNotNil(
                MindEyeQualificationFeatureMode(
                    rawValue: try XCTUnwrap(run["featureMode"] as? String)
                )
            )
        }
        XCTAssertTrue(runs.contains { $0["scenario"] as? String == "authoredBigMikeAllTen" })
        XCTAssertTrue(runs.contains { $0["scenario"] as? String == "testFlightEquivalent" })
    }
}
