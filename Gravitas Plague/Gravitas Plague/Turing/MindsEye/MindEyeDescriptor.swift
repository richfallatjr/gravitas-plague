import Foundation

nonisolated enum MindEyeMouthPose:
    String,
    Codable,
    CaseIterable,
    Sendable,
    Hashable
{
    case rest
    case small
    case wide
    case round
    case teeth
}

nonisolated struct MindEyePixelSize:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    let width: Int
    let height: Int

    static let source = MindEyePixelSize(width: 2_304, height: 1_296)
    static let viewport = MindEyePixelSize(width: 1_920, height: 1_080)

    var pixelCount: Int? {
        let product = width.multipliedReportingOverflow(by: height)
        return product.overflow ? nil : product.partialValue
    }

    var isPositive: Bool {
        width > 0 && height > 0
    }
}

nonisolated struct MindEyePixelPoint:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    let x: Int
    let y: Int
}

nonisolated struct MindEyePixelRect:
    Codable,
    Sendable,
    Equatable,
    Hashable
{
    let origin: MindEyePixelPoint
    let size: MindEyePixelSize

    static let centeredViewport = MindEyePixelRect(
        origin: MindEyePixelPoint(x: 192, y: 108),
        size: .viewport
    )
}

nonisolated struct MindEyeFloat2:
    Codable,
    Sendable,
    Equatable
{
    let x: Float
    let y: Float
}

nonisolated struct MindEyeDepthTuning:
    Codable,
    Sendable,
    Equatable
{
    let cameraToCharacterMeters: Float
    let cameraToBackgroundMeters: Float
}

nonisolated struct MindEyeMotionTuning:
    Codable,
    Sendable,
    Equatable
{
    let sharedDriftMaxPixels: MindEyeFloat2
    let sharedRollMaxDegrees: Float
    let sharedScaleMax: Float
    let characterParallaxMaxPixels: MindEyeFloat2
    let backgroundCounterMotion: Float
    let gripCorrectionMaxPixels: MindEyeFloat2
    let gripCorrectionMaxDegrees: Float
}

nonisolated struct MindEyeBlinkTuning:
    Codable,
    Sendable,
    Equatable
{
    let ordinaryIntervalMinSeconds: Double
    let ordinaryIntervalMaxSeconds: Double
    let closedFrameMin: Int
    let closedFrameMax: Int
    let doubleBlinkProbability: Double
    let doubleBlinkGapMinSeconds: Double
    let doubleBlinkGapMaxSeconds: Double
}

nonisolated struct MindEyePlacementTuning:
    Codable,
    Sendable,
    Equatable
{
    let cardWidthMeters: Float
    let cardHeightMeters: Float
    let verticalLiftMeters: Float
    let forwardOffsetMeters: Float
    let shelfClearanceMeters: Float
}

nonisolated enum MindEyeDescriptorConstants {
    static let catalogSchemaVersion = 1
    static let vignetteSchemaVersion = 1
    static let expectedSourceSize = MindEyePixelSize.source
    static let expectedViewportSize = MindEyePixelSize.viewport
    static let expectedViewportRect = MindEyePixelRect.centeredViewport
    static let requiredMouthPoses = Set(MindEyeMouthPose.allCases)
}
