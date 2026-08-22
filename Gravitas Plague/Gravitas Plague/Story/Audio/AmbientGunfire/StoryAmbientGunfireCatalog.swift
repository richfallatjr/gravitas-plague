import Foundation
import simd

nonisolated enum StoryAmbientGunfireClass: String, Codable, Sendable, Hashable {
    case distantAuthored
    case dryGunfire
}

nonisolated struct StoryAmbientGunfireAsset: Codable, Sendable, Hashable {
    let id: String
    let fileName: String
    let assetClass: StoryAmbientGunfireClass
    let selectionWeight: Double
    let sourceGainDB: Double
    let distanceRolloffFactor: Double
}

nonisolated struct StoryAmbientGunfireCatalog: Codable, Sendable {
    let schemaVersion: Int
    let minimumGapSeconds: Double
    let maximumGapSeconds: Double
    let distantFixedDistanceFeet: Double
    let dryMinimumDistanceFeet: Double
    let dryMaximumDistanceFeet: Double
    let groundOffsetMeters: Float
    let avoidImmediateRepeat: Bool
    let maximumActiveVoices: Int
    let assets: [StoryAmbientGunfireAsset]
}

nonisolated enum StoryAmbientGunfireError: LocalizedError, Sendable {
    case catalogInvalid(String)
    case sceneUnavailable
    case playerPoseUnavailable
    case voiceLimitExceeded

    var errorDescription: String? {
        switch self {
        case .catalogInvalid(let message):
            return message
        case .sceneUnavailable:
            return "Story ambient gunfire scene is unavailable."
        case .playerPoseUnavailable:
            return "Tracked player pose is unavailable."
        case .voiceLimitExceeded:
            return "A Story ambient gunfire voice is already active."
        }
    }
}

nonisolated struct StoryAmbientGunfireCatalogStore: Sendable {
    let catalog: StoryAmbientGunfireCatalog

    init(bundle: Bundle = .main) throws {
        catalog = try TuringResourceLoader.decodeResource(
            StoryAmbientGunfireCatalog.self,
            resourcePath: "Turing/Audio/story-ambient-gunfire/catalog.json",
            bundle: bundle
        )
        try StoryAmbientGunfireCatalogValidator.validate(catalog, bundle: bundle)
    }
}

