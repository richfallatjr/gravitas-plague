import Foundation
import simd

enum PlagueNativeGaussianSplatCompileGate {
    nonisolated static var isCompiled: Bool {
        #if os(visionOS) && !targetEnvironment(simulator)
        if #available(visionOS 27.0, *) {
            return true
        }

        return false
        #else
        return false
        #endif
    }
}

enum PlagueGaussianSplatAvailability {
    nonisolated static func assertNativeAvailable(
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        #if os(visionOS) && !targetEnvironment(simulator)
        guard #available(visionOS 27.0, *) else {
            throw NSError(
                domain: "PlagueGaussianSplatAvailability",
                code: 2700,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Native RealityKit Gaussian splats require a visionOS runtime that exposes GaussianSplatResource and GaussianSplatComponent."
                ]
            )
        }
        #else
        throw NSError(
            domain: "PlagueGaussianSplatAvailability",
            code: 2701,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Native RealityKit Gaussian splat symbols are not compiled into this build. The visionOS simulator SDK in this Xcode seed does not expose GaussianSplatResource/GaussianSplatComponent. compileGate=\(PlagueNativeGaussianSplatCompileGate.isCompiled). No fallback renderer is allowed."
            ]
        )
        #endif
    }

    nonisolated static func assertAvailable() throws {
        try assertNativeAvailable()
    }
}

struct PlagueGaussianSplatCloud: Sendable {
    let sourceURL: URL
    let splatCount: Int

    var positions: [SIMD3<Float>]
    var scales: [SIMD3<Float>]
    var rotations: [simd_quatf]
    var opacities: [Float]
    var sphericalHarmonicsRGB: [SIMD3<Float>]
    var sphericalHarmonicsDegree: Int
    var boundsMin: SIMD3<Float>
    var boundsMax: SIMD3<Float>

    nonisolated var debugDescription: String {
        let opacityMin = opacities.min() ?? 0
        let opacityMax = opacities.max() ?? 0
        let scaleMin = scales.map { min($0.x, min($0.y, $0.z)) }.min() ?? 0
        let scaleMax = scales.map { max($0.x, max($0.y, $0.z)) }.max() ?? 0

        return """
        file: \(sourceURL.lastPathComponent)
        count: \(splatCount)
        shDegree: \(sphericalHarmonicsDegree)
        boundsMin: \(boundsMin)
        boundsMax: \(boundsMax)
        opacityMinMax: \(opacityMin)...\(opacityMax)
        scaleMinMax: \(scaleMin)...\(scaleMax)
        """
    }
}

enum PlaguePLYFormat: String, Sendable {
    case ascii
    case binaryLittleEndian = "binary_little_endian"
    case binaryBigEndian = "binary_big_endian"
}

struct PlaguePLYProperty: Sendable {
    let name: String
    let type: String
    let byteSize: Int
}

struct PlaguePLYHeader: Sendable {
    let format: PlaguePLYFormat
    let vertexCount: Int
    let properties: [PlaguePLYProperty]
    let bodyByteOffset: Int
    let headerText: String
}

enum PlaguePLYType {
    nonisolated static func byteSize(_ type: String) -> Int {
        switch type {
        case "char", "uchar", "int8", "uint8":
            return 1
        case "short", "ushort", "int16", "uint16":
            return 2
        case "int", "uint", "float", "int32", "uint32", "float32":
            return 4
        case "double", "float64":
            return 8
        default:
            return 4
        }
    }
}

enum PlagueGaussianSplatPLYParser {
    nonisolated static func parse(
        url: URL
    ) throws -> PlagueGaussianSplatCloud {
        let data = try Data(contentsOf: url)
        let header = try PlaguePLYHeaderParser.parseHeader(
            data: data,
            sourceURL: url
        )

        switch header.format {
        case .ascii:
            return try parseASCII(
                data: data,
                header: header,
                sourceURL: url
            )

        case .binaryLittleEndian:
            return try parseBinary(
                data: data,
                header: header,
                sourceURL: url,
                littleEndian: true
            )

        case .binaryBigEndian:
            return try parseBinary(
                data: data,
                header: header,
                sourceURL: url,
                littleEndian: false
            )
        }
    }
}

enum PlaguePLYHeaderParser {
    nonisolated static func parseHeader(
        data: Data,
        sourceURL: URL
    ) throws -> PlaguePLYHeader {
        guard data.count >= 16 else {
            throw NSError(
                domain: "PlaguePLYHeaderParser",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "PLY file too small: \(sourceURL.lastPathComponent)"
                ]
            )
        }

