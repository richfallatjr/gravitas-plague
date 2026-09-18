import Foundation
import Testing
@testable import TuringQwenNative

struct TuringQwenPerformanceEvidenceTests {
    private typealias Evidence = TuringQwenPerformanceEvidence

    private func context(texts: [String] = ["Complete native segment"], seed: UInt64 = 17) -> Evidence.Context {
        .init(runID: "run", characterID: "big_mike", voiceID: "voice", texts: texts,
              samplingSeed: seed, maximumRowsPerSegment: 160, workloadSHA256: "workload-hash",
              policySHA256: "policy-hash", workloadJSON: Data("{\"id\":\"fixture\"}".utf8),
              policyJSON: Data("{\"arithmetic\":\"legacy\"}".utf8), identitySHA256: ["model": "model-hash"],
              outcome: "SCOUT_COMPLETED", failure: nil)
    }

    private func codes(index: Int = 0, runID: String = "run", reachedEOS: Bool = true) -> Evidence.Codes {
        .init(runID: runID, voiceID: "voice", segmentIndex: index, codebookCount: 16,
              conditioningReferenceRowCount: 3, decodeReferenceRowCount: 2, generatedRowCount: 2,
              reachedEOS: reachedEOS, referenceCodes: ContiguousArray((0..<48).map(Int32.init)),
              generatedCodes: ContiguousArray((100..<132).map(Int32.init)))
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qwen-evidence-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    @Test func exportPreservesExactFloatPCMCodeRowsAndMetadata() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try Evidence.Capture(segmentCount: 1, maximumRows: 160)
        let samples: [Float] = [0, -0.0, 0.25, -0.5, 1.25]
        try capture.recordCodes(codes())
        try capture.recordPCM(.init(runID: "run", voiceID: "voice", segmentIndex: 0,
                                    sampleRate: 24_000, samples: samples))
        let directory = root.appendingPathComponent("evidence")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        // UInt64 metadata must not round through a JSON Double/JavaScript number.
        let exported = try Evidence.export(capture: capture, context: context(seed: 9_155_153_355_066_127_096), directory: directory)
        #expect(exported.performancePromotionEligible == false)
        #expect(exported.status == "UNASSESSED_REQUIRES_LISTENING_AND_TOKEN_COMPARISON")
        #expect(exported.retainedPayloadBytes == (48 + 32 + samples.count) * 4)
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("evidence.json"))
        #expect(Evidence.digest(manifestData) == exported.manifestSHA256)
        let manifest = try JSONDecoder().decode(Evidence.Manifest.self, from: manifestData)
        #expect(manifest.serializationAfterRenderTiming)
        #expect(!manifest.performancePromotionEligible)
        #expect(manifest.policySHA256 == "policy-hash")
        #expect(manifest.workloadSHA256 == "workload-hash")
        let segment = try #require(manifest.segments.first)
        #expect(segment.samplingSeed == 9_155_153_355_066_127_096)
        #expect(segment.reachedEOS == true && segment.stopReason == "naturalEOS")
        #expect(segment.generatedRowCount == 2 && segment.conditioningReferenceRowCount == 3)
        #expect(segment.decodeReferenceRowCount == 2 && segment.unavailable.isEmpty)
        let codeData = try Data(contentsOf: directory.appendingPathComponent(try #require(segment.codeRowsFilename)))
        #expect(Evidence.digest(codeData) == segment.codeRowsFileSHA256)
        let rows = try JSONDecoder().decode(Evidence.CodeRows.self, from: codeData)
        #expect(rows.generatedCodeRows == [(100..<116).map(Int32.init), (116..<132).map(Int32.init)])
        #expect(rows.conditioningReferenceCodeRows.count == 3)
        #expect(rows.decodeReferenceCodeRows == Array(rows.conditioningReferenceCodeRows.suffix(2)))
        let wav = try Data(contentsOf: directory.appendingPathComponent(try #require(segment.wavFilename)))
        #expect(Evidence.digest(wav) == segment.wavFileSHA256)
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav[20] == 3 && wav[21] == 0) // IEEE float32, mono.
        #expect(wav[22] == 1 && wav[34] == 32)
        #expect(wav[36..<40] == Data("fact".utf8))
        #expect(wav[48..<52] == Data("data".utf8))
        let payload = Evidence.floatPayload(samples)
        #expect(wav.suffix(payload.count) == payload)
        #expect(Evidence.digest(payload) == segment.pcmF32LESHA256)
        #expect(try Data(contentsOf: directory.appendingPathComponent("policy.json")) == context().policyJSON)
        #expect(try Data(contentsOf: directory.appendingPathComponent("workload.json")) == context().workloadJSON)
    }

    @Test func partialEvidenceIsExplicitAndDoesNotInventPCMOrEOS() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try Evidence.Capture(segmentCount: 2, maximumRows: 160)
        try capture.recordCodes(codes(reachedEOS: false))
        let directory = root.appendingPathComponent("partial")
        let exported = try Evidence.export(capture: capture,
            context: context(texts: ["Capped segment", "Skipped segment"], seed: UInt64.max), directory: directory)
        #expect(exported.status == "PARTIAL_EVIDENCE_UNASSESSED")
        let manifest = try JSONDecoder().decode(Evidence.Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("evidence.json")))
        #expect(manifest.segments.count == 2)
        #expect(manifest.segments[0].stopReason == "didNotReachEOS")
        #expect(manifest.segments[0].wavFilename == nil && manifest.segments[0].sampleCount == nil)
        #expect(manifest.segments[1].reachedEOS == nil && manifest.segments[1].generatedRowCount == nil)
        #expect(manifest.segments[1].codeRowsFilename == nil && manifest.segments[1].wavFilename == nil)
        #expect(manifest.segments[1].unavailable.count == 2 && manifest.segments[1].samplingSeed == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("segment-001.wav").path))
    }

