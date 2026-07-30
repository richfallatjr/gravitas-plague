import Foundation

enum TuringRollingBenchEntityName {
    static let bundleRoot = "root"
    static let cartRoot = "cart_root"
    static let generatorRoot = "generator_root"
    static let hamReceiverRoot = "ham_receiver_root"
    static let crankRadioRoot = "crank_radio_root"
    static let antennaeRoot = "antennae_root"
    static let microphoneRoot = "microphone_root"
    static let crankRadioIconAnchor = "crank_radio_icon_root"
    static let hamReceiverIconAnchor =
        "ham_receiver_icon_root_001"
    static let microphoneIconAnchor = "microphone_icon_root"
    static let importedEnvironmentLight = "env_light"

    static let canonicalBundleRoot = "TuringRollingBenchBundle_Root"
    static let canonicalCartRoot = "TuringRollingBenchCart_Root"
    static let canonicalGeneratorRoot = "TuringRollingBenchGenerator_Root"
    static let canonicalHamReceiverRoot = "TuringRollingBenchHamReceiver_Root"
    static let canonicalCrankRadioRoot = "TuringRollingBenchCrankRadio_Root"
    static let canonicalAntennaeRoot = "TuringRollingBenchAntennae_Root"
    static let canonicalMicrophoneRoot = "TuringRollingBenchMicrophone_Root"
    static let canonicalCrankRadioIconAnchor = "TuringRollingBenchCrankRadio_IconAnchor"
    static let canonicalHamReceiverIconAnchor =
        "TuringRollingBenchHamReceiver_IconAnchor"
    static let canonicalMicrophoneIconAnchor = "TuringRollingBenchMicrophone_IconAnchor"

    static let runtimeAudioEmitter = "TuringRollingBenchCrankRadio_AudioEmitter"
    static let runtimeStaticLane = "TuringRollingBenchCrankRadio_StaticLane"
    static let runtimeCueLane = "TuringRollingBenchCrankRadio_CueLane"
    static let runtimeBroadcastLane = "TuringRollingBenchCrankRadio_BroadcastLane"
    static let runtimeCrankRadioHitTarget = "TuringRollingBenchCrankRadio_HitTarget"
    static let runtimeCrankRadioActionIcon = "TuringRollingBenchCrankRadio_ActionIcon"
    static let runtimeHamReceiverAudioEmitter =
        "TuringRollingBenchHamReceiver_AudioEmitter"
    static let runtimeHamReceiverHitTarget =
        "TuringRollingBenchHamReceiver_PhysicalHitTarget"
    static let runtimeHamReceiverActionIcon =
        "TuringRollingBenchHamReceiver_ActionIcon"
}

enum TuringRollingBenchTuning {
    static let runtimeScale: Float = 3.0
    static let expectedHeightMeters: Float = 1.2192
    static let minimumPlausibleHeightMeters: Float = 1.00
    static let maximumPlausibleHeightMeters: Float = 1.45
    static let minimumReservationWidthMeters: Float = 1.10
    static let preferredReservationWidthMeters: Float = 1.25
    static let maximumReservationWidthMeters: Float = 1.40
    static let frontageDepthMeters: Float = 0.70
    static let wallMarginMeters: Float = 0.10
    static let depthOffsetMeters: Float = 0.018
    static let occupancyPaddingMeters: Float = 0.14
    static let bottomAboveFloorMeters: Float = 0
    static let floorSnapToleranceMeters: Float = 0.01

    static let ambientStaticGainDB: Double = -15.0
    static let tuningLoopGainDB: Double = 20.0 * log10(0.20)
    static let cueGainDB: Double = -23.0
}

struct TuringRollingBenchBundlePlacement: Codable, Equatable, Sendable {
    var wallID: UUID
    var localX: Float
    var localY: Float
    var depthOffset: Float
    var width: Float
    var height: Float
    var floorWorldY: Float
}

func turingRollingBenchWallRect(
    for placement: TuringRollingBenchBundlePlacement
) -> WallLocalRect {
    WallLocalRect(
        minX: placement.localX - placement.width * 0.5,
        minY: placement.localY - placement.height * 0.5,
        maxX: placement.localX + placement.width * 0.5,
        maxY: placement.localY + placement.height * 0.5
    )
}
