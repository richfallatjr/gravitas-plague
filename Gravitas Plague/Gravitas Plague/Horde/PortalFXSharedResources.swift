import RealityKit
import simd
import UIKit

enum PortalFXDefaults {
    /// Was 0.022. New value is exactly 1/4 thickness.
    static let tubeRadiusMeters: Float = 0.0055

    /// Joint bead also reduced to stay proportional.
    static let tubeJointRadiusMeters: Float = 0.0075

    /// Blood-red material emissive intensity. Bloom remains installed separately.
    static let tubeEmissiveIntensity: Float = 0.6
    static let bloomTargetStrength: Float = 1.0

    /// Was 1000/sec. Current pass halves prior 60/sec density.
    static let emberBirthRatePerDoor: Float = 30.0

    /// Still visually travels around 2-3 feet, but slower and more varied.
    static let emberTravelDistanceFeet: Float = 2.25
    static let emberTravelDistanceMeters: Float = emberTravelDistanceFeet * 0.3048

    /// Was around 1.1. Longer life for slower drift.
    static let emberLifeSecondsMin: Float = 1.45
    static let emberLifeSecondsMax: Float = 2.35

    /// About half previous speed, with variance.
    static let emberSpeedMetersPerSecondMin: Float = 0.22
    static let emberSpeedMetersPerSecondMax: Float = 0.44

    /// Continuous per-ember extra speed amount.
    ///
    /// 0.0 means baseline/current authored ember speed.
    /// 1.0 means 100% extra speed, so final speed is 2x baseline.
    ///
    /// Final multiplier is:
    ///     1.0 + random(0.0...1.0)
    static let emberSpeedExtraAmountMin: Float = 0.0
    static let emberSpeedExtraAmountMax: Float = 1.0

    /// Launch-direction side jitter along the portal segment tangent.
    static let emberTangentJitterMin: Float = -0.75
    static let emberTangentJitterMax: Float = 0.75

    /// Protect bottom/floor embers from excessive sideways spray.
    static let bottomEmberTangentScale: Float = 0.30

    /// Ongoing side acceleration in meters / second^2.
    static let emberSideAccelerationMetersPerSecond2: Float = 0.14

    static let emberStartSizeMetersMin: Float = 0.0045
    static let emberStartSizeMetersMax: Float = 0.010
    static let emberEndSizeMetersMin: Float = 0.0018
    static let emberEndSizeMetersMax: Float = 0.0045

    /// More active pool headroom because lifespan is longer.
    static let emberMaxActiveMultiplier: Float = 2.6

    /// Bottom edge is allowed only as upward licking embers.
    static let bottomSegmentBirthRateMultiplier: Float = 0.10

    /// Crucial: embers move in wall plane. Z should be tiny.
    static let maxNormalVelocityLeak: Float = 0.015

    static let portalLocalOutwardNormal = SIMD3<Float>(0, 0, 1)
    static let portalLocalUp = SIMD3<Float>(0, 1, 0)
}

enum PortalFXPalette {
    /// ~357 degrees: blood red, nearly saturated, one stop down from 0.58 value.
    static let bloodRedHue: CGFloat = 357.0 / 360.0
    static let bloodRedSaturation: CGFloat = 0.98
    static let bloodRedBrightness: CGFloat = 0.29

    static let bloodRedUIColor = UIColor(
        hue: bloodRedHue,
        saturation: bloodRedSaturation,
        brightness: bloodRedBrightness,
        alpha: 1.0
    )

    static let bloodRedSIMD = SIMD3<Float>(0.29, 0.006, 0.020)

    static let emberBirth = UIColor(
        red: 1.00,
        green: 0.92,
        blue: 0.48,
        alpha: 1.0
    )

    static let emberHot = UIColor(
        red: 1.00,
        green: 0.44,
        blue: 0.06,
        alpha: 1.0
    )

    static let emberRed = UIColor(
        red: 0.82,
        green: 0.08,
        blue: 0.015,
        alpha: 1.0
    )

    static let emberDark = UIColor(
        red: 0.28,
        green: 0.015,
        blue: 0.005,
        alpha: 0.0
    )

    /// Uses fixed blood-red hue/saturation/value while preserving source alpha.
    static func bloodRedPreservingAlpha(
        _ color: UIColor
    ) -> UIColor {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = bloodRedBrightness
        var alpha: CGFloat = 1

        _ = color.getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        )

        return UIColor(
            hue: bloodRedHue,
            saturation: bloodRedSaturation,
            brightness: bloodRedBrightness,
            alpha: alpha
        )
    }
}

