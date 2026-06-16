import Foundation
import simd

enum CharacterCollisionUnits: String, Codable {
    case meters
    case feet

    var metersScale: Float {
        switch self {
        case .meters:
            return 1.0
        case .feet:
            return 0.3048
        }
    }
}

struct CharacterBodyCollisionAttributes: Codable {
    let enabled: Bool
    let units: CharacterCollisionUnits
    let size: CharacterBodyCollisionSize
    let centerOffset: CharacterBodyCollisionOffset
    let bottomAnchoredToGround: Bool
    let debugVisible: Bool?
    let probes: CharacterBodyCollisionProbeAttributes?

    enum CodingKeys: String, CodingKey {
        case enabled
        case units
        case size
        case centerOffset = "center_offset"
        case bottomAnchoredToGround = "bottom_anchored_to_ground"
        case debugVisible = "debug_visible"
        case probes
    }

    var sizeMeters: SIMD3<Float> {
        SIMD3<Float>(
            size.width * units.metersScale,
            size.height * units.metersScale,
            size.depth * units.metersScale
        )
    }

    var centerOffsetMeters: SIMD3<Float> {
        SIMD3<Float>(
            centerOffset.x * units.metersScale,
            centerOffset.y * units.metersScale,
            centerOffset.z * units.metersScale
        )
    }

    var resolvedCenterOffsetMeters: SIMD3<Float> {
        var offset = centerOffsetMeters

        if bottomAnchoredToGround {
            offset.y += sizeMeters.y * 0.5
        }

        return offset
    }
}

struct CharacterBodyCollisionSize: Codable {
    let width: Float
    let depth: Float
    let height: Float
}

struct CharacterBodyCollisionOffset: Codable {
    let x: Float
    let y: Float
    let z: Float
}

struct CharacterBodyCollisionProbeAttributes: Codable {
    let forwardLength: Float?
    let sideLength: Float?
    let floorDrop: Float?
    let wallClearance: Float?
    let units: CharacterCollisionUnits?

    enum CodingKeys: String, CodingKey {
        case forwardLength = "forward_length"
        case sideLength = "side_length"
        case floorDrop = "floor_drop"
        case wallClearance = "wall_clearance"
        case units
    }

    func scaled(
        _ value: Float?,
        default defaultValue: Float
    ) -> Float {
        let scale = units?.metersScale ?? 1.0
        return (value ?? defaultValue) * scale
    }
}
