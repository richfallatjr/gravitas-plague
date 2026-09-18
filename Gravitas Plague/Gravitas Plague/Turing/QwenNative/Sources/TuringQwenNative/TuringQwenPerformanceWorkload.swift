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

    public func validate(decoderOnly: Bool = false) throws {
        guard schemaVersion == 1, !id.isEmpty, !origin.isEmpty, !voiceID.isEmpty,
              !characterID.isEmpty, !language.isEmpty,
              (1...32).contains(maximumRowsPerSegment),
              wallCapSeconds.isFinite, (1...180).contains(wallCapSeconds),
              footprintCapMiB.isFinite, (256...6_500).contains(footprintCapMiB) else {
            throw TuringQwenNativeError.invalidConfig("Invalid bounded workload schema or limits")
        }
        if decoderOnly {
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
