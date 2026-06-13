import Foundation
import ImageIO
import RealityKit
import simd

enum PlagueImmersiveSpaceID {
    static let forest = "plague-forest-immersive-space"
}

enum PlagueForestAtmosphere: String, Codable, CaseIterable, Identifiable, Hashable {
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

enum PlagueGaussianSplatStreamState: String {
    case idle
    case planning
    case loadingHDRI
    case decoding
    case creatingNativeResource
    case addingChunkEntity
    case streaming
    case complete
    case failed
    case cancelled
}

struct PlagueGaussianSplatStreamKey: Hashable {
    let atmosphere: PlagueForestAtmosphere
    let revision: Int
}

enum PlagueGaussianSplatStreamTuning {
    nonisolated static let firstChunkSize = 50_000
    nonisolated static let laterChunkSize = 150_000

    // Set only while debugging native resource caps. Nil means stream every chunk.
    nonisolated static let stopAfterChunkForDebug: Int? = nil
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
final class PlagueGaussianForestEnvironmentController {
    private let environmentRoot = Entity()
    private let splatRoot = Entity()
    private let lightingEntity = Entity()

    private weak var sceneRoot: Entity?
    private var isInstalled = false
    private var activeAtmosphere: PlagueForestAtmosphere?
    private var activeRevision = -1

    private var activeStreamKey: PlagueGaussianSplatStreamKey?
    private var completedStreamKey: PlagueGaussianSplatStreamKey?
    private var failedStreamKey: PlagueGaussianSplatStreamKey?
    private var streamState: PlagueGaussianSplatStreamState = .idle
    private var activeStreamTask: Task<Void, Never>?

    private var currentRoot: Entity?
    private var pendingRoot: Entity?
    private var currentChunkEntities: [Entity] = []
    private var pendingChunkEntities: [Entity] = []
    private var currentChunkHandles: [PlagueNativeSplatChunkHandle] = []
    private var pendingChunkHandles: [PlagueNativeSplatChunkHandle] = []

    private var loadedChunkCount = 0
    private var expectedChunkCount = 0
    private var loadedSplatCount = 0
    private var expectedSplatCount = 0

    var onStrictAtmosphereFailure: ((Error) -> Void)?
    var onSplatLoadStatusChanged: ((String) -> Void)?

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
        let key = PlagueGaussianSplatStreamKey(
            atmosphere: atmosphere,
            revision: revision
        )

        if !force {
            if completedStreamKey == key {
                return
            }

            if activeStreamKey == key,
               streamState != .failed,
               streamState != .cancelled {
                return
            }

            if failedStreamKey == key {
                print(
                    """
                    [PlagueForest] skipped retry for failed stream key
                      atmosphere: \(atmosphere.rawValue)
                      revision: \(revision)
                      change revision to retry
                    """
                )

                return
            }
        }

        startAtmosphereStream(
            atmosphere: atmosphere,
            revision: revision
        )
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
        activeStreamTask?.cancel()
        activeStreamTask = nil
        pendingRoot?.removeFromParent()
        currentRoot?.removeFromParent()
        pendingRoot = nil
        currentRoot = nil
        pendingChunkEntities.removeAll()
        currentChunkEntities.removeAll()
        pendingChunkHandles.removeAll()
        currentChunkHandles.removeAll()
        environmentRoot.removeFromParent()
        sceneRoot = nil
        isInstalled = false
        activeAtmosphere = nil
        activeRevision = -1
        activeStreamKey = nil
        completedStreamKey = nil
        failedStreamKey = nil
        streamState = .idle
        loadedChunkCount = 0
        expectedChunkCount = 0
        loadedSplatCount = 0
        expectedSplatCount = 0

        print("[PlagueForest] environment shutdown")
    }

