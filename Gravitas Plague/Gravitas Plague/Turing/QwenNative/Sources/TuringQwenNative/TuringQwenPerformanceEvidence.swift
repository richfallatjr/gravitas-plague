import Foundation
import CryptoKit

/// Optional listening/token evidence, never a quality verdict or a performance
/// promotion run: retaining already-materialized CPU arrays changes memory use.
public struct TuringQwenPerformanceEvidenceReport: Codable, Sendable {
    public let status: String
    public let directory: String
    public let manifestFilename: String?
    public let manifestSHA256: String?
    public let retainedPayloadBytes: Int
    public let performancePromotionEligible: Bool
    public let exportError: String?
}

enum TuringQwenPerformanceEvidence {
    @TaskLocal static var current: Capture?

    struct EvidenceError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Codes: Sendable {
        let runID: String
        let voiceID: String
        let segmentIndex: Int
        let codebookCount: Int
        let conditioningReferenceRowCount: Int
        let decodeReferenceRowCount: Int
        let generatedRowCount: Int
        let reachedEOS: Bool
        let referenceCodes: ContiguousArray<Int32>
        let generatedCodes: ContiguousArray<Int32>
    }

    struct PCM: Sendable {
        let runID: String
        let voiceID: String
        let segmentIndex: Int
        let sampleRate: Int
        let samples: [Float]
    }

    /// Only CPU arrays are retained here. There is no MLX access, evaluation,
    /// conversion, file I/O, token reconstruction, or audio processing in capture.
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private let segmentCount: Int
        private let maximumRows: Int
        private var codes: [Int: Codes] = [:]
        private var pcm: [Int: PCM] = [:]
        private var codeBytes = 0
        private var pcmBytes = 0
        static let maximumCodeBytes = 2 * 1024 * 1024
        static let maximumPCMBytes = 16 * 1024 * 1024

        init(segmentCount: Int, maximumRows: Int) throws {
            guard (1...6).contains(segmentCount), (1...160).contains(maximumRows) else {
                throw EvidenceError(message: "Quality evidence requires bounded segment and row counts")
            }
            self.segmentCount = segmentCount
            self.maximumRows = maximumRows
        }

        func recordCodes(_ value: Codes) throws {
            lock.lock(); defer { lock.unlock() }
            guard (0..<segmentCount).contains(value.segmentIndex), codes[value.segmentIndex] == nil,
                  value.codebookCount == 16, value.conditioningReferenceRowCount >= 0,
                  (0...value.conditioningReferenceRowCount).contains(value.decodeReferenceRowCount),
                  (1...maximumRows).contains(value.generatedRowCount),
                  value.referenceCodes.count % 16 == 0,
                  value.referenceCodes.count / 16 == value.conditioningReferenceRowCount,
                  value.generatedCodes.count == value.generatedRowCount * 16,
                  value.referenceCodes.count <= Self.maximumCodeBytes / 4,
                  value.generatedCodes.count <= Self.maximumCodeBytes / 4 else {
                throw EvidenceError(message: "Missing, duplicate, malformed, or oversized native codebook evidence")
            }
            let bytes = (value.referenceCodes.count + value.generatedCodes.count) * 4
            guard bytes <= Self.maximumCodeBytes - codeBytes else {
                throw EvidenceError(message: "Quality evidence codebook retention limit exceeded")
            }
            codes[value.segmentIndex] = value
            codeBytes += bytes
        }

        func recordPCM(_ value: PCM) throws {
            lock.lock(); defer { lock.unlock() }
            guard (0..<segmentCount).contains(value.segmentIndex), pcm[value.segmentIndex] == nil,
                  value.sampleRate > 0, !value.samples.isEmpty,
                  value.samples.count <= (Self.maximumPCMBytes - pcmBytes) / 4 else {
                throw EvidenceError(message: "Missing, duplicate, malformed, or oversized native PCM evidence")
            }
            pcm[value.segmentIndex] = value
            pcmBytes += value.samples.count * 4
        }

