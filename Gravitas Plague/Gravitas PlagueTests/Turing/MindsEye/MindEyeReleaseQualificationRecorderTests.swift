import Foundation
import XCTest

@testable import Gravitas_Plague

enum MindEyePhase11TestFixture {
    static func process() -> TuringMemoryBudgetSnapshot {
        TuringMemoryBudgetSnapshot(
            label: "test",
            availableProcessMemoryBytes: 0,
            physicalFootprintBytes: 1,
            residentSizeBytes: 1,
            peakPhysicalFootprintBytes: 1,
            mlxActiveMemoryBytes: 0,
            mlxCacheMemoryBytes: 0,
            mlxPeakMemoryBytes: 0,
            mlxCacheLimitBytes: 0,
            mlxMemoryLimitBytes: 0,
            activeQwenModelID: nil,
            quantization: nil,
            increasedMemoryEntitlementStatus: "test"
        )
    }

    static func resource() -> MindEyeReleaseResourceSnapshot {
        .empty(process: process())
    }

    static func run(
        scenario: MindEyeReleaseScenario = .controlStoryScene
    ) -> MindEyeReleaseScenarioRun {
        MindEyeReleaseScenarioRun(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            scenario: scenario,
            configuration: .releaseNoDebugger,
            sequenceNumber: 0
        )
    }
}

final class MindEyeReleaseQualificationRecorderTests: XCTestCase {
    func testRecorderAssignsOrderedOrdinals() async throws {
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
                notes: ["z", "a"]
            )
        }
        let report = try await recorder.finish()
        XCTAssertEqual(report.events.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(report.events.first?.notes, ["a", "z"])
        XCTAssertEqual(report.validationErrors(), [])
    }
}