    private func startAtmosphereStream(
        atmosphere: PlagueForestAtmosphere,
        revision: Int
    ) {
        let key = PlagueGaussianSplatStreamKey(
            atmosphere: atmosphere,
            revision: revision
        )

        if activeStreamKey == key,
           streamState != .failed,
           streamState != .cancelled {
            print(
                """
                [PlagueForest] stream already active
                  atmosphere: \(atmosphere.rawValue)
                  revision: \(revision)
                  state: \(streamState.rawValue)
                  loadedChunks: \(loadedChunkCount)/\(expectedChunkCount)
                """
            )

            return
        }

        cancelActiveStreamForReplacement()

        activeStreamKey = key
        failedStreamKey = nil
        streamState = .planning
        loadedChunkCount = 0
        expectedChunkCount = 0
        loadedSplatCount = 0
        expectedSplatCount = 0
        pendingChunkEntities.removeAll()
        pendingChunkHandles.removeAll()

        let newRoot = Entity()
        newRoot.name = "GaussianSplatPendingRoot_\(atmosphere.rawValue)_rev\(revision)"
        newRoot.isEnabled = true
        applyCurrentSplatPlacement(
            to: newRoot
        )

        splatRoot.addChild(newRoot)
        pendingRoot = newRoot

        print(
            """
            [PlagueForest] stream started
              atmosphere: \(atmosphere.rawValue)
              revision: \(revision)
              root: \(newRoot.name)
              noFallback: true
            """
        )

        emitSplatStatus("Forest \(atmosphere.displayName): planning stream.")

        activeStreamTask = Task { [weak self] in
            await self?.runAtmosphereStream(
                key: key,
                atmosphere: atmosphere,
                root: newRoot
            )
        }

        startStreamWatchdog(
            key: key
        )
    }

    private func cancelActiveStreamForReplacement() {
        if let activeStreamTask {
            activeStreamTask.cancel()

            print(
                """
                [PlagueForest] cancelling previous stream
                  activeKey: \(String(describing: activeStreamKey))
                  loadedChunks: \(loadedChunkCount)/\(expectedChunkCount)
                """
            )
        }

        activeStreamTask = nil

        if let pendingRoot {
            pendingRoot.removeFromParent()
        }

        pendingRoot = nil
        pendingChunkEntities.removeAll()
        pendingChunkHandles.removeAll()
    }