@MainActor
final class PortalFXSharedResources {
    static let shared = PortalFXSharedResources()

    let tubeMaterial: RealityKit.Material
    let jointMaterial: RealityKit.Material

    let emberBirthMaterials: [RealityKit.Material]
    let emberHotMaterials: [RealityKit.Material]
    let emberRedMaterials: [RealityKit.Material]
    let emberDarkMaterials: [RealityKit.Material]

    let emberMesh: MeshResource

    private init() {
        tubeMaterial = Self.makeEmissiveMaterial(
            base: PortalFXPalette.bloodRedUIColor,
            emissive: PortalFXPalette.bloodRedUIColor,
            intensity: PortalFXDefaults.tubeEmissiveIntensity,
            label: "tube_hdr_blood_red"
        )

        jointMaterial = tubeMaterial

        print(
            """
            [PortalFX] retint applied
              target: border_tube
              hue: \(PortalFXPalette.bloodRedHue)
              saturation: \(PortalFXPalette.bloodRedSaturation)
              brightness: \(PortalFXPalette.bloodRedBrightness)
              materialEmissiveIntensity: \(PortalFXDefaults.tubeEmissiveIntensity)
              bloom: unchanged_installed
            """
        )

        emberBirthMaterials = [
            Self.makeEmissiveMaterial(
                base: UIColor(red: 1.0, green: 0.88, blue: 0.34, alpha: 1),
                emissive: UIColor(red: 1.0, green: 0.90, blue: 0.38, alpha: 1),
                intensity: 3.2,
                label: "ember_birth_yellow_32"
            ),
            Self.makeEmissiveMaterial(
                base: UIColor(red: 1.0, green: 0.70, blue: 0.18, alpha: 1),
                emissive: UIColor(red: 1.0, green: 0.74, blue: 0.20, alpha: 1),
                intensity: 2.8,
                label: "ember_birth_orange_28"
            )
        ]

        emberHotMaterials = [
            Self.makeEmissiveMaterial(
                base: UIColor(red: 1.0, green: 0.36, blue: 0.045, alpha: 1),
                emissive: UIColor(red: 1.0, green: 0.36, blue: 0.045, alpha: 1),
                intensity: 2.4,
                label: "ember_hot_24"
            ),
            Self.makeEmissiveMaterial(
                base: UIColor(red: 0.92, green: 0.20, blue: 0.02, alpha: 1),
                emissive: UIColor(red: 0.95, green: 0.18, blue: 0.02, alpha: 1),
                intensity: 2.0,
                label: "ember_hot_redorange_20"
            )
        ]

        emberRedMaterials = [
            Self.makeEmissiveMaterial(
                base: UIColor(red: 0.70, green: 0.055, blue: 0.012, alpha: 1),
                emissive: UIColor(red: 0.72, green: 0.045, blue: 0.010, alpha: 1),
                intensity: 1.4,
                label: "ember_red_14"
            ),
            Self.makeEmissiveMaterial(
                base: UIColor(red: 0.45, green: 0.025, blue: 0.006, alpha: 1),
                emissive: UIColor(red: 0.50, green: 0.025, blue: 0.006, alpha: 1),
                intensity: 1.0,
                label: "ember_deep_red_10"
            )
        ]

        emberDarkMaterials = [
            Self.makeEmissiveMaterial(
                base: UIColor(red: 0.18, green: 0.006, blue: 0.003, alpha: 0.45),
                emissive: UIColor(red: 0.20, green: 0.006, blue: 0.003, alpha: 1),
                intensity: 0.25,
                label: "ember_dark_025"
            )
        ]

        emberMesh = .generateSphere(
            radius: 0.5
        )

        print("[PortalFX] shared resources initialized")
    }

    private static func makeEmissiveMaterial(
        base: UIColor,
        emissive: UIColor,
        intensity: Float,
        label: String
    ) -> RealityKit.Material {
        var material = PhysicallyBasedMaterial()

        material.baseColor = .init(
            tint: base
        )

        material.roughness = .init(floatLiteral: 0.72)
        material.metallic = .init(floatLiteral: 0.0)

        material.emissiveColor = .init(
            color: emissive
        )

        material.emissiveIntensity = .init(
            floatLiteral: intensity
        )

        print(
            """
            [PortalFX] emissive material created
              label: \(label)
              baseColor: visible_not_black
              emissiveIntensity: \(intensity)
              hdrIntent: true
            """
        )

        return material
    }
}
