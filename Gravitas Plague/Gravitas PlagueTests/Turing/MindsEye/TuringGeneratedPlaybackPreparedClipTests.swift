import Foundation
import XCTest

@testable import Gravitas_Plague

final class TuringGeneratedPlaybackPreparedClipTests: XCTestCase {
    func testExpiredVisualBudgetStillReturnsAndDeletesMandatoryWAV() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("phase9-prepared-\(UUID().uuidString)", isDirectory: true)
        let store = TuringGeneratedPlaybackFileStore(
            rootURL: root,
            generatedSpeechAnalysisBudget: .init(
                hardBudget: .zero,
                postFileWriteGrace: .zero
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
        XCTAssertNil(clip.generatedVisualAnalysis)
        XCTAssertNotNil(clip.generatedVisualAnalysisStatus)
        await store.delete(clip, reason: "test")
        XCTAssertFalse(FileManager.default.fileExists(atPath: clip.fileURL.path))
        await store.endRun("run", reason: "test")
    }
}