    private func runAtmosphereStream(
        key: PlagueGaussianSplatStreamKey,
        atmosphere: PlagueForestAtmosphere,
        root: Entity
    ) async {
        do {
            try Task.checkCancellation()
            try PlagueGaussianSplatAvailability.assertNativeAvailable()

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

            streamState = .loadingHDRI

            let hdri = try loadHDRIEnvironment(
                atmosphere: atmosphere
            )

            try Task.checkCancellation()

            streamState = .planning

            let planTask = Task.detached(priority: .userInitiated) {
                try PlagueGaussianSplatChunkPlanner.makePlan(
                    url: plyURL,
                    firstVisibleChunkSize: PlagueGaussianSplatStreamTuning.firstChunkSize,
                    maxSplatsPerChunk: PlagueGaussianSplatStreamTuning.laterChunkSize
                )
            }

            let plan = try await withTaskCancellationHandler {
                try await planTask.value
            } onCancel: {
                planTask.cancel()
            }

            expectedChunkCount = plan.chunkCount
            expectedSplatCount = plan.header.vertexCount

            print(
                """
                [PlagueForest] stream plan ready
                  atmosphere: \(atmosphere.rawValue)
                  revision: \(key.revision)
                  expectedChunks: \(expectedChunkCount)
                  expectedSplats: \(expectedSplatCount)
                  firstChunkSize: \(PlagueGaussianSplatStreamTuning.firstChunkSize)
                  laterChunkSize: \(PlagueGaussianSplatStreamTuning.laterChunkSize)
                  noFallback: true
                """
            )

            let sphericalHarmonicsDegree = inferredSphericalHarmonicsDegree(
                layout: plan.layout
            )

            if sphericalHarmonicsDegree == 0 {
                print(
                    """
                    [PlagueForest] spherical harmonics degree is 0
                      file: \(plyURL.lastPathComponent)
                      meaning: DC color only; not a loading failure
                      f_rest properties absent or not detected
                    """
                )
            }

            emitSplatStatus("Forest \(atmosphere.displayName): 0/\(expectedChunkCount) chunks, 0%.")

            try Task.checkCancellation()

            applyHDRILighting(
                hdri,
                atmosphere: atmosphere,
                lightingEntity: lightingEntity,
                receiverRoot: root
            )

            for chunkIndex in 0..<plan.chunkCount {
                try Task.checkCancellation()

                guard activeStreamKey == key else {
                    throw CancellationError()
                }

                if let stop = PlagueGaussianSplatStreamTuning.stopAfterChunkForDebug,
                   chunkIndex >= stop {
                    throw NSError(
                        domain: "PlagueForestDebug",
                        code: 900,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Debug stopAfterChunkForDebug hit at chunk \(chunkIndex)."
                        ]
                    )
                }

                streamState = .decoding

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

                guard activeStreamKey == key else {
                    throw CancellationError()
                }

                streamState = .creatingNativeResource

                let handle: PlagueNativeSplatChunkHandle

                do {
                    handle = try PlagueRealityKitGaussianSplatBridge.makeHandle(
                        chunk: chunk
                    )
                } catch {
                    throw NSError(
                        domain: "PlagueForestChunkCreate",
                        code: chunkIndex,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                """
                                Failed creating native Gaussian splat entity for chunk \(chunkIndex).
                                loadedChunks=\(loadedChunkCount)/\(expectedChunkCount)
                                chunkSplats=\(chunk.count)
                                underlying=\(error.localizedDescription)
                                """
                        ]
                    )
                }

                handle.entity.name = "GaussianSplat_\(atmosphere.rawValue)_chunk\(chunkIndex)"

                streamState = .addingChunkEntity

                root.addChild(handle.entity)
                pendingChunkEntities.append(handle.entity)
                pendingChunkHandles.append(handle)

                loadedChunkCount += 1
                loadedSplatCount += chunk.count

                let percent = Double(loadedSplatCount)
                    / Double(max(expectedSplatCount, 1))
                    * 100.0

                print(
                    """
                    [PlagueForest] native chunk added
                      atmosphere: \(atmosphere.rawValue)
                      revision: \(key.revision)
                      chunk: \(loadedChunkCount)/\(expectedChunkCount)
                      chunkIndex: \(chunkIndex)
                      chunkSplats: \(chunk.count)
                      loadedSplats: \(loadedSplatCount)/\(expectedSplatCount)
                      percent: \(String(format: "%.1f", percent))%
                      noFallback: true
                    """
                )

                emitSplatStatus(
                    "Forest \(atmosphere.displayName): \(loadedChunkCount)/\(expectedChunkCount) chunks, \(Int(percent))%."
                )

                if chunkIndex == 0 {
                    markFirstChunkVisible(
                        key: key,
                        atmosphere: atmosphere,
                        root: root
                    )
                }

                streamState = .streaming

                try? await Task.sleep(nanoseconds: 1_000_000)
                await Task.yield()
            }

            guard activeStreamKey == key else {
                throw CancellationError()
            }

            streamState = .complete
            completedStreamKey = key
            activeStreamTask = nil

            assert(
                loadedChunkCount == expectedChunkCount,
                "Stream marked complete before all chunks loaded."
            )
            assert(
                loadedSplatCount == expectedSplatCount,
                "Stream marked complete before all splats loaded."
            )

            currentChunkEntities = pendingChunkEntities
            pendingChunkEntities.removeAll()
            currentChunkHandles = pendingChunkHandles
            pendingChunkHandles.removeAll()

            print(
                """
                [PlagueForest] stream complete
                  atmosphere: \(atmosphere.rawValue)
                  revision: \(key.revision)
                  chunks: \(loadedChunkCount)/\(expectedChunkCount)
                  splats: \(loadedSplatCount)/\(expectedSplatCount)
                  percent: 100.0%
                  noFallback: true
                """
            )

