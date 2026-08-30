import Foundation

enum PortalFXError: Error, Equatable {
    case invalidConfiguration
    case invalidPerimeterPointCount(Int)
    case invalidMaterialPalette(String)
    case invalidPoolCapacity(Int)
}

nonisolated enum PortalTransitionFXBorderRendering: Sendable, Equatable {
    case tubeAndJoints
    case embersOnly
}

nonisolated enum PortalEmberMaterialSelectionMode: Sendable, Equatable {
    case independentPerPhase
    case coherentTrack
}

nonisolated enum PortalEmberPaletteID: String, Sendable, Equatable {
    case hordeHellfire
    case heavenPurpleMagentaCyan
}

nonisolated struct PortalTransitionFXConfiguration: Sendable, Equatable {
    let identifier: String
    let borderRendering: PortalTransitionFXBorderRendering
    let paletteID: PortalEmberPaletteID
    let initialBirthRateMultiplier: Float
    let maximumBirthRateMultiplier: Float

    var maximumPoolCapacity: Int {
        Int(ceil(
            PortalFXDefaults.emberBirthRatePerDoor *
                maximumBirthRateMultiplier *
                PortalFXDefaults.emberLifeSecondsMax *
                PortalFXDefaults.emberMaxActiveMultiplier
        ))
    }

    func validate() throws {
        guard !identifier.isEmpty,
              initialBirthRateMultiplier.isFinite,
              maximumBirthRateMultiplier.isFinite,
              initialBirthRateMultiplier == 1,
              maximumBirthRateMultiplier >= initialBirthRateMultiplier,
              maximumBirthRateMultiplier <= 2 else {
            throw PortalFXError.invalidConfiguration
        }
        switch paletteID {
        case .hordeHellfire:
            guard self == .hordePortal else { throw PortalFXError.invalidConfiguration }
        case .heavenPurpleMagentaCyan:
            guard self == .heavenPortal else { throw PortalFXError.invalidConfiguration }
        }
    }

    static let hordePortal = Self(
        identifier: "horde.hellfire.current",
        borderRendering: .tubeAndJoints,
        paletteID: .hordeHellfire,
        initialBirthRateMultiplier: 1,
        maximumBirthRateMultiplier: 1
    )

    static let heavenPortal = Self(
        identifier: "chapter03.heaven.visemeReactive.v1",
        borderRendering: .embersOnly,
        paletteID: .heavenPurpleMagentaCyan,
        initialBirthRateMultiplier: 1,
        maximumBirthRateMultiplier: 2
    )
}
