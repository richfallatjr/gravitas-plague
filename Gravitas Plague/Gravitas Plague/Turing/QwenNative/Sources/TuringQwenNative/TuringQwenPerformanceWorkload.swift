import Foundation
import CryptoKit

/// A compact immutable fixture, not a replacement for the app's segmenter.
public struct TuringQwenPerformanceWorkload: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let origin: String
    public let characterID: String
    public let voiceID: String
    public let language: String
    public let segments: [String]
    public let samplingSeed: UInt64
    public let maximumRowsPerSegment: Int
    public let wallCapSeconds: Double
    public let footprintCapMiB: Double
    public let decoderCodes: [[Int]]?
    public let decoderReferenceRows: Int?
    /// Complete production-segment replay, not a truncated diagnostic scout.
    /// Nil/false preserves old fixture behavior and its smaller safety ceiling.
    public let requireCompleteSegments: Bool?

    public func validate(decoderOnly: Bool = false) throws {
        guard schemaVersion == 1, !id.isEmpty, !origin.isEmpty, !voiceID.isEmpty,
              !characterID.isEmpty, !language.isEmpty,
              (1...(requireCompleteSegments == true ? 160 : 32)).contains(maximumRowsPerSegment),
              wallCapSeconds.isFinite, (1...180).contains(wallCapSeconds),
              footprintCapMiB.isFinite, (256...6_500).contains(footprintCapMiB) else {
            throw TuringQwenNativeError.invalidConfig("Invalid bounded workload schema or limits")
        }
        if decoderOnly {
            guard requireCompleteSegments != true else {
                throw TuringQwenNativeError.invalidConfig("Complete segments require generation and natural EOS, not decoder-only replay")
            }
            guard let codes = decoderCodes, let prefix = decoderReferenceRows,
                  (0...24).contains(prefix), codes.count > prefix,
                  codes.count <= maximumRowsPerSegment + prefix,
                  codes.allSatisfy({ row in row.count == 16 && row.enumerated().allSatisfy {
                      (0..<($0.offset == 0 ? 4096 : 2048)).contains($0.element)
                  } }) else {
                throw TuringQwenNativeError.invalidConfig("Decoder fixture requires valid 16-code rows and explicit prefix")
            }
        } else {
            guard (1...6).contains(segments.count),
                  segments.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 1_024 }) else {
                throw TuringQwenNativeError.invalidConfig("Bounded workload requires 1–6 short segments")
            }
        }
    }

    func validateProductionMaximumRows(_ productionMaximum: Int) throws {
        guard maximumRowsPerSegment <= productionMaximum,
              requireCompleteSegments != true || maximumRowsPerSegment == productionMaximum else {
            throw TuringQwenNativeError.invalidConfig("Complete-segment replay must use the current production row ceiling without truncating it")
        }
    }

    func validateCompletion(reachedEOS: Bool?, generatedRows: Int?) throws {
        guard requireCompleteSegments == true else { return }
        guard reachedEOS == true, let generatedRows, generatedRows > 0,
              generatedRows <= maximumRowsPerSegment else {
            throw TuringQwenNativeError.invalidConfig("Full-length benchmark segment did not finish naturally; missing EOS/row evidence or row-cap termination cannot qualify")
        }
    }

    func validateCompletedSegments(
        pcmIndices: [Int],
        completions: [(segmentIndex: Int, reachedEOS: Bool?, generatedRows: Int?)]
    ) throws {
        guard requireCompleteSegments == true else { return }
        let expected = Array(segments.indices)
        guard pcmIndices.sorted() == expected,
              completions.map(\.segmentIndex).sorted() == expected else {
            throw TuringQwenNativeError.invalidConfig("Full-length benchmark must complete every requested segment exactly once; skipped or missing speech cannot qualify")
        }
        for completion in completions {
            try validateCompletion(reachedEOS: completion.reachedEOS,
                                   generatedRows: completion.generatedRows)
        }
    }

    public var fingerprint: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
        }
    }
}

/// Recorded completion order is distinct from ordered readiness and playback.
public struct TuringQwenPerformancePCMRecord: Codable, Sendable, Equatable {
    public let segmentIndex: Int
    public let readySeconds: Double
    public let sampleCount: Int
    public let sampleRate: Int
    public let pcmSHA256: String
}

public enum TuringQwenPerformanceReadiness {
    public static func ordered(_ records: [TuringQwenPerformancePCMRecord], count: Int) throws -> [Double?] {
        guard count > 0 else { return [] }
        var ready: [Int: Double] = [:]
        for record in records {
            guard (0..<count).contains(record.segmentIndex), ready[record.segmentIndex] == nil,
                  record.readySeconds.isFinite, record.readySeconds >= 0,
                  record.sampleCount > 0, record.sampleRate > 0 else {
                throw TuringQwenNativeError.invalidConfig("Invalid or duplicate PCM readiness record")
            }
            ready[record.segmentIndex] = record.readySeconds
        }
        var prefixMaximum: Double? = 0
        return (0..<count).map { index in
            if let previous = prefixMaximum, let value = ready[index] {
                prefixMaximum = max(previous, value)
            } else { prefixMaximum = nil }
            return prefixMaximum
        }
    }
}
