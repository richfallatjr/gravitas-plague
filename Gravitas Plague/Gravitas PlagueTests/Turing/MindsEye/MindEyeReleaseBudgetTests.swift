import Foundation
import XCTest

@testable import Gravitas_Plague

final class MindEyeReleaseBudgetTests: XCTestCase {
    func testRepositoryBudgetDecodesAndValidates() throws {
        let url = MindEyePhase11TestSource.projectRoot.appendingPathComponent(
            "Gravitas Plague/Scripts/mind_eye_qualification/config/release_budget.json"
        )
        let budget = try JSONDecoder().decode(
            MindEyeReleaseBudget.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(budget.schemaVersion, 1)
        XCTAssertEqual(budget.memory.releaseObservationSeconds, [0, 2, 5, 15, 30])
        XCTAssertEqual(budget.validationErrors(), [])
    }
}