nonisolated enum StoryAmbientGunfireCatalogValidator {
    private static let dryFiles = [
        "automatic-pistol-01.wav",
        "automatic-pistol-02.wav",
        "automatic-pistol-03.wav",
        "automatic-pistol-04.wav",
        "automatic-pistol-05.wav",
        "pistol-volley-01.wav",
        "rifle-1-01.wav",
        "rifle-1-02.wav",
        "rifle-1-03.wav",
        "rifle-1-04.wav",
        "rifle-1-05.wav",
        "rifle-3-01.wav",
        "rifle-3-02.wav",
        "semi-auto-rifle-01.wav",
        "semi-auto-rifle-02.wav",
        "semi-auto-rifle-03.wav",
        "shotgun-01.wav",
        "shotgun-02.wav",
        "shotgun-2-01.wav"
    ]

    private static let distantFiles = (1...7).map {
        String(format: "distant-%02d.wav", $0)
    }

    static func validate(
        _ catalog: StoryAmbientGunfireCatalog,
        bundle: Bundle = .main
    ) throws {
        try require(catalog.schemaVersion == 1, "schemaVersion must be 1")
        try require(catalog.minimumGapSeconds == 5, "minimum gap must be 5 seconds")
        try require(catalog.maximumGapSeconds == 30, "maximum gap must be 30 seconds")
        try require(catalog.distantFixedDistanceFeet == 50, "distant radius must be 50 feet")
        try require(catalog.dryMinimumDistanceFeet == 500, "dry minimum radius must be 500 feet")
        try require(catalog.dryMaximumDistanceFeet == 1000, "dry maximum radius must be 1000 feet")
        try require(
            catalog.groundOffsetMeters.isFinite && catalog.groundOffsetMeters == 0.05,
            "ground offset must be 0.05 meters"
        )
        try require(catalog.maximumActiveVoices == 1, "maximumActiveVoices must be 1")
        try require(catalog.assets.count == 26, "catalog must contain exactly 26 assets")

        let ids = Set(catalog.assets.map(\.id))
        let files = Set(catalog.assets.map(\.fileName))
        let expectedFiles = Set(dryFiles + distantFiles)
        try require(ids.count == 26, "catalog asset IDs must be unique")
        try require(files == expectedFiles, "catalog filenames do not match the authored set")

        for asset in catalog.assets {
            try require(
                asset.selectionWeight.isFinite && asset.selectionWeight > 0,
                "invalid selection weight for \(asset.fileName)"
            )
            try require(
                asset.sourceGainDB.isFinite && asset.distanceRolloffFactor.isFinite,
                "non-finite audio policy for \(asset.fileName)"
            )

            if distantFiles.contains(asset.fileName) {
                try require(asset.assetClass == .distantAuthored, "invalid distant class for \(asset.fileName)")
                try require(asset.sourceGainDB == 0, "distant gain must be 0 dB for \(asset.fileName)")
                try require(asset.distanceRolloffFactor == 0, "distant rolloff must be 0 for \(asset.fileName)")
            } else {
                try require(asset.assetClass == .dryGunfire, "invalid dry class for \(asset.fileName)")
                try require(asset.sourceGainDB == -12, "dry gain must be -12 dB for \(asset.fileName)")
                try require(asset.distanceRolloffFactor == 1, "dry rolloff must be 1 for \(asset.fileName)")
            }

            _ = try TuringResourceLoader.resourceURL(
                resourcePath: "Turing/Audio/story-ambient-gunfire/\(asset.fileName)",
                bundle: bundle
            )
        }
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else {
            throw StoryAmbientGunfireError.catalogInvalid(message)
        }
    }
}

nonisolated enum StoryAmbientGunfireUnits {
    static let feetToMeters = 0.3048
}

nonisolated enum StoryAmbientGunfireFloorSource: String, Sendable, Equatable {
    case mapped
    case headFallback
}

nonisolated struct StoryAmbientGunfireWorldSnapshot: Sendable, Equatable {
    let playerPosition: SIMD3<Float>
    let floorY: Float
    let floorSource: StoryAmbientGunfireFloorSource
}

nonisolated struct StoryAmbientGunfireSessionID: Sendable, Equatable, Hashable {
    let rawValue: UUID
}

nonisolated struct StoryAmbientGunfireEventID: Sendable, Equatable, Hashable {
    let rawValue: UUID
}

nonisolated struct StoryAmbientGunfirePlaybackRequest: Sendable, Equatable {
    let sessionID: StoryAmbientGunfireSessionID
    let eventID: StoryAmbientGunfireEventID
    let asset: StoryAmbientGunfireAsset
    let worldPosition: SIMD3<Float>
    let azimuthRadians: Double
    let radiusFeet: Double
    let floorSource: StoryAmbientGunfireFloorSource
}

@MainActor
final class StoryAmbientGunfireWorldSnapshotProvider {
    private unowned let spatialProvider: PhaseOneSpatialProvider
    private unowned let wallManager: WallPlaneManager

    init(
        spatialProvider: PhaseOneSpatialProvider,
        wallManager: WallPlaneManager
    ) {
        self.spatialProvider = spatialProvider
        self.wallManager = wallManager
    }

    func capture() throws -> StoryAmbientGunfireWorldSnapshot {
        guard let pose = spatialProvider.currentPose() else {
            throw StoryAmbientGunfireError.playerPoseUnavailable
        }
        if let floor = wallManager.bestFloorCandidate() {
            return .init(
                playerPosition: pose.headPosition,
                floorY: floor.worldY,
                floorSource: .mapped
            )
        }
        return .init(
            playerPosition: pose.headPosition,
            floorY: pose.headPosition.y - 1.45,
            floorSource: .headFallback
        )
    }
}