        let first16Hex = data.prefix(16)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")

        let first16ASCII = String(
            bytes: data.prefix(16).map { byte in
                byte >= 32 && byte <= 126 ? byte : UInt8(ascii: ".")
            },
            encoding: .ascii
        ) ?? "?"

        guard data[0] == UInt8(ascii: "p"),
              data[1] == UInt8(ascii: "l"),
              data[2] == UInt8(ascii: "y") else {
            throw NSError(
                domain: "PlaguePLYHeaderParser",
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        """
                        Not a raw PLY file.
                          file: \(sourceURL.lastPathComponent)
                          first16Hex: \(first16Hex)
                          first16ASCII: \(first16ASCII)
                        """
                ]
            )
        }

        let marker = Array("end_header".utf8)

        guard let markerStart = findByteSequence(
            data: data,
            sequence: marker
        ) else {
            throw NSError(
                domain: "PlaguePLYHeaderParser",
                code: 3,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "PLY missing end_header: \(sourceURL.lastPathComponent)"
                ]
            )
        }

        var bodyOffset = markerStart + marker.count

        if bodyOffset + 1 < data.count,
           data[bodyOffset] == 13,
           data[bodyOffset + 1] == 10 {
            bodyOffset += 2
        } else if bodyOffset < data.count,
                  data[bodyOffset] == 10 {
            bodyOffset += 1
        } else if bodyOffset < data.count,
                  data[bodyOffset] == 13 {
            bodyOffset += 1
        } else {
            throw NSError(
                domain: "PlaguePLYHeaderParser",
                code: 4,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "PLY end_header is not followed by a newline: \(sourceURL.lastPathComponent)"
                ]
            )
        }

        let headerData = data.subdata(in: 0..<bodyOffset)

        guard let headerText = String(data: headerData, encoding: .ascii)
            ?? String(data: headerData, encoding: .utf8) else {
            throw NSError(
                domain: "PlaguePLYHeaderParser",
                code: 5,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        """
                        PLY header bytes could not decode.
                          file: \(sourceURL.lastPathComponent)
                          headerBytes: \(bodyOffset)
                          first16Hex: \(first16Hex)
                          first16ASCII: \(first16ASCII)
                        """
                ]
            )
        }

        let lines = headerText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map(String.init)

        var format: PlaguePLYFormat?
        var vertexCount: Int?
        var properties: [PlaguePLYProperty] = []
        var inVertexElement = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("comment") else {
                continue
            }

            let tokens = trimmed.split(separator: " ").map(String.init)

            if tokens.count >= 3,
               tokens[0] == "format" {
                switch tokens[1] {
                case "ascii":
                    format = .ascii
                case "binary_little_endian":
                    format = .binaryLittleEndian
                case "binary_big_endian":
                    format = .binaryBigEndian
                default:
                    throw NSError(
                        domain: "PlaguePLYHeaderParser",
                        code: 6,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unsupported PLY format \(tokens[1]) in \(sourceURL.lastPathComponent)"
                        ]
                    )
                }
            }

            if tokens.count >= 3,
               tokens[0] == "element" {
                inVertexElement = tokens[1] == "vertex"

                if inVertexElement {
                    vertexCount = Int(tokens[2])
                }
            }

            if inVertexElement,
               tokens.count >= 3,
               tokens[0] == "property" {
                if tokens[1] == "list" {
                    throw NSError(
                        domain: "PlaguePLYHeaderParser",
                        code: 7,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unsupported list property in vertex element: \(line)"
                        ]
                    )
                }

                let type = tokens[1]
                let name = tokens[2]

                properties.append(
                    PlaguePLYProperty(
                        name: name,
                        type: type,
                        byteSize: PlaguePLYType.byteSize(type)
                    )
                )
            }
        }

        guard let format,
              let vertexCount else {
            throw NSError(
                domain: "PlaguePLYHeaderParser",
                code: 8,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "PLY missing format or vertex count: \(sourceURL.lastPathComponent)"
                ]
            )
        }

        print(
            """
            [PlaguePLYHeaderParser] parsed
              file: \(sourceURL.lastPathComponent)
              format: \(format.rawValue)
              vertexCount: \(vertexCount)
              propertyCount: \(properties.count)
              bodyByteOffset: \(bodyOffset)
              first16Hex: \(first16Hex)
              first16ASCII: \(first16ASCII)
            """
        )

        return PlaguePLYHeader(
            format: format,
            vertexCount: vertexCount,
            properties: properties,
            bodyByteOffset: bodyOffset,
            headerText: headerText
        )
    }

    nonisolated private static func findByteSequence(
        data: Data,
        sequence: [UInt8]
    ) -> Int? {
        guard !sequence.isEmpty,
              data.count >= sequence.count else {
            return nil
        }

        for start in 0...(data.count - sequence.count) {
            var isMatch = true

            for index in 0..<sequence.count where data[start + index] != sequence[index] {
                isMatch = false
                break
            }

            if isMatch {
                return start
            }
        }

        return nil
    }
}

