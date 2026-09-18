import Foundation
import Testing
@testable import TuringQwenNative

struct TuringQwenPerformanceWorkloadTests {
    private func fixture(rows: Int = 4, wall: Double = 60, footprint: Double = 6_000,
                         codes: [[Int]]? = nil, prefix: Int? = nil,
                         complete: Bool? = nil) -> TuringQwenPerformanceWorkload {
        .init(schemaVersion: 1, id: "test", origin: "synthetic contract test", characterID: "big_mike",
              voiceID: "big_mike_base_clone_v1", language: "English", segments: ["Hello world"],
              samplingSeed: 1, maximumRowsPerSegment: rows, wallCapSeconds: wall,
              footprintCapMiB: footprint, decoderCodes: codes, decoderReferenceRows: prefix,
              requireCompleteSegments: complete)
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
    @Test func fullSegmentsUseProductionCeilingAndRequireObservedNaturalEOS() throws {
        let full = fixture(rows: 160, complete: true)
        try full.validate()
        try full.validateProductionMaximumRows(160)
        try full.validateCompletion(reachedEOS: true, generatedRows: 75)
        #expect(throws: (any Error).self) { try full.validateCompletion(reachedEOS: false, generatedRows: 160) }
        #expect(throws: (any Error).self) { try full.validateCompletion(reachedEOS: nil, generatedRows: 75) }
        #expect(throws: (any Error).self) { try full.validateCompletion(reachedEOS: true, generatedRows: nil) }
        #expect(throws: (any Error).self) { try full.validateCompletion(reachedEOS: true, generatedRows: 0) }
        #expect(throws: (any Error).self) { try full.validateCompletion(reachedEOS: true, generatedRows: 161) }
        #expect(throws: (any Error).self) { try fixture(rows: 32, complete: true).validateProductionMaximumRows(160) }
        #expect(throws: (any Error).self) { try full.validateProductionMaximumRows(159) }
        #expect(throws: (any Error).self) { try fixture(rows: 161, complete: true).validate() }
        #expect(throws: (any Error).self) { try full.validate(decoderOnly: true) }
        // Historical diagnostic fixtures remain explicitly truncated scouts.
        try fixture().validateCompletion(reachedEOS: false, generatedRows: 4)
    }
    @Test func fullSegmentFlagRoundTripsAndChangesIdentityWithoutChangingLegacy() throws {
        let full = fixture(rows: 160, complete: true)
        let copy = try JSONDecoder().decode(TuringQwenPerformanceWorkload.self, from: JSONEncoder().encode(full))
        #expect(copy == full)
        #expect(try fixture().fingerprint != fixture(complete: false).fingerprint)
        let legacyData = try JSONEncoder().encode(fixture())
        let dictionary = try #require(JSONSerialization.jsonObject(with: legacyData) as? [String: Any])
        #expect(dictionary["requireCompleteSegments"] == nil)
    }
    @Test func fullSegmentRunRejectsSkippedMissingDuplicateAndTruncatedSpeech() throws {
        let full = fixture(rows: 160, complete: true)
        try full.validateCompletedSegments(pcmIndices: [0], completions: [(0, true, 48)])
        #expect(throws: (any Error).self) {
            try full.validateCompletedSegments(pcmIndices: [], completions: [])
        }
        #expect(throws: (any Error).self) {
            try full.validateCompletedSegments(pcmIndices: [0], completions: [])
        }
        #expect(throws: (any Error).self) {
            try full.validateCompletedSegments(pcmIndices: [0, 0], completions: [(0, true, 48)])
        }
        #expect(throws: (any Error).self) {
            try full.validateCompletedSegments(pcmIndices: [0], completions: [(0, true, 48), (0, true, 48)])
        }
        #expect(throws: (any Error).self) {
            try full.validateCompletedSegments(pcmIndices: [0], completions: [(1, true, 48)])
        }
        #expect(throws: (any Error).self) {
            try full.validateCompletedSegments(pcmIndices: [0], completions: [(0, false, 160)])
        }
        try fixture().validateCompletedSegments(pcmIndices: [], completions: [])
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
        let candidate = TuringQwenNativeExecutionPolicy(prefill: .fusedCausalCandidate)
        #expect(throws: (any Error).self) { try candidate.validateImplemented() }
    }
}