nonisolated protocol StoryAmbientGunfireRandomSource: Sendable {
    func nextUnitInterval() async -> Double
}

actor SystemStoryAmbientGunfireRandomSource: StoryAmbientGunfireRandomSource {
    func nextUnitInterval() -> Double {
        Double.random(in: 0..<1)
    }
}

nonisolated protocol StoryAmbientGunfireClock: Sendable {
    func sleep(seconds: Double) async throws
}

nonisolated struct ContinuousStoryAmbientGunfireClock: StoryAmbientGunfireClock {
    private let clock = ContinuousClock()

    func sleep(seconds: Double) async throws {
        try await clock.sleep(for: .seconds(seconds))
    }
}

nonisolated enum StoryAmbientGunfireSpatialSampler {
    static func gapSeconds(catalog: StoryAmbientGunfireCatalog, unit: Double) -> Double {
        catalog.minimumGapSeconds + clampedUnit(unit) *
            (catalog.maximumGapSeconds - catalog.minimumGapSeconds)
    }

    static func azimuthRadians(unit: Double) -> Double {
        clampedUnit(unit) * 2 * Double.pi
    }

    static func radiusFeet(
        assetClass: StoryAmbientGunfireClass,
        catalog: StoryAmbientGunfireCatalog,
        unit: Double
    ) -> Double {
        switch assetClass {
        case .distantAuthored:
            return catalog.distantFixedDistanceFeet
        case .dryGunfire:
            let minimum = catalog.dryMinimumDistanceFeet
            let maximum = catalog.dryMaximumDistanceFeet
            return exp(log(minimum) + clampedUnit(unit) * (log(maximum) - log(minimum)))
        }
    }

    static func worldPosition(
        snapshot: StoryAmbientGunfireWorldSnapshot,
        azimuthRadians: Double,
        radiusFeet: Double,
        groundOffsetMeters: Float
    ) -> SIMD3<Float> {
        let radiusMeters = radiusFeet * StoryAmbientGunfireUnits.feetToMeters
        return SIMD3<Float>(
            snapshot.playerPosition.x + Float(cos(azimuthRadians) * radiusMeters),
            snapshot.floorY + groundOffsetMeters,
            snapshot.playerPosition.z + Float(sin(azimuthRadians) * radiusMeters)
        )
    }

    private static func clampedUnit(_ value: Double) -> Double {
        min(max(value, 0), Double(1).nextDown)
    }
}

nonisolated enum StoryAmbientGunfireTelemetry {
    static func eventStarted(
        request: StoryAmbientGunfirePlaybackRequest,
        precedingGapSeconds: Double
    ) {
        print(
            """
            [StoryAmbientGunfire] event started
              sessionID: \(request.sessionID.rawValue.uuidString)
              eventID: \(request.eventID.rawValue.uuidString)
              file: \(request.asset.fileName)
              class: \(request.asset.assetClass.rawValue)
              sourceGainDB: \(request.asset.sourceGainDB)
              rolloffFactor: \(request.asset.distanceRolloffFactor)
              delaySeconds: \(String(format: "%.3f", precedingGapSeconds))
              azimuthDegrees: \(String(format: "%.2f", request.azimuthRadians * 180 / .pi))
              radiusFeet: \(String(format: "%.2f", request.radiusFeet))
              worldPositionMeters: \(request.worldPosition)
              floorSource: \(request.floorSource.rawValue)
            """
        )
    }

    static func eventCompleted(request: StoryAmbientGunfirePlaybackRequest) {
        print(
            "[StoryAmbientGunfire] event completed " +
                "eventID=\(request.eventID.rawValue.uuidString) " +
                "emitterRemoved=true transientResourceEvicted=true"
        )
    }
}
