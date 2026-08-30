import RealityKit

@MainActor
struct PortalEmberMaterialPalette {
    let identifier: String
    let selectionMode: PortalEmberMaterialSelectionMode
    let birthMaterials: [RealityKit.Material]
    let hotMaterials: [RealityKit.Material]
    let lateMaterials: [RealityKit.Material]
    let darkMaterials: [RealityKit.Material]

    var materialCounts: PortalEmberMaterialCounts {
        .init(
            birth: birthMaterials.count,
            hot: hotMaterials.count,
            red: lateMaterials.count,
            dark: darkMaterials.count
        )
    }

    func validate() throws {
        guard !identifier.isEmpty,
              !birthMaterials.isEmpty,
              !hotMaterials.isEmpty,
              !lateMaterials.isEmpty,
              !darkMaterials.isEmpty else {
            throw PortalFXError.invalidMaterialPalette(identifier)
        }
        if selectionMode == .coherentTrack {
            let count = birthMaterials.count
            guard count == 2,
                  hotMaterials.count == count,
                  lateMaterials.count == count,
                  darkMaterials.count == count else {
                throw PortalFXError.invalidMaterialPalette(identifier)
            }
        }
    }
}

nonisolated struct PortalEmberMaterialCounts: Sendable, Equatable {
    let birth: Int
    let hot: Int
    let red: Int
    let dark: Int
}

nonisolated struct PortalEmberMaterialIndices: Sendable, Equatable {
    let birth: Int
    let hot: Int
    let late: Int
    let dark: Int
}

nonisolated enum PortalEmberMaterialIndexPlanner {
    static func choose<RNG: RandomNumberGenerator>(
        mode: PortalEmberMaterialSelectionMode,
        counts: PortalEmberMaterialCounts,
        using generator: inout RNG
    ) -> PortalEmberMaterialIndices {
        switch mode {
        case .independentPerPhase:
            return .init(
                birth: Int.random(in: 0..<max(counts.birth, 1), using: &generator),
                hot: Int.random(in: 0..<max(counts.hot, 1), using: &generator),
                late: Int.random(in: 0..<max(counts.red, 1), using: &generator),
                dark: Int.random(in: 0..<max(counts.dark, 1), using: &generator)
            )
        case .coherentTrack:
            let trackCount = [counts.birth, counts.hot, counts.red, counts.dark].min() ?? 0
            precondition(trackCount > 0)
            let index = Int.random(in: 0..<trackCount, using: &generator)
            return .init(birth: index, hot: index, late: index, dark: index)
        }
    }
}
