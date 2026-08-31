import Foundation
import simd

nonisolated struct Chapter03AngelBlendShapeOffsetPayload: Sendable, Equatable {
    struct Record: Sendable, Equatable {
        let pointIndex: Int
        let basePosition: SIMD3<Float>
        let offset: SIMD3<Float>
    }

    struct Mesh: Sendable, Equatable {
        let sourcePrimPath: String
        let sourcePointCount: Int
        let records: [Record]
    }

    let meshes: [Mesh]

    init(
        data: Data,
        expectedMeshCount: Int,
        expectedRecordCount: Int
    ) throws {
        var reader = Reader(data: data)
        let magic = try reader.readBytes(count: 8)
        guard magic == Data("GRJAWP1\0".utf8) else {
            throw Chapter03AngelBlendShapeError.invalidOffsetPayload("magic")
        }
        guard try reader.readUInt32() == 1 else {
            throw Chapter03AngelBlendShapeError.invalidOffsetPayload("schemaVersion")
        }
        let meshCount = Int(try reader.readUInt32())
        guard meshCount == expectedMeshCount, meshCount > 0 else {
            throw Chapter03AngelBlendShapeError.invalidOffsetPayload("meshCount")
        }

        var decoded: [Mesh] = []
        decoded.reserveCapacity(meshCount)
        var totalRecords = 0
        for _ in 0..<meshCount {
            let pathLength = Int(try reader.readUInt32())
            let sourcePointCount = Int(try reader.readUInt32())
            let recordCount = Int(try reader.readUInt32())
            guard try reader.readUInt32() == 0,
                  pathLength > 0,
                  sourcePointCount > 0,
                  recordCount > 0 else {
                throw Chapter03AngelBlendShapeError.invalidOffsetPayload("meshHeader")
            }
            let pathData = try reader.readBytes(count: pathLength)
            guard let sourcePrimPath = String(data: pathData, encoding: .utf8),
                  sourcePrimPath.hasPrefix("/") else {
                throw Chapter03AngelBlendShapeError.invalidOffsetPayload("sourcePrimPath")
            }
            var records: [Record] = []
            records.reserveCapacity(recordCount)
            var previousIndex = -1
            for _ in 0..<recordCount {
                let pointIndex = Int(try reader.readUInt32())
                let base = try reader.readVector3()
                let offset = try reader.readVector3()
                guard pointIndex > previousIndex,
                      pointIndex < sourcePointCount,
                      base.allFinite,
                      offset.allFinite,
                      simd_length_squared(offset) > 0 else {
                    throw Chapter03AngelBlendShapeError.invalidOffsetPayload("record")
                }
                previousIndex = pointIndex
                records.append(.init(
                    pointIndex: pointIndex,
                    basePosition: base,
                    offset: offset
                ))
            }
            totalRecords += records.count
            decoded.append(.init(
                sourcePrimPath: sourcePrimPath,
                sourcePointCount: sourcePointCount,
                records: records
            ))
        }
        guard reader.isAtEnd, totalRecords == expectedRecordCount else {
            throw Chapter03AngelBlendShapeError.invalidOffsetPayload("length")
        }
        meshes = decoded
    }
}

private nonisolated struct Reader {
    let data: Data
    var cursor = 0

    var isAtEnd: Bool { cursor == data.count }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, cursor <= data.count - count else {
            throw Chapter03AngelBlendShapeError.invalidOffsetPayload("truncated")
        }
        defer { cursor += count }
        return data.subdata(in: cursor..<(cursor + count))
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return bytes.withUnsafeBytes { raw in
            let value = raw.loadUnaligned(as: UInt32.self)
            return UInt32(littleEndian: value)
        }
    }

    mutating func readFloat() throws -> Float {
        Float(bitPattern: try readUInt32())
    }

    mutating func readVector3() throws -> SIMD3<Float> {
        try SIMD3(readFloat(), readFloat(), readFloat())
    }
}

private nonisolated extension SIMD3 where Scalar == Float {
    var allFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}