            emitSplatStatus("Forest \(atmosphere.displayName): complete, 100%.")
        } catch is CancellationError {
            if activeStreamKey == key {
                streamState = .cancelled
                activeStreamTask = nil
            }

            print(
                """
                [PlagueForest] stream cancelled
                  key: \(key)
                  loadedChunks: \(loadedChunkCount)/\(expectedChunkCount)
                  loadedSplats: \(loadedSplatCount)/\(expectedSplatCount)
                """
            )
        } catch {
            guard activeStreamKey == key else {
                return
            }

            streamState = .failed
            failedStreamKey = key
            activeStreamTask = nil

            print(
                """
                [PlagueForest] FATAL stream failed
                  atmosphere: \(atmosphere.rawValue)
                  revision: \(key.revision)
                  state: \(streamState.rawValue)
                  loadedChunks: \(loadedChunkCount)/\(expectedChunkCount)
                  loadedSplats: \(loadedSplatCount)/\(expectedSplatCount)
                  error: \(error.localizedDescription)
                  noFallback: true
                """
            )

            emitSplatStatus(
                "Forest \(atmosphere.displayName): failed at \(loadedChunkCount)/\(expectedChunkCount) chunks."
            )

            if loadedChunkCount == 0 {
                pendingRoot?.removeFromParent()
                pendingRoot = nil
                onStrictAtmosphereFailure?(error)
            }
        }
    }

    private func markFirstChunkVisible(
        key: PlagueGaussianSplatStreamKey,
        atmosphere: PlagueForestAtmosphere,
        root: Entity
    ) {
        guard activeStreamKey == key else {
            return
        }

        if currentRoot !== root {
            if let old = currentRoot {
                old.removeFromParent()
            }

            currentRoot = root
        }

        if pendingRoot === root {
            pendingRoot = nil
        }

        activeAtmosphere = atmosphere
        activeRevision = key.revision

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
            [PlagueForest] first chunk visible
              atmosphere: \(atmosphere.rawValue)
              revision: \(key.revision)
              rootStillAlive: \(root.parent != nil)
              streamContinues: true
              loadedChunks: \(loadedChunkCount)/\(expectedChunkCount)
              noFallback: true
            """
        )

        print(
            """
            [PlagueForest] atmosphere active
              atmosphere: \(atmosphere.rawValue)
              revision: \(key.revision)
              ply: \(atmosphere.gaussianSplatResourceName).\(atmosphere.gaussianSplatFileExtension)
              hdri: \(atmosphere.hdriResourceName).\(atmosphere.hdriFileExtension)
            """
        )
    }

    private func startStreamWatchdog(
        key: PlagueGaussianSplatStreamKey
    ) {
        Task { @MainActor in
            var lastLoaded = -1

            while activeStreamKey == key,
                  streamState != .complete,
                  streamState != .failed,
                  streamState != .cancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                guard activeStreamKey == key else {
                    return
                }

                if loadedChunkCount == lastLoaded {
                    print(
                        """
                        [PlagueForest] WARNING stream progress stalled
                          key: \(key)
                          state: \(streamState.rawValue)
                          loadedChunks: \(loadedChunkCount)/\(expectedChunkCount)
                          loadedSplats: \(loadedSplatCount)/\(expectedSplatCount)
                          rootAlive: \(currentRoot?.parent != nil || pendingRoot?.parent != nil)
                          taskCancelled: \(activeStreamTask?.isCancelled ?? true)
                        """
                    )
                } else {
                    print(
                        """
                        [PlagueForest] stream progress
                          key: \(key)
                          state: \(streamState.rawValue)
                          loadedChunks: \(loadedChunkCount)/\(expectedChunkCount)
                          loadedSplats: \(loadedSplatCount)/\(expectedSplatCount)
                        """
                    )
                }

                lastLoaded = loadedChunkCount
            }
        }
    }

    private func applyCurrentSplatPlacement(
        to root: Entity
    ) {
        let placement = PlagueGaussianSplatPlacement()
        root.position = placement.position
        root.scale = SIMD3<Float>(repeating: placement.scale)
        root.orientation = placement.rotation

        print(
            """
            [PlagueForest] splat root placement
              position: \(root.position)
              scale: \(root.scale)
              orientation: \(root.orientation.vector)
            """
        )
    }

    private func inferredSphericalHarmonicsDegree(
        layout: PlaguePLYBinaryVertexLayout
    ) -> Int {
        let restCount = layout.properties.keys.filter {
            $0.hasPrefix("f_rest_")
        }.count

        if restCount >= 45 {
            return 3
        }

        return 0
    }

    private func emitSplatStatus(
        _ status: String
    ) {
        onSplatLoadStatusChanged?(status)
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
