import Foundation
import MLX

struct TuringQwenNativeSafetensorsIndex: Sendable {
    let fileURL: URL
    let dataStartOffset: UInt64
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

        return TuringQwenNativeSafetensorsIndex(
            fileURL: url,
            dataStartOffset: 8 + headerLength,
            tensors: tensors
        )
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

struct TuringQwenNativeFloatTensor: Sendable {
    let name: String
    let shape: [Int]
    private let storage: Storage

    init(
        name: String,
        shape: [Int],
        values: [Float]
    ) {
        self.name = name
        self.shape = shape
        self.storage = .float32Values(values)
    }

    init(
        name: String,
        shape: [Int],
        rawData: Data,
        dtype: RawDType
    ) {
        self.name = name
        self.shape = shape
        self.storage = .rawData(rawData, dtype: dtype)
    }

    enum RawDType: Sendable {
        case bfloat16
        case float32

        var mlxDType: DType {
            switch self {
            case .bfloat16:
                return .bfloat16
            case .float32:
                return .float32
            }
        }
    }

    private enum Storage: Sendable {
        case float32Values([Float])
        case rawData(Data, dtype: RawDType)
    }
}

struct TuringQwenNativeSafetensorsReader: Sendable {
    private let index: TuringQwenNativeSafetensorsIndex

    init(index: TuringQwenNativeSafetensorsIndex) {
        self.index = index
    }

    func loadTensorFloat32(
        name: String
    ) throws -> TuringQwenNativeFloatTensor {
        let metadata = try metadata(for: name)
        let byteCount = try expectedByteCount(for: metadata, name: name)
        let start = try absoluteOffset(for: metadata.dataOffsets[0])

        let handle = try FileHandle(forReadingFrom: index.fileURL)
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: start)
        let data = try handle.read(upToCount: byteCount) ?? Data()
        guard data.count == byteCount else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Could not read full tensor \(name). Expected \(byteCount) bytes, got \(data.count)."
            )
        }

        return TuringQwenNativeFloatTensor(
            name: name,
            shape: metadata.shape,
            rawData: data,
            dtype: try rawDType(for: metadata.dtype, name: name)
        )
    }

    func loadRowsFloat32(
        name: String,
        rows: [Int]
    ) throws -> TuringQwenNativeFloatTensor {
        let metadata = try metadata(for: name)
        guard metadata.shape.count == 2 else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Row slicing requires rank-2 tensor \(name), got shape \(metadata.shape)."
            )
        }

        let rowCount = metadata.shape[0]
        let columnCount = metadata.shape[1]
        let bytesPerElement = try bytesPerElement(dtype: metadata.dtype, name: name)
        let rowByteCount = columnCount * bytesPerElement

        let handle = try FileHandle(forReadingFrom: index.fileURL)
        defer {
            try? handle.close()
        }

        var values: [Float] = []
        values.reserveCapacity(rows.count * columnCount)

        for row in rows {
            guard row >= 0,
                  row < rowCount else {
                throw TuringQwenNativeError.invalidSafetensors(
                    "Row \(row) is out of bounds for tensor \(name) with \(rowCount) rows."
                )
            }

            let relative = metadata.dataOffsets[0] +
                Int64(row) * Int64(rowByteCount)
            let start = try absoluteOffset(for: relative)

            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: rowByteCount) ?? Data()
            guard data.count == rowByteCount else {
                throw TuringQwenNativeError.invalidSafetensors(
                    "Could not read row \(row) from \(name). Expected \(rowByteCount) bytes, got \(data.count)."
                )
            }

            values.append(
                contentsOf: try decodeFloat32(data, dtype: metadata.dtype, name: name)
            )
        }

        return TuringQwenNativeFloatTensor(
            name: name,
            shape: [rows.count, columnCount],
            values: values
        )
    }

    private func metadata(
        for name: String
    ) throws -> TuringQwenNativeSafetensorsIndex.TensorMetadata {
        guard let metadata = index.tensors[name] else {
            throw TuringQwenNativeError.invalidSafetensors("Missing tensor \(name).")
        }

        return metadata
    }

    private func absoluteOffset(
        for relativeOffset: Int64
    ) throws -> UInt64 {
        guard relativeOffset >= 0 else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Negative tensor data offset \(relativeOffset)."
            )
        }

        return index.dataStartOffset + UInt64(relativeOffset)
    }

    private func expectedByteCount(
        for metadata: TuringQwenNativeSafetensorsIndex.TensorMetadata,
        name: String
    ) throws -> Int {
        let elementCount = try metadata.shape.reduce(1) { partial, next in
            guard next >= 0,
                  partial <= Int.max / max(next, 1) else {
                throw TuringQwenNativeError.invalidSafetensors(
                    "Invalid tensor shape for \(name): \(metadata.shape)."
                )
            }

            return partial * next
        }

        let expected = elementCount * (try bytesPerElement(dtype: metadata.dtype, name: name))
        let actual = metadata.dataOffsets[1] - metadata.dataOffsets[0]
        guard actual == Int64(expected) else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Tensor \(name) byte count mismatch. Metadata \(actual), expected \(expected)."
            )
        }

        return expected
    }

    private func bytesPerElement(
        dtype: String,
        name: String
    ) throws -> Int {
        switch dtype {
        case "BF16":
            return 2
        case "F32":
            return 4
        default:
            throw TuringQwenNativeError.invalidSafetensors(
                "Unsupported tensor dtype \(dtype) for \(name)."
            )
        }
    }

    private func rawDType(
        for dtype: String,
        name: String
    ) throws -> TuringQwenNativeFloatTensor.RawDType {
        switch dtype {
        case "BF16":
            return .bfloat16
        case "F32":
            return .float32
        default:
            throw TuringQwenNativeError.invalidSafetensors(
                "Unsupported tensor dtype \(dtype) for \(name)."
            )
        }
    }

    private func decodeFloat32(
        _ data: Data,
        dtype: String,
        name: String
    ) throws -> [Float] {
        switch dtype {
        case "BF16":
            guard data.count.isMultiple(of: 2) else {
                throw TuringQwenNativeError.invalidSafetensors(
                    "BF16 tensor \(name) has odd byte count \(data.count)."
                )
            }

            var values: [Float] = []
            values.reserveCapacity(data.count / 2)
            data.withUnsafeBytes { raw in
                for offset in stride(from: 0, to: data.count, by: 2) {
                    let word = UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                    values.append(Float(bitPattern: UInt32(word) << 16))
                }
            }
            return values

        case "F32":
            guard data.count.isMultiple(of: 4) else {
                throw TuringQwenNativeError.invalidSafetensors(
                    "F32 tensor \(name) byte count is not divisible by 4: \(data.count)."
                )
            }

            var values: [Float] = []
            values.reserveCapacity(data.count / 4)
            data.withUnsafeBytes { raw in
                for offset in stride(from: 0, to: data.count, by: 4) {
                    let word = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                    values.append(Float(bitPattern: word))
                }
            }
            return values

        default:
            throw TuringQwenNativeError.invalidSafetensors(
                "Unsupported tensor dtype \(dtype) for \(name)."
            )
        }
    }
}

extension TuringQwenNativeFloatTensor {
    func mlxArray() -> MLXArray {
        switch storage {
        case .float32Values(let values):
            return MLXArray(values, shape)
        case .rawData(let data, let dtype):
            return MLXArray(data, shape, dtype: dtype.mlxDType)
        }
    }
}
