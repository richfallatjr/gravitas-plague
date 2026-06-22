import Foundation
import simd

struct PortalFXSnapshot: Sendable {
    let portalID: UUID
    let phaseRawValue: String
    let elapsedTime: Float
    let tubeIntensity: Float
    let emberEmissionEnabled: Bool
}

struct PortalEmberCommand: Sendable {
    let poolIndex: Int
    let isEnabled: Bool
    let positionLocal: SIMD3<Float>
    let scale: Float
    let opacity: Float
    let normalizedAge: Float
}

struct PortalFXPortalCommand: Sendable {
    let portalID: UUID
    let tubeIntensity: Float
    let tubeScale: Float
    let glyphPhase: Float
    let embers: [PortalEmberCommand]
}

struct PortalFXBatchRequest: Sendable {
    let frame: FrameStamp
    let portals: [PortalFXSnapshot]
}

struct PortalFXCommandBuffer: Sendable {
    let frameIndex: UInt64
    let portals: [PortalFXPortalCommand]
}
