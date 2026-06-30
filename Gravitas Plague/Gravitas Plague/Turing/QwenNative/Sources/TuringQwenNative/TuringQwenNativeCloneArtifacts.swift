import Foundation
import CryptoKit

public struct TuringQwenNativeCloneArtifacts: Sendable {
    public let voiceID: String
    public let variantID: String
    public let xVectorOnlyMode: Bool
    public let language: String
    public let refTextTokens: [Int32]
    public let referenceCodes: [[Int32]]
    public let speakerEmbedding: [Float]
    public let referenceRowCount: Int
    public let codebookCount: Int
    public let referenceDurationSeconds: Double
}

public struct TuringQwenNativeCloneArtifactsLoader: Sendable {
    public init() {}

    public func load(
        from variant: TuringQwenNativeCloneProfile.Variant
    ) throws -> TuringQwenNativeCloneArtifacts {
        let artifactsRoot = variant.rootURL.appendingPathComponent("qwen_artifacts", isDirectory: true)
        let manifestURL = artifactsRoot.appendingPathComponent("clone_prompt_manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Missing Big Mike Qwen clone artifacts. Run Scripts/precompute_big_mike_qwenclone.sh."
            )
        }

        let manifest = try JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.isBaseCloneICL,
              manifest.xVectorOnlyMode == false else {
            throw TuringQwenNativeError.invalidConfig(
                "Big Mike clone artifacts must be baseCloneICL with xVectorOnlyMode false."
            )
        }
        guard manifest.voiceID == "big_mike_base_clone_v1",
              manifest.variantID == variant.variantID else {
            throw TuringQwenNativeError.invalidConfig(
                "Clone artifact manifest does not match requested variant \(variant.variantID)."
            )
        }

        let checksums = try loadChecksums(
            artifactsRoot.appendingPathComponent("checksums.sha256")
        )
        let refTextTokenSpec = try manifest.resolvedRefTextTokens(checksums: checksums)
        let referenceCodeSpec = try manifest.resolvedReferenceCodes(checksums: checksums)
        let speakerEmbeddingSpec = try manifest.resolvedSpeakerEmbedding(checksums: checksums)

        guard referenceCodeSpec.codebookCount == 16,
              referenceCodeSpec.shape.count == 2,
              referenceCodeSpec.shape[1] == 16,
              referenceCodeSpec.shape[0] > 0 else {
            throw TuringQwenNativeError.invalidConfig(
                "Clone artifact reference_codes must have non-empty [rows, 16] shape."
            )
        }

        let refTextTokens = try readInt32Vector(
            artifactsRoot.appendingPathComponent(refTextTokenSpec.path),
            expectedShape: refTextTokenSpec.shape,
            sha256: refTextTokenSpec.sha256
        )
        let flatReferenceCodes = try readInt32Vector(
            artifactsRoot.appendingPathComponent(referenceCodeSpec.path),
            expectedShape: referenceCodeSpec.shape,
            sha256: referenceCodeSpec.sha256
        )
        let speakerEmbedding = try readFloatVector(
            artifactsRoot.appendingPathComponent(speakerEmbeddingSpec.path),
            expectedShape: speakerEmbeddingSpec.shape,
            sha256: speakerEmbeddingSpec.sha256
        )

        let referenceRows = referenceCodeSpec.shape[0]
        let codebookCount = referenceCodeSpec.shape[1]
        var rows: [[Int32]] = []
        rows.reserveCapacity(referenceRows)
        for row in 0..<referenceRows {
            let start = row * codebookCount
            rows.append(Array(flatReferenceCodes[start..<(start + codebookCount)]))
        }

        guard refTextTokens.isEmpty == false else {
            throw TuringQwenNativeError.invalidConfig("Clone artifact ref_text_tokens is empty.")
        }
        guard speakerEmbedding.isEmpty == false else {
            throw TuringQwenNativeError.invalidConfig("Clone artifact speaker_embedding is empty.")
        }