    @Test func priorEvidenceIsNeverOverwrittenAndWrongRunCannotExport() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = try Evidence.Capture(segmentCount: 1, maximumRows: 160)
        try capture.recordCodes(codes(runID: "different-run"))
        let output = root.appendingPathComponent("wrong-run")
        #expect(throws: (any Error).self) { try Evidence.export(capture: capture, context: context(), directory: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        let sentinel = root.appendingPathComponent("keep.txt")
        let original = Data("earlier evidence".utf8)
        try original.write(to: sentinel)
        #expect(throws: (any Error).self) { try Evidence.validateDestination(root) }
        #expect(try Data(contentsOf: sentinel) == original)
    }

    @Test func captureBoundsDuplicatesAndNonfiniteAudioFailClosed() throws {
        #expect(Evidence.current == nil)
        #expect(throws: (any Error).self) { try Evidence.Capture(segmentCount: 7, maximumRows: 160) }
        #expect(throws: (any Error).self) { try Evidence.Capture(segmentCount: 1, maximumRows: 161) }
        let capture = try Evidence.Capture(segmentCount: 1, maximumRows: 160)
        try capture.recordCodes(codes())
        #expect(throws: (any Error).self) { try capture.recordCodes(codes()) }
        #expect(throws: (any Error).self) { try capture.recordCodes(codes(index: 1)) }
        try capture.recordPCM(.init(runID: "run", voiceID: "voice", segmentIndex: 0,
                                    sampleRate: 24_000, samples: [.nan]))
        #expect(throws: (any Error).self) {
            try capture.recordPCM(.init(runID: "run", voiceID: "voice", segmentIndex: 0,
                                        sampleRate: 24_000, samples: [0]))
        }
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("nonfinite")
        #expect(throws: (any Error).self) { try Evidence.export(capture: capture, context: context(), directory: output) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(throws: (any Error).self) { try Evidence.wavData(payload: Data(), sampleCount: 1, sampleRate: 24_000) }
    }
}