private extension PlagueGaussianSplatPLYParser {

    nonisolated static func parseASCII(
        data: Data,
        header: PlaguePLYHeader,
        sourceURL: URL
    ) throws -> PlagueGaussianSplatCloud {
        let bodyData = data.subdata(in: header.bodyByteOffset..<data.count)

        guard let bodyText = String(data: bodyData, encoding: .utf8)
            ?? String(data: bodyData, encoding: .ascii) else {
            throw NSError(
                domain: "PlaguePLY",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "ASCII PLY body could not decode: \(sourceURL.lastPathComponent)"
                ]
            )
        }

        let body = bodyText
            .split(whereSeparator: \.isNewline)
            .map(String.init)

        var rows: [[String: Float]] = []
        rows.reserveCapacity(header.vertexCount)

        for line in body.prefix(header.vertexCount) {
            let values = line
                .split(separator: " ")
                .compactMap { Float($0) }

            guard values.count >= header.properties.count else {
                continue
            }

            var row: [String: Float] = [:]

            for (index, property) in header.properties.enumerated() {
                row[property.name] = values[index]
            }

            rows.append(row)
        }

        return try buildCloud(
            rows: rows,
            sourceURL: sourceURL
        )
    }

    nonisolated static func parseBinary(
        data: Data,
        header: PlaguePLYHeader,
        sourceURL: URL,
        littleEndian: Bool
    ) throws -> PlagueGaussianSplatCloud {
        guard header.vertexCount > 0 else {
            throw NSError(
                domain: "PlaguePLY",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "PLY has no splat rows."]
            )
        }

        let shDegree = inferSHDegree(properties: header.properties)
        let coeffCount = (shDegree + 1) * (shDegree + 1)

        var positions: [SIMD3<Float>] = []
        var scales: [SIMD3<Float>] = []
        var rotations: [simd_quatf] = []
        var opacities: [Float] = []
        var sphericalHarmonics: [SIMD3<Float>] = []

        positions.reserveCapacity(header.vertexCount)
        scales.reserveCapacity(header.vertexCount)
        rotations.reserveCapacity(header.vertexCount)
        opacities.reserveCapacity(header.vertexCount)
        sphericalHarmonics.reserveCapacity(header.vertexCount * coeffCount)

        var boundsMin = SIMD3<Float>(
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude
        )
        var boundsMax = SIMD3<Float>(
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude
        )

        var offset = header.bodyByteOffset

        for vertexIndex in 0..<header.vertexCount {
            var x: Float = 0
            var y: Float = 0
            var z: Float = 0
            var dc = SIMD3<Float>(0, 0, 0)
            var rest = shDegree >= 3
                ? Array(repeating: Float(0), count: max(45, coeffCount * 3))
                : []
            var opacity: Float?
            var scale0: Float?
            var scale1: Float?
            var scale2: Float?
            var rot0: Float?
            var rot1: Float?
            var rot2: Float?
            var rot3: Float?
            var sx: Float?
            var sy: Float?
            var sz: Float?
            var qx: Float?
            var qy: Float?
            var qz: Float?
            var qw: Float?
            var alpha: Float?
            var red: Float?
            var green: Float?
            var blue: Float?

            for property in header.properties {
                let value = try readScalar(
                    data: data,
                    offset: &offset,
                    type: property.type,
                    littleEndian: littleEndian,
                    file: sourceURL.lastPathComponent,
                    vertexIndex: vertexIndex,
                    propertyName: property.name
                )

                switch property.name {
                case "x":
                    x = value
                case "y":
                    y = value
                case "z":
                    z = value
                case "f_dc_0":
                    dc.x = value
                case "f_dc_1":
                    dc.y = value
                case "f_dc_2":
                    dc.z = value
                case "opacity":
                    opacity = value
                case "alpha":
                    alpha = value
                case "scale_0":
                    scale0 = value
                case "scale_1":
                    scale1 = value
                case "scale_2":
                    scale2 = value
                case "sx":
                    sx = value
                case "sy":
                    sy = value
                case "sz":
                    sz = value
                case "rot_0":
                    rot0 = value
                case "rot_1":
                    rot1 = value
                case "rot_2":
                    rot2 = value
                case "rot_3":
                    rot3 = value
                case "qx":
                    qx = value
                case "qy":
                    qy = value
                case "qz":
                    qz = value
                case "qw":
                    qw = value
                case "red":
                    red = value
                case "green":
                    green = value
                case "blue":
                    blue = value
                default:
                    if property.name.hasPrefix("f_rest_"),
                       let index = Int(property.name.dropFirst("f_rest_".count)),
                       !rest.isEmpty,
                       index < rest.count {
                        rest[index] = value
                    }
                }
            }

            let position = SIMD3<Float>(x, y, z)
            positions.append(position)
            boundsMin = componentMin(boundsMin, position)
            boundsMax = componentMax(boundsMax, position)

            scales.append(
                parseScale(
                    scale0: scale0,
                    scale1: scale1,
                    scale2: scale2,
                    sx: sx,
                    sy: sy,
                    sz: sz
                )
            )
            rotations.append(
                parseRotation(
                    rot0: rot0,
                    rot1: rot1,
                    rot2: rot2,
                    rot3: rot3,
                    qx: qx,
                    qy: qy,
                    qz: qz,
                    qw: qw
                )
            )
            opacities.append(parseOpacity(opacity: opacity, alpha: alpha))
            sphericalHarmonics.append(
                contentsOf: parseSphericalHarmonics(
                    dc: dc,
                    rest: rest,
                    red: red,
                    green: green,
                    blue: blue,
                    degree: shDegree
                )
            )
        }

        print(
            """
            [PlagueGaussianSplatPLYParser] binary body parsed
              file: \(sourceURL.lastPathComponent)
              vertices: \(positions.count)
              finalOffset: \(offset)
              fileSize: \(data.count)
              noFallback: true
            """
        )

        let cloud = PlagueGaussianSplatCloud(
            sourceURL: sourceURL,
            splatCount: header.vertexCount,
            positions: positions,
            scales: scales,
            rotations: rotations,
            opacities: opacities,
            sphericalHarmonicsRGB: sphericalHarmonics,
            sphericalHarmonicsDegree: shDegree,
            boundsMin: boundsMin,
            boundsMax: boundsMax
        )

        print(
            """
            [PlagueGaussianSplatPLYParser] parsed cloud
              file: \(sourceURL.lastPathComponent)
              splats: \(cloud.splatCount)
              shDegree: \(cloud.sphericalHarmonicsDegree)
              coeffCount: \(coeffCount)
              boundsMin: \(cloud.boundsMin)
              boundsMax: \(cloud.boundsMax)
            """
        )

        print(
            """
            [PlagueGaussianSplat] parsed
            \(cloud.debugDescription)
            """
        )

        return cloud
    }

    nonisolated static func readScalar(
        data: Data,
        offset: inout Int,
        type: String,
        littleEndian: Bool,
        file: String,
        vertexIndex: Int,
        propertyName: String
    ) throws -> Float {
        func require(_ count: Int) throws {
            guard offset + count <= data.count else {
                throw NSError(
                    domain: "PlaguePLY",
                    code: 20,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            """
                            Unexpected EOF while reading binary PLY.
                              file: \(file)
                              vertexIndex: \(vertexIndex)
                              property: \(propertyName)
                              type: \(type)
                              offset: \(offset)
                              requestedBytes: \(count)
                              fileSize: \(data.count)
                            """
                    ]
                )
            }
        }

        switch type {
        case "float", "float32":
            try require(4)
            let value: Float = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Float.self)
            }
            offset += 4
            return littleEndian ? value : Float(bitPattern: value.bitPattern.byteSwapped)

        case "double", "float64":
            try require(8)
            let value: Double = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Double.self)
            }
            offset += 8
            let final = littleEndian ? value : Double(bitPattern: value.bitPattern.byteSwapped)
            return Float(final)

        case "uchar", "uint8":
            try require(1)
            let value = data[offset]
            offset += 1
            return Float(value)

        case "char", "int8":
            try require(1)
            let value = Int8(bitPattern: data[offset])
            offset += 1
            return Float(value)

        case "short", "int16":
            try require(2)
            let raw: Int16 = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Int16.self)
            }
            offset += 2
            return Float(littleEndian ? raw : Int16(bitPattern: UInt16(bitPattern: raw).byteSwapped))

        case "ushort", "uint16":
            try require(2)
            let raw: UInt16 = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            }
            offset += 2
            return Float(littleEndian ? raw : raw.byteSwapped)

        case "int", "int32":
            try require(4)
            let raw: Int32 = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: Int32.self)
            }
            offset += 4
            return Float(littleEndian ? raw : Int32(bitPattern: UInt32(bitPattern: raw).byteSwapped))

        case "uint", "uint32":
            try require(4)
            let raw: UInt32 = data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            }
            offset += 4
            return Float(littleEndian ? raw : raw.byteSwapped)

        default:
            throw NSError(
                domain: "PlaguePLY",
                code: 21,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        """
                        Unsupported binary PLY scalar type \(type).
                          file: \(file)
                          vertexIndex: \(vertexIndex)
                          property: \(propertyName)
                          offset: \(offset)
                        """
                ]
            )
        }
    }
}

