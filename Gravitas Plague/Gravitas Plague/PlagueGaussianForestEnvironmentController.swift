import Foundation
import RealityKit

enum PlagueImmersiveSpaceID {
    static let forest = "plague-forest-immersive-space"
}

enum PlagueForestAtmosphere: String, Codable, CaseIterable, Identifiable {
    case overcast
    case night

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .overcast:
            return "Day"

        case .night:
            return "Night"
        }
    }

    var gaussianSplatResourceName: String {
        switch self {
        case .overcast:
            return "forest-overcast-01"
        case .night:
            return "forest-night-01"
        }
    }

    var gaussianSplatFileExtension: String {
        "ply"
    }

    var hdriResourceName: String {
        switch self {
        case .overcast:
            return "forest-overcast-01"
        case .night:
            return "forest-night-01"
        }
    }

    var hdriFileExtension: String {
        "exr"
    }

    var next: PlagueForestAtmosphere {
        switch self {
        case .overcast:
            return .night

        case .night:
            return .overcast
        }
    }

    var iconSystemName: String {
        switch self {
        case .overcast:
            return "sun.max.fill"

        case .night:
            return "moon.stars.fill"
        }
    }

    var toggleTargetIconSystemName: String {
        switch self {
        case .overcast:
            return "moon.stars.fill"

        case .night:
            return "sun.max.fill"
        }
    }

    var iblIntensityExponent: Float {
        switch self {
        case .overcast:
            return 1.0

        case .night:
            return 0.45
        }
    }
}

enum PlagueForestAssetValidator {
    static func validate() {
        let files = [
            ("forest-overcast-01", "ply"),
            ("forest-overcast-01", "exr"),
            ("forest-night-01", "ply"),
            ("forest-night-01", "exr")
        ]

        for file in files {
            if let url = Bundle.main.url(
                forResource: file.0,
                withExtension: file.1
            ) {
                print(
                    """
                    [PlagueForest] found asset
                      file: \(file.0).\(file.1)
                      url: \(url.path)
                    """
                )
            } else {
                print(
                    """
                    [PlagueForest] ERROR missing asset
                      file: \(file.0).\(file.1)
                    """
                )
            }
        }

        print("[PlagueForest] strict native Gaussian splat path enabled; no fallback renderer is allowed")
    }
}

@MainActor
final class PlagueGaussianForestEnvironmentController {
    private let environmentRoot = Entity()
    private let splatRoot = Entity()
    private let lightingEntity = Entity()

    private weak var sceneRoot: Entity?
    private var splatEntities: [Entity] = []
    private var isInstalled = false
    private var activeAtmosphere: PlagueForestAtmosphere?
    private var activeRevision = -1
    private var isSwapInFlight = false
    private var failedAtmosphereRevisionKey: String?

    var onStrictAtmosphereFailure: ((Error) -> Void)?

    init() {
        environmentRoot.name = "PlagueForestEnvironmentRoot"
        splatRoot.name = "PlagueForestGaussianSplatRoot"
        lightingEntity.name = "PlagueForestHDRILighting"
        environmentRoot.addChild(splatRoot)
        environmentRoot.addChild(lightingEntity)
    }

    func attach(
        to sceneRoot: Entity
    ) {
        self.sceneRoot = sceneRoot

        guard !isInstalled else {
            return
        }

        sceneRoot.addChild(environmentRoot)
        isInstalled = true

        print("[PlagueForest] environment root installed")
    }

    func applyInitialAtmosphere(
        _ atmosphere: PlagueForestAtmosphere,
        revision: Int
    ) async {
        await updateAtmosphereIfNeeded(
            atmosphere: atmosphere,
            revision: revision,
            force: true
        )
    }

    func updateAtmosphereIfNeeded(
        atmosphere: PlagueForestAtmosphere,
        revision: Int,
        force: Bool = false
    ) async {
        let key = "\(atmosphere.rawValue)|\(revision)"

        guard force ||
              activeAtmosphere != atmosphere ||
              activeRevision != revision else {
            return
        }

        guard !isSwapInFlight else {
            return
        }

        if failedAtmosphereRevisionKey == key,
           !force {
            return
        }

        isSwapInFlight = true
        defer {
            isSwapInFlight = false
        }

        do {
            try await applyAtmosphereAtomically(
                atmosphere: atmosphere
            )

            activeAtmosphere = atmosphere
            activeRevision = revision
            failedAtmosphereRevisionKey = nil

            print(
                """
                [PlagueForest] atmosphere active
                  atmosphere: \(atmosphere.rawValue)
                  revision: \(revision)
                  ply: \(atmosphere.gaussianSplatResourceName).\(atmosphere.gaussianSplatFileExtension)
                  hdri: \(atmosphere.hdriResourceName).\(atmosphere.hdriFileExtension)
                """
            )
        } catch {
            failedAtmosphereRevisionKey = key

            print(
                """
                [PlagueForest] FATAL atmosphere swap failed once
                  key: \(key)
                  error: \(error.localizedDescription)
                  retrySuppressedUntilRevisionChanges: true
                  noFallback: true
                  preservedPreviousAtmosphere: \(activeAtmosphere?.rawValue ?? "none")
                """
            )

            onStrictAtmosphereFailure?(error)
        }
    }

