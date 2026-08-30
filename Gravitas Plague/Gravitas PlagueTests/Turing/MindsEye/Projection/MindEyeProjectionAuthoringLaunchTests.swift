import XCTest
@testable import Gravitas_Plague

final class MindEyeProjectionAuthoringLaunchTests: XCTestCase {
    func testLaunchArgumentIsOptionalAndExact() throws {
        XCTAssertNil(try MindEyeProjectionAuthoringLaunchConfiguration.current(arguments: ["app"]))
        let present = [
            "app",
            "--mind-eye-projection-job=inspect-subject",
            "--mind-eye-projection-capture-id=angel_head_v1"
        ]
        XCTAssertEqual(
            try MindEyeProjectionAuthoringLaunchConfiguration.current(arguments: present)?.job,
            .inspectSubject
        )
    }
}