private extension PlagueGaussianSplatPLYParser {
    nonisolated static func buildCloud(
        rows: [[String: Float]],
        sourceURL: URL
    ) throws -> PlagueGaussianSplatCloud {
        guard !rows.isEmpty else {
            throw NSError(
                domain: "PlaguePLY",
                code: 30,
                userInfo: [NSLocalizedDescriptionKey: "PLY has no splat rows."]
            )
        }

        var positions: [SIMD3<Float>] = []
        var scales: [SIMD3<Float>] = []
        var rotations: [simd_quatf] = []
        var opacities: [Float] = []

        let shDegree = inferSHDegree(row: rows[0])
        let coeffCount = (shDegree + 1) * (shDegree + 1)
        var sphericalHarmonics: [SIMD3<Float>] = []

        positions.reserveCapacity(rows.count)
        scales.reserveCapacity(rows.count)
        rotations.reserveCapacity(rows.count)
        opacities.reserveCapacity(rows.count)
        sphericalHarmonics.reserveCapacity(rows.count * coeffCount)

        var boundsMin = SIMD3<Float>(
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude,
            Float.greatestFiniteMagnitude
        )
        var boundsMax = SIMD3<Float>(
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude,
            -Float.greatestFiniteMagnitude
        )

        for row in rows {
            let p = SIMD3<Float>(
                row["x"] ?? 0,
                row["y"] ?? 0,
                row["z"] ?? 0
            )

            positions.append(p)
            boundsMin = componentMin(boundsMin, p)
            boundsMax = componentMax(boundsMax, p)

            scales.append(parseScale(row))
            rotations.append(parseRotation(row))
            opacities.append(parseOpacity(row))

            sphericalHarmonics.append(
                contentsOf: parseSphericalHarmonics(
                    row,
                    degree: shDegree
                )
            )
        }

        let cloud = PlagueGaussianSplatCloud(
            sourceURL: sourceURL,
            splatCount: rows.count,
            positions: positions,
            scales: scales,
            rotations: rotations,
            opacities: opacities,
            sphericalHarmonicsRGB: sphericalHarmonics,
            sphericalHarmonicsDegree: shDegree,
            boundsMin: boundsMin,
            boundsMax: boundsMax
        )

        print(
            """
            [PlagueGaussianSplatPLYParser] parsed cloud
              file: \(sourceURL.lastPathComponent)
              splats: \(rows.count)
              shDegree: \(shDegree)
              coeffCount: \(coeffCount)
              boundsMin: \(boundsMin)
              boundsMax: \(boundsMax)
            """
        )

        print(
            """
            [PlagueGaussianSplat] parsed
            \(cloud.debugDescription)
            """
        )

        return cloud
    }

