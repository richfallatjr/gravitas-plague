import Foundation
import Testing
@testable import TuringQwenNative

struct TuringQwenPerformanceWorkloadTests {
    private func fixture(rows: Int = 4, wall: Double = 60, footprint: Double = 6_000,
                         codes: [[Int]]? = nil, prefix: Int? = nil) -> TuringQwenPerformanceWorkload {
        .init(schemaVersion: 1, id: "test", origin: "synthetic contract test", characterID: "big_mike",
              voiceID: "big_mike_base_clone_v1", language: "English", segments: ["Hello world"],
              samplingSeed: 1, maximumRowsPerSegment: rows, wallCapSeconds: wall,
              footprintCapMiB: footprint, decoderCodes: codes, decoderReferenceRows: prefix)
    }
    @Test func boundedFixtureRoundTripsAndHashesStably() throws {
        let original = fixture()
        let copy = try JSONDecoder().decode(TuringQwenPerformanceWorkload.self, from: JSONEncoder().encode(original))
        try copy.validate()
        #expect(original == copy)
        #expect(try original.fingerprint == copy.fingerprint)
    }
    @Test func unsafeBudgetsFailBeforeGeneration() {
        for invalid in [fixture(rows: 0), fixture(rows: 160), fixture(wall: 0), fixture(wall: .infinity),
                        fixture(footprint: 27_000), fixture(footprint: .nan)] {
            #expect(throws: (any Error).self) { try invalid.validate() }
        }
    }
    @Test func decoderUsesDistinctSemanticVocabularyAndRequiresPrefix() throws {
        var row = Array(repeating: 2047, count: 16)
        row[0] = 4095
        try fixture(codes: [row], prefix: 0).validate(decoderOnly: true)
        #expect(throws: (any Error).self) { try fixture(codes: [row], prefix: nil).validate(decoderOnly: true) }
        row[1] = 2048
        #expect(throws: (any Error).self) { try fixture(codes: [row], prefix: 0).validate(decoderOnly: true) }
    }
    @Test func readinessUsesNeededPredecessorsNotCompletionOrder() throws {
        func record(_ index: Int, _ seconds: Double) -> TuringQwenPerformancePCMRecord {
            .init(segmentIndex: index, readySeconds: seconds, sampleCount: 24_000, sampleRate: 24_000, pcmSHA256: "test")
        }
        #expect(try TuringQwenPerformanceReadiness.ordered([record(1, 3), record(0, 5), record(2, 7)], count: 3) == [5, 5, 7])
        #expect(try TuringQwenPerformanceReadiness.ordered([record(0, 5), record(2, 7)], count: 3) == [5, nil, nil])
        #expect(throws: (any Error).self) { try TuringQwenPerformanceReadiness.ordered([record(0, 1), record(0, 2)], count: 1) }
    }
    @Test func unsupportedPolicyDoesNotSilentlyFallBack() {
        let candidate = TuringQwenNativeExecutionPolicy(arithmetic: .bf16Candidate)
        #expect(throws: (any Error).self) { try candidate.validateImplemented() }
    }
}
