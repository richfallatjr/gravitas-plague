import Foundation
import simd

nonisolated struct StoryAmbientAircraftAsset: Codable, Sendable, Hashable {
    let id: String
    let fileName: String
    let selectionWeight: Double
}

nonisolated struct StoryAmbientAircraftCatalog: Codable, Sendable {
    let schemaVersion: Int
    let minimumGapSeconds: Double
    let maximumGapSeconds: Double
    let minimumHeightFeet: Double
    let maximumHeightFeet: Double
    let sourceGainDB: Double
    let distanceRolloffFactor: Double
    let maximumActiveVoices: Int
    let assets: [StoryAmbientAircraftAsset]
}

nonisolated enum StoryAmbientAircraftError: LocalizedError, Sendable {
    case catalogInvalid(String)
    case sceneUnavailable
    case voiceLimitExceeded

    var errorDescription: String? {
        switch self {
        case .catalogInvalid(let message):
            return message
        case .sceneUnavailable:
            return "Story ambient aircraft scene is unavailable."
        case .voiceLimitExceeded:
            return "A Story ambient aircraft voice is already active."
        }
    }
}

nonisolated struct StoryAmbientAircraftCatalogStore: Sendable {
    let catalog: StoryAmbientAircraftCatalog

    init(bundle: Bundle = .main) throws {
        catalog = try TuringResourceLoader.decodeResource(
            StoryAmbientAircraftCatalog.self,
            resourcePath: "Turing/Audio/story-ambient-aircraft/catalog.json",
            bundle: bundle
        )
        try StoryAmbientAircraftCatalogValidator.validate(catalog, bundle: bundle)
    }
}

nonisolated enum StoryAmbientAircraftCatalogValidator {
    private static let expectedFiles = Set([
        "helicopter-overhead-02.wav",
        "helicopter-overhead-03.wav",
        "jet-overhead-02.wav"
    ])

    static func validate(
        _ catalog: StoryAmbientAircraftCatalog,
        bundle: Bundle = .main
    ) throws {
        try require(catalog.schemaVersion == 1, "schemaVersion must be 1")
        try require(catalog.minimumGapSeconds == 10, "minimum gap must be 10 seconds")
        try require(catalog.maximumGapSeconds == 30, "maximum gap must be 30 seconds")
        try require(catalog.minimumHeightFeet == 10, "minimum height must be 10 feet")
        try require(catalog.maximumHeightFeet == 15, "maximum height must be 15 feet")
        try require(catalog.sourceGainDB == 0, "source gain must be 0 dB")
        try require(catalog.distanceRolloffFactor == 0, "distance rolloff must be 0")
        try require(catalog.maximumActiveVoices == 1, "maximumActiveVoices must be 1")
        try require(catalog.assets.count == 3, "catalog must contain exactly 3 assets")
        try require(Set(catalog.assets.map(\.fileName)) == expectedFiles, "aircraft filenames do not match")
        try require(Set(catalog.assets.map(\.id)).count == 3, "aircraft IDs must be unique")

        for asset in catalog.assets {
            try require(
                asset.selectionWeight.isFinite && asset.selectionWeight > 0,
                "invalid selection weight for \(asset.fileName)"
            )
            _ = try TuringResourceLoader.resourceURL(
                resourcePath: "Turing/Audio/story-ambient-aircraft/\(asset.fileName)",
                bundle: bundle
            )
        }
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw StoryAmbientAircraftError.catalogInvalid(message)
        }
    }
}

nonisolated struct StoryAmbientAircraftSessionID: Sendable, Equatable, Hashable {
    let rawValue: UUID
}

nonisolated struct StoryAmbientAircraftEventID: Sendable, Equatable, Hashable {
    let rawValue: UUID
}

nonisolated struct StoryAmbientAircraftPlaybackRequest: Sendable, Equatable {
    let sessionID: StoryAmbientAircraftSessionID
    let eventID: StoryAmbientAircraftEventID
    let asset: StoryAmbientAircraftAsset
    let worldPosition: SIMD3<Float>
    let heightFeet: Double
    let sourceGainDB: Double
    let distanceRolloffFactor: Double
}

nonisolated enum StoryAmbientAircraftSampler {
    static func gapSeconds(
        catalog: StoryAmbientAircraftCatalog,
        unit: Double
    ) -> Double {
        catalog.minimumGapSeconds + clampedUnit(unit) *
            (catalog.maximumGapSeconds - catalog.minimumGapSeconds)
    }

    static func heightFeet(
        catalog: StoryAmbientAircraftCatalog,
        unit: Double
    ) -> Double {
        catalog.minimumHeightFeet + clampedUnit(unit) *
            (catalog.maximumHeightFeet - catalog.minimumHeightFeet)
    }

    static func worldPosition(heightFeet: Double) -> SIMD3<Float> {
        SIMD3<Float>(
            0,
            Float(heightFeet * StoryAmbientGunfireUnits.feetToMeters),
            0
        )
    }

    private static func clampedUnit(_ value: Double) -> Double {
        min(max(value, 0), Double(1).nextDown)
    }
}

nonisolated enum StoryAmbientAircraftTelemetry {
    static func eventStarted(
        request: StoryAmbientAircraftPlaybackRequest,
        precedingGapSeconds: Double
    ) {
        print(
            "[StoryAmbientAircraft] event started " +
                "sessionID=\(request.sessionID.rawValue.uuidString) " +
                "eventID=\(request.eventID.rawValue.uuidString) " +
                "file=\(request.asset.fileName) " +
                "delaySeconds=\(String(format: "%.3f", precedingGapSeconds)) " +
                "heightFeet=\(String(format: "%.2f", request.heightFeet)) " +
                "worldPositionMeters=\(request.worldPosition) " +
                "sourceGainDB=\(request.sourceGainDB)"
        )
    }

    static func eventCompleted(request: StoryAmbientAircraftPlaybackRequest) {
        print(
            "[StoryAmbientAircraft] event completed " +
                "eventID=\(request.eventID.rawValue.uuidString) " +
                "emitterRemoved=true transientResourceEvicted=true"
        )
    }
}
