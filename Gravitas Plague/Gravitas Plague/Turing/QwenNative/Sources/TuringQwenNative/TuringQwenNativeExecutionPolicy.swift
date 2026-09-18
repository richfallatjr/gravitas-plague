import Foundation
import CryptoKit

/// Backend identity only; never selects lane count, voice, sampling or playback.
public struct TuringQwenNativeExecutionPolicy: Codable, Hashable, Sendable {
    public enum Arithmetic: String, Codable, Sendable { case legacy, legacyWithConversionCache, bf16Candidate }
    public enum Prefill: String, Codable, Sendable { case legacyDense, fusedCausalCandidate }
    public enum Predictor: String, Codable, Sendable { case legacy, cachedStepPlanCandidate, compiledGroupCandidate }
    public enum Workspace: String, Codable, Sendable { case legacy, boundedLaneLocalCandidate }
    public enum DecoderIO: String, Codable, Sendable { case legacy, positionalReaderCandidate, budgetedHotSetCandidate }
    public let policyVersion: Int
    public let arithmetic: Arithmetic
    public let prefill: Prefill
    public let predictor: Predictor
    public let workspace: Workspace
    public let decoderIO: DecoderIO
    public let kernelSet: String
    public let decoderState: String

    public init(arithmetic: Arithmetic = .legacy, prefill: Prefill = .legacyDense,
                predictor: Predictor = .legacy, workspace: Workspace = .legacy,
                decoderIO: DecoderIO = .legacy) {
        policyVersion = 1
        self.arithmetic = arithmetic
        self.prefill = prefill
        self.predictor = predictor
        self.workspace = workspace
        self.decoderIO = decoderIO
        kernelSet = "existing"
        decoderState = "legacy"
    }

    public static let production = Self()
    @TaskLocal public static var current = production

    public func validateImplemented() throws {
        guard policyVersion == 1,
              (arithmetic == .legacy || arithmetic == .legacyWithConversionCache), prefill == .legacyDense,
              predictor == .legacy, workspace == .legacy,
              (decoderIO == .legacy || decoderIO == .positionalReaderCandidate),
              kernelSet == "existing", decoderState == "legacy" else {
            throw TuringQwenNativeError.invalidConfig(
                "Requested backend policy has not been implemented/qualified; no silent fallback is permitted")
        }
    }

    public var fingerprint: String {
        // Explicit stable ordering, independent of JSON dictionary ordering.
        let fields = [String(policyVersion), arithmetic.rawValue, prefill.rawValue,
                      predictor.rawValue, workspace.rawValue, decoderIO.rawValue, kernelSet, decoderState]
        return SHA256.hash(data: Data(fields.joined(separator: "|").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