        func snapshot() -> (codes: [Int: Codes], pcm: [Int: PCM], retainedPayloadBytes: Int) {
            lock.lock(); defer { lock.unlock() }
            return (codes, pcm, codeBytes + pcmBytes)
        }
    }

    struct Context {
        let runID: String
        let characterID: String
        let voiceID: String
        let texts: [String]
        let samplingSeed: UInt64
        let maximumRowsPerSegment: Int
        let workloadSHA256: String
        let policySHA256: String
        let workloadJSON: Data
        let policyJSON: Data
        let identitySHA256: [String: String]
        let outcome: String
        let failure: String?
    }

    struct Segment: Codable {
        let segmentIndex: Int
        let voiceID: String
        let text: String
        let textSHA256: String
        let samplingSeed: UInt64
        let status: String
        let stopReason: String
        let reachedEOS: Bool?
        let generatedRowCount: Int?
        let conditioningReferenceRowCount: Int?
        let decodeReferenceRowCount: Int?
        let codebookCount: Int?
        let generatedCodesI32LESHA256: String?
        let codeRowsFilename: String?
        let codeRowsFileSHA256: String?
        let sampleCount: Int?
        let sampleRate: Int?
        let pcmF32LESHA256: String?
        let wavFilename: String?
        let wavFileSHA256: String?
        let unavailable: [String]
    }

    struct CodeRows: Codable {
        let schemaVersion: Int
        let runID: String
        let voiceID: String
        let segmentIndex: Int
        let generatedCodeRows: [[Int32]]
        let conditioningReferenceCodeRows: [[Int32]]
        let decodeReferenceCodeRows: [[Int32]]
        let semantics: String
    }

    struct Manifest: Codable {
        let schemaVersion: Int
        let status: String
        let performancePromotionEligible: Bool
        let captureSemantics: String
        let serializationAfterRenderTiming: Bool
        let retainedPayloadBytes: Int
        let runID: String
        let characterID: String
        let voiceID: String
        let workloadSHA256: String
        let policySHA256: String
        let workloadFilename: String
        let policyFilename: String
        let identitySHA256: [String: String]
        let runOutcome: String
        let runFailure: String?
        let samplingSeedPolicy: String
        let maximumRowsPerSegment: Int
        let segments: [Segment]
    }

    static func validateDestination(_ directory: URL) throws {
        guard directory.isFileURL,
              !FileManager.default.fileExists(atPath: directory.path) else {
            throw EvidenceError(message: "Use a new quality evidence directory; earlier evidence must not be overwritten")
        }
    }

    static func export(capture: Capture, context: Context, directory: URL) throws -> TuringQwenPerformanceEvidenceReport {
        try validateDestination(directory)
        let snapshot = capture.snapshot()
        guard (1...6).contains(context.texts.count) else {
            throw EvidenceError(message: "Quality evidence context has invalid segment coverage")
        }
        // Validate all captured identities before creating any output artifact.
        for value in snapshot.codes.values {
            guard value.runID == context.runID, value.voiceID == context.voiceID,
                  context.texts.indices.contains(value.segmentIndex) else {
                throw EvidenceError(message: "Native codebook evidence belongs to another run/voice/segment")
            }
        }
        for value in snapshot.pcm.values {
            guard value.runID == context.runID, value.voiceID == context.voiceID,
                  context.texts.indices.contains(value.segmentIndex), value.samples.allSatisfy(\.isFinite) else {
                throw EvidenceError(message: "Native PCM evidence is nonfinite or belongs to another run/voice/segment")
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Exclusive writes also protect against an output-path race. A failed
        // export may leave partial files, but cannot replace prior evidence.
        try context.workloadJSON.write(to: directory.appendingPathComponent("workload.json"), options: .withoutOverwriting)
        try context.policyJSON.write(to: directory.appendingPathComponent("policy.json"), options: .withoutOverwriting)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var segments: [Segment] = []
        for index in context.texts.indices {
            let codes = snapshot.codes[index]
            let pcm = snapshot.pcm[index]
            var unavailable: [String] = []
            var codeFilename: String?
            var codeFileHash: String?
            var codeHash: String?
            var wavFilename: String?
            var wavHash: String?
            var pcmHash: String?
            if let codes {
                let references = rows(codes.referenceCodes)
                let codeRows = CodeRows(schemaVersion: 1, runID: context.runID, voiceID: context.voiceID,
                    segmentIndex: index, generatedCodeRows: rows(codes.generatedCodes),
                    conditioningReferenceCodeRows: references,
                    decodeReferenceCodeRows: Array(references.suffix(codes.decodeReferenceRowCount)),
                    semantics: "Exact existing CPU codebook rows; generated rows exclude the terminal EOS token. Row and codebook indices are zero based.")
                let data = try encoder.encode(codeRows)
                let filename = String(format: "segment-%03d.codes.json", index)
                try data.write(to: directory.appendingPathComponent(filename), options: .withoutOverwriting)
                codeFilename = filename
                codeFileHash = digest(data)
                codeHash = digest(integerPayload(codes.generatedCodes))
            } else { unavailable.append("Native generated/conditioning code rows were not captured; no tokens reconstructed from PCM") }
            if let pcm {
                let payload = floatPayload(pcm.samples)
                let wav = try wavData(payload: payload, sampleCount: pcm.samples.count, sampleRate: pcm.sampleRate)
                let filename = String(format: "segment-%03d.wav", index)
                try wav.write(to: directory.appendingPathComponent(filename), options: .withoutOverwriting)
                wavFilename = filename
                wavHash = digest(wav)
                pcmHash = digest(payload)
            } else { unavailable.append("Native decoded PCM was not captured; no silence or replacement audio generated") }
            segments.append(Segment(segmentIndex: index, voiceID: context.voiceID,
                text: context.texts[index], textSHA256: digest(Data(context.texts[index].utf8)),
                samplingSeed: context.samplingSeed &+ UInt64(index),
                status: unavailable.isEmpty ? "CAPTURED_UNASSESSED" : "PARTIAL_OR_UNAVAILABLE",
                stopReason: codes.map { $0.reachedEOS ? "naturalEOS" : "didNotReachEOS" } ?? "unavailable",
                reachedEOS: codes?.reachedEOS, generatedRowCount: codes?.generatedRowCount,
                conditioningReferenceRowCount: codes?.conditioningReferenceRowCount,
                decodeReferenceRowCount: codes?.decodeReferenceRowCount, codebookCount: codes?.codebookCount,
                generatedCodesI32LESHA256: codeHash, codeRowsFilename: codeFilename, codeRowsFileSHA256: codeFileHash,
                sampleCount: pcm?.samples.count, sampleRate: pcm?.sampleRate, pcmF32LESHA256: pcmHash,
                wavFilename: wavFilename, wavFileSHA256: wavHash, unavailable: unavailable))
        }
        let manifest = Manifest(schemaVersion: 1,
            status: segments.allSatisfy({ $0.unavailable.isEmpty })
                ? "UNASSESSED_REQUIRES_LISTENING_AND_TOKEN_COMPARISON" : "PARTIAL_EVIDENCE_UNASSESSED",
            performancePromotionEligible: false,
            captureSemantics: "Opt-in retention of existing CPU PCM/code arrays changes memory use. Payload byte count excludes metadata/allocator overhead. No extra inference evaluation/readback; WAV is unnormalized mono IEEE float32 at the native sample rate. This run cannot support performance promotion or imply a quality pass.",
            serializationAfterRenderTiming: true, retainedPayloadBytes: snapshot.retainedPayloadBytes,
            runID: context.runID, characterID: context.characterID, voiceID: context.voiceID,
            workloadSHA256: context.workloadSHA256, policySHA256: context.policySHA256,
            workloadFilename: "workload.json", policyFilename: "policy.json", identitySHA256: context.identitySHA256,
            runOutcome: context.outcome, runFailure: context.failure, samplingSeedPolicy: "fixture seed + segment index (UInt64 wrapping addition)",
            maximumRowsPerSegment: context.maximumRowsPerSegment, segments: segments)
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent("evidence.json"), options: .withoutOverwriting)
        return .init(status: manifest.status, directory: directory.path, manifestFilename: "evidence.json",
                     manifestSHA256: digest(data), retainedPayloadBytes: snapshot.retainedPayloadBytes,
                     performancePromotionEligible: false, exportError: nil)
    }

    private static func rows(_ codes: ContiguousArray<Int32>) -> [[Int32]] {
        stride(from: 0, to: codes.count, by: 16).map { Array(codes[$0..<($0 + 16)]) }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func floatPayload(_ samples: [Float]) -> Data {
        var result = Data(capacity: samples.count * 4)
        for sample in samples { append(sample.bitPattern, to: &result) }
        return result
    }

    private static func integerPayload(_ codes: ContiguousArray<Int32>) -> Data {
        var result = Data(capacity: codes.count * 4)
        for code in codes { append(UInt32(bitPattern: code), to: &result) }
        return result
    }

    static func wavData(payload: Data, sampleCount: Int, sampleRate: Int) throws -> Data {
        guard sampleRate > 0, sampleRate <= Int(UInt32.max) / 4,
              sampleCount > 0, sampleCount <= Capture.maximumPCMBytes / 4,
              payload.count == sampleCount * 4 else {
            throw EvidenceError(message: "Invalid or oversized native float32 WAV payload")
        }
        var result = Data("RIFF".utf8)
        append(UInt32(48 + payload.count), to: &result)
        result.append(Data("WAVEfmt ".utf8))
        append(UInt32(16), to: &result)
        append(UInt16(3), to: &result) // IEEE float, not quantized/clipped PCM16.
        append(UInt16(1), to: &result)
        append(UInt32(sampleRate), to: &result)
        append(UInt32(sampleRate * 4), to: &result)
        append(UInt16(4), to: &result)
        append(UInt16(32), to: &result)
        result.append(Data("fact".utf8))
        append(UInt32(4), to: &result)
        append(UInt32(sampleCount), to: &result)
        result.append(Data("data".utf8))
        append(UInt32(payload.count), to: &result)
        result.append(payload)
        return result
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
