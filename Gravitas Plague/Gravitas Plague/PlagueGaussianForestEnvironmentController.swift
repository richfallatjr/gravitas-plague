import Foundation
import ImageIO
import RealityKit
import simd

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

struct PlagueGaussianSplatPlacement {
    var scale: Float = 1.0
    var position = SIMD3<Float>(0, 0, -2.0)
    var rotation = simd_quatf(
        angle: 0,
        axis: SIMD3<Float>(0, 1, 0)
    )
}

@MainActor
private func applyHDRILighting(
    _ environment: EnvironmentResource,
    atmosphere: PlagueForestAtmosphere,
    lightingEntity: Entity,
    receiverRoot: Entity
) {
    let ibl = ImageBasedLightComponent(
        source: .single(environment),
        intensityExponent: atmosphere.iblIntensityExponent
    )

    lightingEntity.components.set(ibl)

    applyIBLReceiverRecursively(
        root: receiverRoot,
        lightingEntity: lightingEntity
    )

    print(
        """
        [PlagueForest] HDRI applied before splat visibility
          atmosphere: \(atmosphere.rawValue)
          hdri: \(atmosphere.hdriResourceName).\(atmosphere.hdriFileExtension)
          intensityExponent: \(atmosphere.iblIntensityExponent)
        """
    )
}

@MainActor
private func applyIBLReceiverRecursively(
    root: Entity,
    lightingEntity: Entity
) {
    root.components.set(
        ImageBasedLightReceiverComponent(
            imageBasedLight: lightingEntity
        )
    )

    for child in root.children {
        applyIBLReceiverRecursively(
            root: child,
            lightingEntity: lightingEntity
        )
    }
}

@MainActor
final class PlagueStreamingGaussianSplatLoader {
    private var activeTask: Task<Void, Never>?

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    func load(
        atmosphere: PlagueForestAtmosphere,
        plyURL: URL,
        hdri: EnvironmentResource,
        splatRoot: Entity,
        lightingEntity: Entity,
        onFirstChunkVisible: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void,
        onComplete: @escaping @MainActor (Int) -> Void
    ) {
        cancel()

        activeTask = Task { @MainActor in
            do {
                try Task.checkCancellation()

                let planTask = Task.detached(priority: .userInitiated) {
                    try PlagueGaussianSplatChunkPlanner.makePlan(
                        url: plyURL
                    )
                }

                let plan = try await withTaskCancellationHandler {
                    try await planTask.value
                } onCancel: {
                    planTask.cancel()
                }

                try Task.checkCancellation()

                applyHDRILighting(
                    hdri,
                    atmosphere: atmosphere,
                    lightingEntity: lightingEntity,
                    receiverRoot: splatRoot
                )

                var createdCount = 0

                for chunkIndex in 0..<plan.chunkCount {
                    try Task.checkCancellation()

                    let decodeTask = Task.detached(priority: .userInitiated) {
                        try PlagueGaussianSplatChunkDecoder.decodeChunk(
                            plan: plan,
                            chunkIndex: chunkIndex
                        )
                    }

                    let chunk = try await withTaskCancellationHandler {
                        try await decodeTask.value
                    } onCancel: {
                        decodeTask.cancel()
                    }

                    try Task.checkCancellation()

                    let entity = try PlagueRealityKitGaussianSplatBridge.makeEntity(
                        chunk: chunk
                    )

                    entity.name = "GaussianSplat_\(atmosphere.rawValue)_chunk\(chunkIndex)"
                    splatRoot.addChild(entity)

                    createdCount += 1

                    print(
                        """
                        [PlagueGaussianSplat] native chunk entity added
                          atmosphere: \(atmosphere.rawValue)
                          chunkIndex: \(chunkIndex)
                          chunkCount: \(plan.chunkCount)
                          splats: \(chunk.count)
                          createdEntities: \(createdCount)
                          noFallback: true
                        """
                    )

                    if chunkIndex == 0 {
                        onFirstChunkVisible()
                    }

                    await Task.yield()
                }

                onComplete(createdCount)
            } catch is CancellationError {
                print(
                    """
                    [PlagueGaussianSplat] streaming load cancelled
                      atmosphere: \(atmosphere.rawValue)
                    """
                )
            } catch {
                onFailure(error)
            }
        }
    }
}

