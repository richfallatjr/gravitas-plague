import Foundation

nonisolated struct StoryAmbientCountyCatalogStore: Sendable {
    let catalog: StoryAmbientGunfireCatalog

    init(bundle: Bundle = .main) throws {
        catalog = try TuringResourceLoader.decodeResource(
            StoryAmbientGunfireCatalog.self,
            resourcePath: "Turing/Audio/story-ambient-county/catalog.json",
            bundle: bundle
        )
        try StoryAmbientCountyCatalogValidator.validate(catalog, bundle: bundle)
    }
}

nonisolated enum StoryAmbientCountyCatalogValidator {
    private static let expectedFiles = Set([
        "air-raid-01-county-distant.wav",
        "air-raid-02-county-distant.wav",
        "air-raid-03-county-distant.wav",
        "air-raid-04-county-distant.wav",
        "car-alarm-01-county.wav",
        "car-alarm-02-county.wav",
        "car-alarm-03-county.wav",
        "car-peel-01-county.wav",
        "car-peel-02-county.wav",
        "car-peel-03-county.wav",
        "car-peel-04-county.wav",
        "car-start-01-county.wav",
        "car-start-02-county.wav",
        "car-start-03-county.wav",
        "car-start-04-county.wav",
        "chainsaw-01-county-distance.wav",
        "chainsaw-02-county-distance.wav",
        "chainsaw-03-county-distance.wav",
        "chainsaw-04-county.wav",
        "dog-01-county.wav",
        "dog-02-county.wav",
        "dog-03-county.wav",
        "dog-04-county.wav",
        "pickup-01-county.wav",
        "pickup-02-county.wav",
        "pickup-03-county.wav",
        "pickup-04-county.wav",
        "train-01-county-distant.wav",
        "train-02-county-distant.wav",
        "train-03-county-distant.wav",
        "train-04-county-distant.wav"
    ])

    static func validate(
        _ catalog: StoryAmbientGunfireCatalog,
        bundle: Bundle = .main
    ) throws {
        try require(catalog.schemaVersion == 1, "schemaVersion must be 1")
        try require(catalog.minimumGapSeconds == 5, "minimum gap must be 5 seconds")
        try require(catalog.maximumGapSeconds == 15, "maximum gap must be 15 seconds")
        try require(catalog.distantFixedDistanceFeet == 50, "distant radius must be 50 feet")
        try require(catalog.dryMinimumDistanceFeet == 500, "dry minimum radius must be 500 feet")
        try require(catalog.dryMaximumDistanceFeet == 1000, "dry maximum radius must be 1000 feet")
        try require(
            catalog.groundOffsetMeters.isFinite && catalog.groundOffsetMeters == 0.05,
            "ground offset must be 0.05 meters"
        )
        try require(catalog.avoidImmediateRepeat, "immediate repeats must be disabled")
        try require(catalog.maximumActiveVoices == 1, "maximumActiveVoices must be 1")
        try require(catalog.assets.count == expectedFiles.count, "catalog must contain exactly 31 assets")
        try require(Set(catalog.assets.map(\.id)).count == expectedFiles.count, "catalog asset IDs must be unique")
        try require(Set(catalog.assets.map(\.fileName)) == expectedFiles, "county filenames do not match")

        for asset in catalog.assets {
            try require(asset.assetClass == .distantAuthored, "invalid county class for \(asset.fileName)")
            try require(
                asset.selectionWeight.isFinite && asset.selectionWeight > 0,
                "invalid selection weight for \(asset.fileName)"
            )
            try require(asset.sourceGainDB == 0, "county gain must be 0 dB for \(asset.fileName)")
            try require(asset.distanceRolloffFactor == 0, "county rolloff must be 0 for \(asset.fileName)")
            _ = try TuringResourceLoader.resourceURL(
                resourcePath: "Turing/Audio/story-ambient-county/\(asset.fileName)",
                bundle: bundle
            )
        }
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) throws {
        guard condition() else {
            throw StoryAmbientGunfireError.catalogInvalid(message)
        }
    }
}