    nonisolated static func parseScale(
        _ row: [String: Float]
    ) -> SIMD3<Float> {
        parseScale(
            scale0: row["scale_0"],
            scale1: row["scale_1"],
            scale2: row["scale_2"],
            sx: row["sx"],
            sy: row["sy"],
            sz: row["sz"]
        )
    }

    nonisolated static func parseScale(
        scale0: Float?,
        scale1: Float?,
        scale2: Float?,
        sx: Float?,
        sy: Float?,
        sz: Float?
    ) -> SIMD3<Float> {
        if let scale0,
           let scale1,
           let scale2 {
            return SIMD3<Float>(
                exp(scale0),
                exp(scale1),
                exp(scale2)
            )
        }

        if let sx,
           let sy,
           let sz {
            return SIMD3<Float>(sx, sy, sz)
        }

        return SIMD3<Float>(0.01, 0.01, 0.01)
    }

    nonisolated static func parseRotation(
        _ row: [String: Float]
    ) -> simd_quatf {
        parseRotation(
            rot0: row["rot_0"],
            rot1: row["rot_1"],
            rot2: row["rot_2"],
            rot3: row["rot_3"],
            qx: row["qx"],
            qy: row["qy"],
            qz: row["qz"],
            qw: row["qw"]
        )
    }