        return TuringQwenNativeCloneArtifacts(
            voiceID: manifest.voiceID,
            variantID: manifest.variantID,
            xVectorOnlyMode: manifest.xVectorOnlyMode,
            language: manifest.language,
            refTextTokens: refTextTokens,
            referenceCodes: rows,
            speakerEmbedding: speakerEmbedding,
            referenceRowCount: referenceRows,
            codebookCount: codebookCount,
            referenceDurationSeconds: manifest.referenceDurationSeconds ?? 0
        )
    }

    private func loadChecksums(_ url: URL) throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        var checksums: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            checksums[String(parts[1])] = String(parts[0])
        }
        return checksums
    }

    private func readInt32Vector(
        _ url: URL,
        expectedShape: [Int],
        sha256: String
    ) throws -> [Int32] {
        let data = try readCheckedData(url, sha256: sha256)
        guard data.count.isMultiple(of: MemoryLayout<Int32>.size) else {
            throw TuringQwenNativeError.invalidConfig("\(url.lastPathComponent) is not aligned as i32le.")
        }
        let expectedCount = try expectedElementCount(expectedShape, label: url.lastPathComponent)
        let values = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int32.self))
        }
        guard values.count == expectedCount else {
            throw TuringQwenNativeError.invalidConfig(
                "\(url.lastPathComponent) expected \(expectedCount) Int32 values, got \(values.count)."
            )
        }
        return values
    }

    private func readFloatVector(
        _ url: URL,
        expectedShape: [Int],
        sha256: String
    ) throws -> [Float] {
        let data = try readCheckedData(url, sha256: sha256)
        guard data.count.isMultiple(of: MemoryLayout<Float>.size) else {
            throw TuringQwenNativeError.invalidConfig("\(url.lastPathComponent) is not aligned as f32le.")
        }
        let expectedCount = try expectedElementCount(expectedShape, label: url.lastPathComponent)
        let values = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        guard values.count == expectedCount else {
            throw TuringQwenNativeError.invalidConfig(
                "\(url.lastPathComponent) expected \(expectedCount) Float values, got \(values.count)."
            )
        }
        return values
    }

    private func readCheckedData(
        _ url: URL,
        sha256: String
    ) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TuringQwenNativeError.missingModelFile(url.path)
        }
        let data = try Data(contentsOf: url)
        guard data.isEmpty == false else {
            throw TuringQwenNativeError.invalidConfig("\(url.lastPathComponent) is empty.")
        }
        guard sha256.isEmpty || data.turingSHA256Hex == sha256 else {
            throw TuringQwenNativeError.invalidConfig(
                "\(url.lastPathComponent) checksum mismatch."
            )
        }
        return data
    }

    private func expectedElementCount(
        _ shape: [Int],
        label: String
    ) throws -> Int {
        guard shape.isEmpty == false else {
            throw TuringQwenNativeError.invalidConfig("\(label) has empty shape metadata.")
        }
        return try shape.reduce(1) { partial, next in
            guard next > 0,
                  partial <= Int.max / next else {
                throw TuringQwenNativeError.invalidConfig("Invalid shape \(shape) for \(label).")
            }
            return partial * next
        }
    }

    private struct Manifest: Decodable {
        let voiceID: String
        let variantID: String
        let runtimeMode: String?
        let mode: String?
        let xVectorOnlyMode: Bool
        let language: String
        let referenceDurationSeconds: Double?
        let refTextTokens: Tensor?
        let referenceCodes: ReferenceCodes?
        let speakerEmbedding: Tensor?
        let artifacts: ArtifactBundle?

        var isBaseCloneICL: Bool {
            runtimeMode == "baseCloneICL" || mode == "icl"
        }

        func resolvedRefTextTokens(checksums: [String: String]) throws -> Tensor {
            if let refTextTokens {
                return refTextTokens
            }
            guard let artifacts else {
                throw TuringQwenNativeError.invalidConfig("Clone artifact manifest missing ref_text_tokens metadata.")
            }
            return Tensor(
                path: artifacts.refTextTokens,
                dtype: artifacts.refTextTokensDType,
                shape: artifacts.refTextTokensShape,
                sha256: checksums[artifacts.refTextTokens] ?? ""
            )
        }

        func resolvedReferenceCodes(checksums: [String: String]) throws -> ReferenceCodes {
            if let referenceCodes {
                return referenceCodes
            }
            guard let artifacts else {
                throw TuringQwenNativeError.invalidConfig("Clone artifact manifest missing reference_codes metadata.")
            }
            guard artifacts.referenceCodesShape.count == 2 else {
                throw TuringQwenNativeError.invalidConfig("Clone artifact reference_codes shape must be [rows, codebooks].")
            }
            return ReferenceCodes(
                path: artifacts.referenceCodes,
                dtype: artifacts.referenceCodesDType,
                shape: artifacts.referenceCodesShape,
                layout: "rows_codebooks",
                codebookCount: artifacts.referenceCodesShape[1],
                sha256: checksums[artifacts.referenceCodes] ?? ""
            )
        }

        func resolvedSpeakerEmbedding(checksums: [String: String]) throws -> Tensor {
            if let speakerEmbedding {
                return speakerEmbedding
            }
            guard let artifacts else {
                throw TuringQwenNativeError.invalidConfig("Clone artifact manifest missing speaker_embedding metadata.")
            }
            return Tensor(
                path: artifacts.speakerEmbedding,
                dtype: artifacts.speakerEmbeddingDType,
                shape: artifacts.speakerEmbeddingShape,
                sha256: checksums[artifacts.speakerEmbedding] ?? ""
            )
        }
    }

    private struct ArtifactBundle: Decodable {
        let refTextTokens: String
        let refTextTokensDType: String
        let refTextTokensShape: [Int]
        let referenceCodes: String
        let referenceCodesDType: String
        let referenceCodesShape: [Int]
        let speakerEmbedding: String
        let speakerEmbeddingDType: String
        let speakerEmbeddingShape: [Int]
    }

    private struct Tensor: Decodable {
        let path: String
        let dtype: String
        let shape: [Int]
        let sha256: String
    }

    private struct ReferenceCodes: Decodable {
        let path: String
        let dtype: String
        let shape: [Int]
        let layout: String?
        let codebookCount: Int
        let sha256: String
    }
}

private extension Data {
    var turingSHA256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}