@MainActor
final class PlagueGaussianForestEnvironmentController {
    private let environmentRoot = Entity()
    private let splatRoot = Entity()
    private let lightingEntity = Entity()
    private let streamingLoader = PlagueStreamingGaussianSplatLoader()

    private weak var sceneRoot: Entity?
    private var isInstalled = false
    private var activeAtmosphere: PlagueForestAtmosphere?
    private var activeRevision = -1
    private var isSwapInFlight = false
    private var failedAtmosphereRevisionKey: String?
    private var inFlightAtmosphereRevisionKey: String?
    private var currentRoot: Entity?
    private var pendingRoot: Entity?
    private var atmosphereGeneration = 0

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
        requestAtmosphere(
            atmosphere,
            revision: revision,
            force: force
        )
    }

    private func requestAtmosphere(
        _ atmosphere: PlagueForestAtmosphere,
        revision: Int,
        force: Bool = false
    ) {
        let key = "\(atmosphere.rawValue)|\(revision)"

        guard force ||
              activeAtmosphere != atmosphere ||
              activeRevision != revision else {
            return
        }

        if failedAtmosphereRevisionKey == key,
           !force {
            return
        }

        if isSwapInFlight,
           inFlightAtmosphereRevisionKey == key {
            return
        }

        streamingLoader.cancel()
        pendingRoot?.removeFromParent()
        pendingRoot = nil

        isSwapInFlight = true
        inFlightAtmosphereRevisionKey = key
        atmosphereGeneration += 1

        let generation = atmosphereGeneration

        do {
            try startStreamingAtmosphere(
                atmosphere: atmosphere,
                revision: revision,
                key: key,
                generation: generation
            )
        } catch {
            failedAtmosphereRevisionKey = key
            isSwapInFlight = false
            inFlightAtmosphereRevisionKey = nil

            print(
                """
                [PlagueForest] FATAL atmosphere start failed
                  atmosphere: \(atmosphere.rawValue)
                  revision: \(revision)
                  error: \(error.localizedDescription)
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
        streamingLoader.cancel()
        pendingRoot?.removeFromParent()
        currentRoot?.removeFromParent()
        pendingRoot = nil
        currentRoot = nil
        environmentRoot.removeFromParent()
        sceneRoot = nil
        isInstalled = false
        activeAtmosphere = nil
        activeRevision = -1
        isSwapInFlight = false
        failedAtmosphereRevisionKey = nil
        inFlightAtmosphereRevisionKey = nil
        atmosphereGeneration += 1

        print("[PlagueForest] environment shutdown")
    }

    private func startStreamingAtmosphere(
        atmosphere: PlagueForestAtmosphere,
        revision: Int,
        key: String,
        generation: Int
    ) throws {
        guard let plyURL = Bundle.main.url(
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

        let hdri = try loadHDRIEnvironment(
            atmosphere: atmosphere
        )

        let placement = PlagueGaussianSplatPlacement()
        let newRoot = Entity()
        newRoot.name = "GaussianSplatStreamingRoot_\(atmosphere.rawValue)_rev\(revision)"
        newRoot.position = placement.position
        newRoot.scale = SIMD3<Float>(repeating: placement.scale)
        newRoot.orientation = placement.rotation

        splatRoot.addChild(newRoot)
        pendingRoot = newRoot

        print(
            """
            [PlagueForest] streaming atmosphere begin
              atmosphere: \(atmosphere.rawValue)
              revision: \(revision)
              ply: \(plyURL.lastPathComponent)
              hdri: \(atmosphere.hdriResourceName).\(atmosphere.hdriFileExtension)
              waitingOnlyForFirstChunk: true
              noFallback: true
            """
        )

        print(
            """
            [PlagueForest] splat root placement
              position: \(newRoot.position)
              scale: \(newRoot.scale)
              orientation: \(newRoot.orientation.vector)
            """
        )

        streamingLoader.load(
            atmosphere: atmosphere,
            plyURL: plyURL,
            hdri: hdri,
            splatRoot: newRoot,
            lightingEntity: lightingEntity,
            onFirstChunkVisible: { [weak self, weak newRoot] in
                guard let self,
                      let newRoot,
                      generation == self.atmosphereGeneration else {
                    newRoot?.removeFromParent()
                    return
                }

                if let old = self.currentRoot,
                   old !== newRoot {
                    old.removeFromParent()
                }

                self.currentRoot = newRoot
                self.pendingRoot = nil
                self.activeAtmosphere = atmosphere
                self.activeRevision = revision
                self.failedAtmosphereRevisionKey = nil

                if self.inFlightAtmosphereRevisionKey == key {
                    self.isSwapInFlight = false
                    self.inFlightAtmosphereRevisionKey = nil
                }

                self.applyIBLReceiverRecursively(
                    root: self.environmentRoot
                )

                if let sceneRoot = self.sceneRoot {
                    self.applyIBLReceiverRecursively(
                        root: sceneRoot
                    )
                }

                print(
                    """
                    [PlagueForest] first native splat chunk visible
                      atmosphere: \(atmosphere.rawValue)
                      revision: \(revision)
                      oldRemovedAfterFirstChunk: true
                      noFallback: true
                    """
                )

                print(
                    """
                    [PlagueForest] atmosphere active
                      atmosphere: \(atmosphere.rawValue)
                      revision: \(revision)
                      ply: \(atmosphere.gaussianSplatResourceName).\(atmosphere.gaussianSplatFileExtension)
                      hdri: \(atmosphere.hdriResourceName).\(atmosphere.hdriFileExtension)
                    """
                )
            },
            onFailure: { [weak self, weak newRoot] error in
                guard let self else {
                    return
                }

                if generation != self.atmosphereGeneration {
                    newRoot?.removeFromParent()
                    return
                }

                self.failedAtmosphereRevisionKey = key

                if self.inFlightAtmosphereRevisionKey == key {
                    self.isSwapInFlight = false
                    self.inFlightAtmosphereRevisionKey = nil
                }

                if self.currentRoot == nil {
                    print(
                        """
                        [PlagueForest] FATAL first atmosphere failed
                          atmosphere: \(atmosphere.rawValue)
                          error: \(error.localizedDescription)
                          noFallback: true
                        """
                    )
                } else {
                    print(
                        """
                        [PlagueForest] atmosphere stream failed; preserving current
                          requested: \(atmosphere.rawValue)
                          current: \(self.activeAtmosphere?.rawValue ?? "none")
                          error: \(error.localizedDescription)
                          noFallback: true
                        """
                    )
                }

                newRoot?.removeFromParent()
                self.pendingRoot = nil
                self.onStrictAtmosphereFailure?(error)
            },
            onComplete: { [weak self] entityCount in
                guard let self,
                      generation == self.atmosphereGeneration else {
                    return
                }

                if self.inFlightAtmosphereRevisionKey == key {
                    self.isSwapInFlight = false
                    self.inFlightAtmosphereRevisionKey = nil
                }

                print(
                    """
                    [PlagueForest] atmosphere stream complete
                      atmosphere: \(atmosphere.rawValue)
                      revision: \(revision)
                      nativeEntities: \(entityCount)
                      noFallback: true
                    """
                )
            }
        )
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

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(
                domain: "PlagueForest",
                code: 406,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "ImageIO could not open HDRI EXR \(url.lastPathComponent)"
                ]
            )
        }

        guard let image = CGImageSourceCreateImageAtIndex(
            source,
            0,
            nil
        ) else {
            throw NSError(
                domain: "PlagueForest",
                code: 407,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "ImageIO could not decode HDRI EXR \(url.lastPathComponent)"
                ]
            )
        }

        let options = EnvironmentResource.CreateOptions(
            samplingQuality: .fast,
            specularCubeDimension: nil,
            compression: .default
        )

        let environment = try EnvironmentResource(
            equirectangular: image,
            options: options
        )

        print(
            """
            [PlagueForest] HDRI loaded
              atmosphere: \(atmosphere.rawValue)
              resource: \(atmosphere.hdriResourceName).\(atmosphere.hdriFileExtension)
              source: raw EXR via ImageIO + EnvironmentResource(equirectangular:)
              pixelWidth: \(image.width)
              pixelHeight: \(image.height)
            """
        )

        return environment
    }

}
