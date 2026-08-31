import Foundation
import RealityKit
import simd

@MainActor
final class Chapter03HeavenPortalEmberController {
    nonisolated static let isRuntimeEnabled = false

    let rootEntity: Entity
    private let portalFX: PortalTransitionFXController
    private var activeRunID: UUID?
    private var activePlaybackID: UUID?
    private var lastLoggedPose: MindEyeMouthPose?
    private(set) var poseTransitionCount = 0

    init(perimeterLocalPoints: [SIMD3<Float>]) throws {
        let portalFX = PortalTransitionFXController(
            perimeterLocalPoints: perimeterLocalPoints,
            portalNormalLocal: SIMD3<Float>(0, 0, 1),
            configuration: .heavenPortal
        )
        try portalFX.build()
        self.portalFX = portalFX
        rootEntity = portalFX.rootEntity
        rootEntity.name = "Chapter03HeavenPortalEmberRoot"
        print("[Chapter03HeavenEmbers] palette=heavenPurpleMagentaCyan coherentPerEmber=true")
    }

    func update(deltaTime: TimeInterval) {
        portalFX.update(deltaTime: Float(deltaTime))
    }

    func setPerformanceSample(_ sample: Chapter03AngelPerformanceSample) {
        if activeRunID == nil {
            activeRunID = sample.runID
            activePlaybackID = sample.playbackID
        }
        guard activeRunID == sample.runID,
              activePlaybackID == sample.playbackID else { return }
        portalFX.setBirthRateMultiplier(sample.emberBirthRateMultiplier)
        if sample.pose != lastLoggedPose {
            poseTransitionCount += 1
            lastLoggedPose = sample.pose
            Chapter03HeavenPortalEmberDiagnostics.poseChanged(
                runID: activeRunID,
                playbackID: activePlaybackID,
                frame: sample.frameIndex,
                pose: sample.pose,
                multiplier: sample.emberBirthRateMultiplier,
                effectiveBirthRate: PortalFXDefaults.emberBirthRatePerDoor *
                    sample.emberBirthRateMultiplier
            )
        }
    }

    func clearPerformanceIdentity() {
        activeRunID = nil
        activePlaybackID = nil
        lastLoggedPose = .rest
        portalFX.setBirthRateMultiplier(PortalFXVisemeDensityMapper.rest)
    }

    func teardown(reason: String) {
        activeRunID = nil
        activePlaybackID = nil
        lastLoggedPose = nil
        portalFX.setBirthRateMultiplier(PortalFXVisemeDensityMapper.rest)
        portalFX.teardown()
        Chapter03HeavenPortalEmberDiagnostics.tornDown(reason: reason)
    }

    var activeEmberCount: Int { portalFX.activeEmberCount }
    var currentMultiplier: Float { portalFX.currentBirthRateMultiplier }
    var totalSpawnedCount: UInt64 { portalFX.totalSpawnedCount }
    var maximumEmberCount: Int { portalFX.maximumEmberCount }
}