    nonisolated static func parseRotation(
        rot0: Float?,
        rot1: Float?,
        rot2: Float?,
        rot3: Float?,
        qx: Float?,
        qy: Float?,
        qz: Float?,
        qw: Float?
    ) -> simd_quatf {
        if let rot0,
           let rot1,
           let rot2,
           let rot3 {
            return simd_normalize(
                simd_quatf(
                    vector: SIMD4<Float>(
                        rot1,
                        rot2,
                        rot3,
                        rot0
                    )
                )
            )
        }

        if let qx,
           let qy,
           let qz,
           let qw {
            return simd_normalize(
                simd_quatf(vector: SIMD4<Float>(qx, qy, qz, qw))
            )
        }

        return simd_quatf(
            angle: 0,
            axis: SIMD3<Float>(0, 1, 0)
        )
    }

    nonisolated static func parseOpacity(
        _ row: [String: Float]
    ) -> Float {
        parseOpacity(
            opacity: row["opacity"],
            alpha: row["alpha"]
        )
    }

    nonisolated static func parseOpacity(
        opacity: Float?,
        alpha: Float?
    ) -> Float {
        if let opacity {
            return sigmoid(opacity)
        }

        if let alpha {
            return max(0, min(1, alpha))
        }

        return 1
    }

    nonisolated static func sigmoid(_ x: Float) -> Float {
        1.0 / (1.0 + exp(-x))
    }
}

private extension PlagueGaussianSplatPLYParser {
    nonisolated static func inferSHDegree(
        properties: [PlaguePLYProperty]
    ) -> Int {
        let restCount = properties.filter {
            $0.name.hasPrefix("f_rest_")
        }.count

        if restCount >= 45 {
            return 3
        }

        return 0
    }

    nonisolated static func inferSHDegree(
        row: [String: Float]
    ) -> Int {
        let restCount = row.keys.filter {
            $0.hasPrefix("f_rest_")
        }.count

        if restCount >= 45 {
            return 3
        }

        return 0
    }

    nonisolated static func parseSphericalHarmonics(
        _ row: [String: Float],
        degree: Int
    ) -> [SIMD3<Float>] {
        let rest = (0..<45).map { index in
            row["f_rest_\(index)"] ?? 0
        }

        return parseSphericalHarmonics(
            dc: SIMD3<Float>(
                row["f_dc_0"] ?? row["red"] ?? 0,
                row["f_dc_1"] ?? row["green"] ?? 0,
                row["f_dc_2"] ?? row["blue"] ?? 0
            ),
            rest: rest,
            red: row["red"],
            green: row["green"],
            blue: row["blue"],
            degree: degree
        )
    }

    nonisolated static func parseSphericalHarmonics(
        dc: SIMD3<Float>,
        rest: [Float],
        red: Float?,
        green: Float?,
        blue: Float?,
        degree: Int
    ) -> [SIMD3<Float>] {
        let coeffCount = (degree + 1) * (degree + 1)

        var coefficients = Array(
            repeating: SIMD3<Float>(0, 0, 0),
            count: coeffCount
        )

        coefficients[0] = SIMD3<Float>(
            red ?? dc.x,
            green ?? dc.y,
            blue ?? dc.z
        )

        guard degree >= 3 else {
            return coefficients
        }

        for i in 0..<15 {
            coefficients[i + 1] = SIMD3<Float>(
                rest.indices.contains(i) ? rest[i] : 0,
                rest.indices.contains(15 + i) ? rest[15 + i] : 0,
                rest.indices.contains(30 + i) ? rest[30 + i] : 0
            )
        }

        return coefficients
    }

    nonisolated static func componentMin(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            min(lhs.x, rhs.x),
            min(lhs.y, rhs.y),
            min(lhs.z, rhs.z)
        )
    }

    nonisolated static func componentMax(
        _ lhs: SIMD3<Float>,
        _ rhs: SIMD3<Float>
    ) -> SIMD3<Float> {
        SIMD3<Float>(
            max(lhs.x, rhs.x),
            max(lhs.y, rhs.y),
            max(lhs.z, rhs.z)
        )
    }
}