    func applyIBLReceiverRecursively(
        root: Entity
    ) {
        root.components.set(
            ImageBasedLightReceiverComponent(
                imageBasedLight: lightingEntity
            )
        )

        for child in root.children {
            applyIBLReceiverRecursively(root: child)
        }
    }

    func shutdown() {
        for entity in splatEntities {
            entity.removeFromParent()
        }

        splatEntities.removeAll()
        environmentRoot.removeFromParent()
        sceneRoot = nil
        isInstalled = false
        activeAtmosphere = nil
        activeRevision = -1
        isSwapInFlight = false
        failedAtmosphereRevisionKey = nil

        print("[PlagueForest] environment shutdown")
    }

    private func applyAtmosphereAtomically(
        atmosphere: PlagueForestAtmosphere
    ) async throws {
        let newSplatEntities = try await loadNativeGaussianSplatEntities(
            atmosphere: atmosphere
        )

        guard !newSplatEntities.isEmpty else {
            throw NSError(
                domain: "PlagueForest",
                code: 600,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Native Gaussian splat loader returned zero entities. No fallback allowed."
                ]
            )
        }

        let hdri = try loadHDRIEnvironment(
            atmosphere: atmosphere
        )

        for old in splatEntities {
            old.removeFromParent()
        }

        splatEntities.removeAll()

        for entity in newSplatEntities {
            splatRoot.addChild(entity)
        }

        splatEntities = newSplatEntities

        applyHDRILighting(
            hdri,
            atmosphere: atmosphere
        )

        applyIBLReceiverRecursively(
            root: environmentRoot
        )

        if let sceneRoot {
            applyIBLReceiverRecursively(
                root: sceneRoot
            )
        }

        print(
            """
            [PlagueForest] strict atmosphere applied
              atmosphere: \(atmosphere.rawValue)
              splatEntityCount: \(newSplatEntities.count)
              hdri: \(atmosphere.hdriResourceName).\(atmosphere.hdriFileExtension)
              atomicPairing: true
              noFallback: true
            """
        )
    }

    private func loadNativeGaussianSplatEntities(
        atmosphere: PlagueForestAtmosphere
    ) async throws -> [Entity] {
        guard let url = Bundle.main.url(
            forResource: atmosphere.gaussianSplatResourceName,
            withExtension: atmosphere.gaussianSplatFileExtension
        ) else {
            throw NSError(
                domain: "PlagueForest",
                code: 404,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Missing Gaussian splat \(atmosphere.gaussianSplatResourceName).\(atmosphere.gaussianSplatFileExtension)"
                ]
            )
        }

        try PlagueGaussianSplatAvailability.assertNativeAvailable()

        let entities = try await PlagueGaussianSplatCache.shared.entities(
            for: atmosphere,
            sourceURL: url
        )

        print(
            """
            [PlagueForest] loaded native Gaussian splat entities
              atmosphere: \(atmosphere.rawValue)
              file: \(url.lastPathComponent)
              entityCount: \(entities.count)
            """
        )

        return entities
    }

    private func loadHDRIEnvironment(
        atmosphere: PlagueForestAtmosphere
    ) throws -> EnvironmentResource {
        guard let url = Bundle.main.url(
            forResource: atmosphere.hdriResourceName,
            withExtension: atmosphere.hdriFileExtension
        ) else {
            throw NSError(
                domain: "PlagueForest",
                code: 405,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Missing HDRI \(atmosphere.hdriResourceName).\(atmosphere.hdriFileExtension)"
                ]
            )
        }

        print(
            """
            [PlagueForest] loading HDRI
              atmosphere: \(atmosphere.rawValue)
              file: \(url.lastPathComponent)
            """
        )

        let environment = try EnvironmentResource.load(
            named: atmosphere.hdriResourceName
        )

        print(
            """
            [PlagueForest] HDRI loaded
              atmosphere: \(atmosphere.rawValue)
              resource: \(atmosphere.hdriResourceName).\(atmosphere.hdriFileExtension)
            """
        )

        return environment
    }

    private func applyHDRILighting(
        _ environment: EnvironmentResource,
        atmosphere: PlagueForestAtmosphere
    ) {
        let ibl = ImageBasedLightComponent(
            source: .single(environment),
            intensityExponent: atmosphere.iblIntensityExponent
        )

        lightingEntity.components.set(ibl)

        print(
            """
            [PlagueForest] HDRI lighting component applied
              atmosphere: \(atmosphere.rawValue)
              intensityExponent: \(atmosphere.iblIntensityExponent)
            """
        )
    }
}
