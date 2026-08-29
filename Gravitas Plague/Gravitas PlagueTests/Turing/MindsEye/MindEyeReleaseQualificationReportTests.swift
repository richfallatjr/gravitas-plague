import XCTest

@testable import Gravitas_Plague

final class MindEyeReleaseQualificationReportTests: XCTestCase {
    func testDeterministicEncodingIsByteStable() async throws {
        let recorder = MindEyeReleaseQualificationRecorder()
        try await recorder.begin(run: MindEyePhase11TestFixture.run())
        for checkpoint in [
            MindEyeQualificationCheckpoint.appCold,
            .immersiveEntered,
            .storySystemsReady
        ] {
            try await recorder.record(
                checkpoint: checkpoint,
                playbackRunID: nil,
                mediaIdentity: nil,
                speakerCharacterID: nil,
                interactionSurface: nil,
                resource: MindEyePhase11TestFixture.resource(),
                timing: .empty,
                notes: []
            )
        }
        let report = try await recorder.finish()
        XCTAssertEqual(
            try report.deterministicJSONData(),
            try report.deterministicJSONData()
        )
        XCTAssertNil(report.generatedAtUTC)
    }
}
