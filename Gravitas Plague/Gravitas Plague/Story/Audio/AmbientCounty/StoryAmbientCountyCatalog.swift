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
        "air-raid-01-county-distant-10.wav",
        "air-raid-02-county-distant-10.wav",
        "air-raid-03-county-distant-10.wav",
        "air-raid-04-county-distant-10.wav",
        "car-alarm-01-county-5.wav",
        "car-alarm-02-county-5.wav",
        "car-alarm-03-county-5.wav",
        "car-peel-01-county-1.wav",
        "car-peel-02-county-1.wav",
        "car-peel-03-county-1.wav",
        "car-peel-04-county-1.wav",
        "chainsaw-01-county-distance-1.wav",
        "chainsaw-02-county-distance-1.wav",
        "chainsaw-03-county-distance-1.wav",
        "chainsaw-04-county-distance-1.wav",
        "clank-01-county-10.wav",
        "clank-02-county-10.wav",
        "clank-03-county-10.wav",
        "dog-01-county-10.wav",
        "dog-02-county-10.wav",
        "dog-03-county-10.wav",
        "dog-04-county-10.wav",
        "train-01-county-distant-10.wav",
        "train-02-county-distant-10.wav",
        "train-03-county-distant-10.wav",
        "train-04-county-distant-10.wav"
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
        try require(catalog.assets.count == expectedFiles.count, "catalog must contain exactly 26 assets")
        try require(Set(catalog.assets.map(\.id)).count == expectedFiles.count, "catalog asset IDs must be unique")
        try require(Set(catalog.assets.map(\.fileName)) == expectedFiles, "county filenames do not match")

        for asset in catalog.assets {
            try require(asset.assetClass == .distantAuthored, "invalid county class for \(asset.fileName)")
            let fileNameWeight = StoryAmbientCountyFileNaming.selectionWeight(
                from: asset.fileName
            )
            try require(
                fileNameWeight != nil,
                "county filename must end in a 1-10 weight: \(asset.fileName)"
            )
            try require(
                asset.selectionWeight == Double(fileNameWeight ?? 0),
                "catalog weight does not match filename for \(asset.fileName)"
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

nonisolated enum StoryAmbientCountyFileNaming {
    static func selectionWeight(from fileName: String) -> Int? {
        let fileURL = URL(fileURLWithPath: fileName)
        guard fileURL.pathExtension.lowercased() == "wav",
              let suffix = fileURL
                .deletingPathExtension()
                .lastPathComponent
                .split(separator: "-")
                .last,
              let weight = Int(suffix),
              (1...10).contains(weight) else {
            return nil
        }
        return weight
    }
}
