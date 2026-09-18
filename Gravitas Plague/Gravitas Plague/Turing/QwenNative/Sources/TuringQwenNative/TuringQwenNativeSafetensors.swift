import Foundation
import MLX

struct TuringQwenNativeSafetensorsIndex: Sendable {
    let fileURL: URL
    let dataStartOffset: UInt64
    let tensors: [String: TensorMetadata]
    let fileIdentity: TuringQwenNativeSafetensorsFileIdentity?

    init(fileURL: URL, dataStartOffset: UInt64, tensors: [String: TensorMetadata],
         fileIdentity: TuringQwenNativeSafetensorsFileIdentity? = nil) {
        self.fileURL = fileURL
        self.dataStartOffset = dataStartOffset
        self.tensors = tensors
        self.fileIdentity = fileIdentity
    }

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
        let phaseSpan = TuringQwenNativePhaseDiagnostics.begin("SafetensorsIndexIOCPU")
        defer { TuringQwenNativePhaseDiagnostics.end(phaseSpan) }
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }
        let identity = try TuringQwenNativeSafetensorsFileIdentity.capture(descriptor: handle.fileDescriptor)

        let prefix = try handle.read(upToCount: 8) ?? Data()
        guard prefix.count == 8 else {
            throw TuringQwenNativeError.invalidSafetensors("Missing 8-byte safetensors header length.")
        }

        let headerLength = prefix.withUnsafeBytes {
            UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self))
        }
        guard headerLength > 0,
              headerLength < UInt64(Int.max), identity.byteCount >= 8,
              headerLength <= UInt64(identity.byteCount - 8) else {
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

        guard try TuringQwenNativeSafetensorsFileIdentity.capture(descriptor: handle.fileDescriptor) == identity else {
            throw TuringQwenNativeError.invalidSafetensors("Safetensors file changed while reading the index.")
        }
        return TuringQwenNativeSafetensorsIndex(
            fileURL: url,
            dataStartOffset: 8 + headerLength,
            tensors: tensors,
            fileIdentity: identity
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

struct TuringQwenNativeFloatTensor: Sendable, Equatable {
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

    enum RawDType: Sendable, Equatable {
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

    private enum Storage: Sendable, Equatable {
        case float32Values([Float])
        case rawData(Data, dtype: RawDType)
    }
}

struct TuringQwenNativeSafetensorsReader: Sendable {
    private let index: TuringQwenNativeSafetensorsIndex
    private let positionalFile: TuringQwenNativePositionalSafetensorsFile?

    init(index: TuringQwenNativeSafetensorsIndex) {
        self.index = index
        positionalFile = nil
    }

    init(index: TuringQwenNativeSafetensorsIndex,
         decoderIO: TuringQwenNativeExecutionPolicy.DecoderIO) throws {
        self.index = index
        switch decoderIO {
        case .legacy:
            positionalFile = nil
        case .positionalReaderCandidate:
            guard let identity = index.fileIdentity else {
                throw TuringQwenNativeError.invalidSafetensors("Positional reader requires a file-validated index.")
            }
            positionalFile = try TuringQwenNativePositionalSafetensorsFile(
                url: index.fileURL, expectedIdentity: identity)
            // Validate ranges before allocating any tensor, including unused
            // entries. No weights are loaded or retained by this preflight.
            for (name, metadata) in index.tensors {
                let count = try expectedByteCount(for: metadata, name: name)
                let start = try absoluteOffset(for: metadata.dataOffsets[0])
                guard start <= UInt64(identity.byteCount),
                      UInt64(count) <= UInt64(identity.byteCount) - start else {
                    throw TuringQwenNativeError.invalidSafetensors("Tensor \(name) exceeds the safetensors file.")
                }
            }
        case .budgetedHotSetCandidate:
            throw TuringQwenNativeError.invalidConfig("Budgeted decoder tensor cache is not implemented.")
        }
    }

    func ioCounters() -> TuringQwenNativeSafetensorsIOCounters? {
        positionalFile?.snapshot()
    }

    func loadTensorFloat32(
        name: String
    ) throws -> TuringQwenNativeFloatTensor {
        let phaseSpan = TuringQwenNativePhaseDiagnostics.begin("SafetensorsTensorIOCPU", detail: name)
        defer { TuringQwenNativePhaseDiagnostics.end(phaseSpan) }
        let metadata = try metadata(for: name)
        let byteCount = try expectedByteCount(for: metadata, name: name)
        let start = try absoluteOffset(for: metadata.dataOffsets[0])

        try positionalFile?.validateIdentity()
        positionalFile?.recordRequest(name: name, rows: false)
        let handle = positionalFile == nil ? try FileHandle(forReadingFrom: index.fileURL) : nil
        defer {
            try? handle?.close()
        }

        let data = try readBytes(at: start, count: byteCount, legacyHandle: handle)
        guard data.count == byteCount else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Could not read full tensor \(name). Expected \(byteCount) bytes, got \(data.count)."
            )
        }
        try positionalFile?.validateIdentity()

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
        let phaseSpan = TuringQwenNativePhaseDiagnostics.begin("SafetensorsRowsIOCPU", detail: name)
        defer { TuringQwenNativePhaseDiagnostics.end(phaseSpan) }
        let metadata = try metadata(for: name)
        guard metadata.shape.count == 2 else {
            throw TuringQwenNativeError.invalidSafetensors(
                "Row slicing requires rank-2 tensor \(name), got shape \(metadata.shape)."
            )
        }

        let rowCount = metadata.shape[0]
        let columnCount = metadata.shape[1]
        _ = try expectedByteCount(for: metadata, name: name)
        let bytesPerElement = try bytesPerElement(dtype: metadata.dtype, name: name)
        let (rowByteCount, rowByteOverflow) = columnCount.multipliedReportingOverflow(by: bytesPerElement)
        guard !rowByteOverflow, rows.allSatisfy({ $0 >= 0 && $0 < rowCount }) else {
            throw TuringQwenNativeError.invalidSafetensors("Invalid row selection or row size for \(name).")
        }
        let (resultElementCount, resultOverflow) = rows.count.multipliedReportingOverflow(by: columnCount)
        guard !resultOverflow else {
            throw TuringQwenNativeError.invalidSafetensors("Row selection size overflows for \(name).")
        }
        try positionalFile?.validateIdentity()
        let handle = positionalFile == nil ? try FileHandle(forReadingFrom: index.fileURL) : nil
        defer {
            try? handle?.close()
        }

        var values: [Float] = []
        values.reserveCapacity(resultElementCount)

        for row in rows {
            guard row >= 0,
                  row < rowCount else {
                throw TuringQwenNativeError.invalidSafetensors(
                    "Row \(row) is out of bounds for tensor \(name) with \(rowCount) rows."
                )
            }

            let (relativeRow, rowOverflow) = Int64(row).multipliedReportingOverflow(by: Int64(rowByteCount))
            let (relative, offsetOverflow) = metadata.dataOffsets[0].addingReportingOverflow(relativeRow)
            guard !rowOverflow, !offsetOverflow else {
                throw TuringQwenNativeError.invalidSafetensors("Row offset overflows for \(name).")
            }
            let start = try absoluteOffset(for: relative)

            let data = try readBytes(at: start, count: rowByteCount, legacyHandle: handle)
            guard data.count == rowByteCount else {
                throw TuringQwenNativeError.invalidSafetensors(
                    "Could not read row \(row) from \(name). Expected \(rowByteCount) bytes, got \(data.count)."
                )
            }

            values.append(
                contentsOf: try decodeFloat32(data, dtype: metadata.dtype, name: name)
            )
        }
        try positionalFile?.validateIdentity()
        positionalFile?.recordRequest(name: name, rows: true, convertedElements: values.count)

        return TuringQwenNativeFloatTensor(
            name: name,
            shape: [rows.count, columnCount],
            values: values
        )
    }

    private func readBytes(at offset: UInt64, count: Int, legacyHandle: FileHandle?) throws -> Data {
        if let positionalFile {
            return try positionalFile.readExactly(offset: offset, count: count)
        }
        guard let legacyHandle else {
            throw TuringQwenNativeError.invalidSafetensors("Missing safetensors read owner.")
        }
        try legacyHandle.seek(toOffset: offset)
        return try legacyHandle.read(upToCount: count) ?? Data()
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

        let (offset, overflow) = index.dataStartOffset.addingReportingOverflow(UInt64(relativeOffset))
        guard !overflow, offset <= UInt64(Int64.max) else {
            throw TuringQwenNativeError.invalidSafetensors("Safetensors absolute offset overflows.")
        }
        return offset
    }

    private func expectedByteCount(
        for metadata: TuringQwenNativeSafetensorsIndex.TensorMetadata,
        name: String
    ) throws -> Int {
        guard metadata.dataOffsets.count == 2, metadata.dataOffsets[0] >= 0,
              metadata.dataOffsets[1] >= metadata.dataOffsets[0] else {
            throw TuringQwenNativeError.invalidSafetensors("Invalid offsets for \(name).")
        }
        let elementCount = try metadata.shape.reduce(1) { partial, next in
            guard next >= 0,
                  partial <= Int.max / max(next, 1) else {
                throw TuringQwenNativeError.invalidSafetensors(
                    "Invalid tensor shape for \(name): \(metadata.shape)."
                )
            }

            return partial * next
        }

        let elementBytes = try bytesPerElement(dtype: metadata.dtype, name: name)
        let (expected, overflow) = elementCount.multipliedReportingOverflow(by: elementBytes)
        guard !overflow, metadata.dataOffsets[0].isMultiple(of: Int64(elementBytes)) else {
            throw TuringQwenNativeError.invalidSafetensors("Tensor \(name) has overflowing shape or misaligned offsets.")
        }
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
