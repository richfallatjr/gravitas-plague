import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringGeneratedPlaybackPreparedClipTests: XCTestCase {
    func testTicketedAnalysisNeverDelaysOrOwnsMandatoryWAV() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase9-prepared-\(UUID().uuidString)", isDirectory: true)
        let store = TuringGeneratedPlaybackFileStore(
            rootURL: root,
            generatedSpeechAnalysisCoordinator: .init(
                policy: .init(
                    minimumComputeBudget: .milliseconds(150),
                    maximumComputeBudget: .milliseconds(800),
                    computeBudgetFraction: 0.08,
                    maximumQueueDelay: .seconds(1),
                    maximumTotalLatency: .seconds(2),
                    maximumQueuedJobCount: 2,
                    maximumRetainedPCMBytes: 32 * 1024 * 1024
                )
            )
        )
        _ = try await store.beginRun("run")
        let clip = try await store.write(
            runID: "run",
            segmentIndex: 0,
            audio: .init(
                segmentIndex: 0,
                samples: Array(repeating: 0.1, count: 4_800),
                sampleRate: 48_000
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: clip.fileURL.path))
        switch clip.generatedVisualAnalysisState {
        case .pending, .ready:
            break
        case .unavailable(let reason):
            XCTFail("Valid analysis submission was rejected: \(reason)")
        }
        await store.delete(clip, reason: "test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.fileURL.path))
        await store.endRun("run", reason: "test")
    }
}
