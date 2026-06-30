import Foundation

struct TuringQwenNativeSafetensorsIndex: Sendable {
    let tensors: [String: TensorMetadata]

    struct TensorMetadata: Decodable, Sendable {
        let dtype: String
        let shape: [Int]
        let dataOffsets: [Int64]

        enum CodingKeys: String, CodingKey {
            case dtype
            case shape
            case dataOffsets = "data_offsets"
        }
    }

    static func load(from url: URL) throws -> TuringQwenNativeSafetensorsIndex {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let prefix = try handle.read(upToCount: 8) ?? Data()
        guard prefix.count == 8 else {
            throw TuringQwenNativeError.invalidSafetensors("Missing 8-byte safetensors header length.")
        }

        let headerLength = prefix.withUnsafeBytes {
            $0.loadUnaligned(as: UInt64.self)
        }
        guard headerLength > 0,
              headerLength < UInt64(Int.max) else {
            throw TuringQwenNativeError.invalidSafetensors("Invalid safetensors header length \(headerLength).")
        }

        let header = try handle.read(upToCount: Int(headerLength)) ?? Data()
        guard header.count == Int(headerLength) else {
            throw TuringQwenNativeError.invalidSafetensors("Could not read complete safetensors header.")
        }

        let raw = try JSONDecoder().decode([String: RawTensorMetadata].self, from: header)
        var tensors: [String: TensorMetadata] = [:]

        for (name, value) in raw where name != "__metadata__" {
            guard let dtype = value.dtype,
                  let shape = value.shape,
                  let offsets = value.dataOffsets,
                  offsets.count == 2,
                  offsets[0] >= 0,
                  offsets[1] >= offsets[0] else {
                throw TuringQwenNativeError.invalidSafetensors("Invalid tensor metadata for \(name).")
            }

            tensors[name] = TensorMetadata(
                dtype: dtype,
                shape: shape,
                dataOffsets: offsets
            )
        }

        return TuringQwenNativeSafetensorsIndex(tensors: tensors)
    }

    func requireAny(prefixes: [String]) throws {
        for prefix in prefixes where tensors.keys.contains(where: { $0.hasPrefix(prefix) }) {
            return
        }

        throw TuringQwenNativeError.invalidSafetensors(
            "Missing tensor matching any prefix: \(prefixes.joined(separator: ", "))"
        )
    }

    private struct RawTensorMetadata: Decodable {
        let dtype: String?
        let shape: [Int]?
        let dataOffsets: [Int64]?

        enum CodingKeys: String, CodingKey {
            case dtype
            case shape
            case dataOffsets = "data_offsets"
        }
    }
}
