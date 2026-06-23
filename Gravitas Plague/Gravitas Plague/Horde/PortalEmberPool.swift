import Foundation
import RealityKit
import simd

private enum PortalEmberMaterialPhase: Sendable {
    case birth
    case hot
    case red
    case dark
}

private struct PortalEmberFrameUpdate: Sendable {
    let index: Int
    let active: Bool
    let position: SIMD3<Float>
    let orientation: simd_quatf
    let size: Float
    let materialPhase: PortalEmberMaterialPhase
    let materialIndex: Int
}

private struct PortalEmberFrameOutput: Sendable {
    let updates: [PortalEmberFrameUpdate]
}

private struct PortalEmberParticleState: Sendable {
    var active: Bool = false

    var age: Float = 0
    var life: Float = 1.8

    var position: SIMD3<Float> = .zero
    var velocity: SIMD3<Float> = .zero
    var orientation = simd_quatf(
        angle: 0,
        axis: SIMD3<Float>(0, 1, 0)
    )

    var startSize: Float = 0.008
    var endSize: Float = 0.003

    var birthMaterialIndex: Int = 0
    var hotMaterialIndex: Int = 0
    var redMaterialIndex: Int = 0
    var darkMaterialIndex: Int = 0

    var spinRadiansPerSecond: Float = 0
}

private struct PortalEmberCompletedSimulation {
    let revision: Int
    let output: PortalEmberFrameOutput
}

private struct PortalEmberMaterialCounts: Sendable {
    let birth: Int
    let hot: Int
    let red: Int
    let dark: Int
}

private actor PortalFXStepper {
    private var states: [PortalEmberParticleState]
    private var nextIndex: Int = 0
    private let materialCounts: PortalEmberMaterialCounts

    init(
        capacity: Int,
        materialCounts: PortalEmberMaterialCounts
    ) {
        self.states = Array(
            repeating: PortalEmberParticleState(),
            count: capacity
        )
        self.materialCounts = materialCounts
    }

    func reset() {
        states = Array(
            repeating: PortalEmberParticleState(),
            count: states.count
        )
        nextIndex = 0
    }

    func step(
        spawnSamples: [PortalFXSpawnSample],
        deltaTime: Float
    ) -> PortalEmberFrameOutput {
        for sample in spawnSamples {
            spawn(sample)
        }

        let output = PortalEmberSimulationStepper.step(
            states: states,
            deltaTime: deltaTime
        )

        states = output.nextStates

        return PortalEmberFrameOutput(
            updates: output.updates
        )
    }

    private func spawn(
        _ sample: PortalFXSpawnSample
    ) {
        guard !states.isEmpty else {
            return
        }

        let index = nextIndex
        nextIndex = (nextIndex + 1) % states.count

        states[index] = PortalEmberParticleState(
            active: true,
            age: 0,
            life: sample.life,
            position: sample.position,
            velocity: sample.velocity,
            orientation: simd_quatf(
                angle: 0,
                axis: SIMD3<Float>(0, 1, 0)
            ),
            startSize: Float.random(
                in: PortalFXDefaults.emberStartSizeMetersMin...PortalFXDefaults.emberStartSizeMetersMax
            ),
            endSize: Float.random(
                in: PortalFXDefaults.emberEndSizeMetersMin...PortalFXDefaults.emberEndSizeMetersMax
            ),
            birthMaterialIndex: Int.random(
                in: 0..<max(materialCounts.birth, 1)
            ),
            hotMaterialIndex: Int.random(
                in: 0..<max(materialCounts.hot, 1)
            ),
            redMaterialIndex: Int.random(
                in: 0..<max(materialCounts.red, 1)
            ),
            darkMaterialIndex: Int.random(
                in: 0..<max(materialCounts.dark, 1)
            ),
            spinRadiansPerSecond: Float.random(in: -4.0...4.0)
        )
    }
}

private enum PortalEmberSimulationStepper {
    struct Output: Sendable {
        let nextStates: [PortalEmberParticleState]
        let updates: [PortalEmberFrameUpdate]
    }

    static func step(
        states: [PortalEmberParticleState],
        deltaTime: Float
    ) -> Output {
        var nextStates = states
        var updates: [PortalEmberFrameUpdate] = []

        for index in nextStates.indices {
            guard nextStates[index].active else {
                continue
            }

            nextStates[index].age += deltaTime

            let t = nextStates[index].age / max(
                nextStates[index].life,
                0.001
            )

            if t >= 1 {
                nextStates[index].active = false
                updates.append(
                    PortalEmberFrameUpdate(
                        index: index,
                        active: false,
                        position: nextStates[index].position,
                        orientation: nextStates[index].orientation,
                        size: nextStates[index].endSize,
                        materialPhase: .dark,
                        materialIndex: nextStates[index].darkMaterialIndex
                    )
                )
                continue
            }

            nextStates[index].velocity.y += 0.18 * deltaTime
            nextStates[index].position += nextStates[index].velocity * deltaTime

            let spin = nextStates[index].spinRadiansPerSecond * deltaTime
            nextStates[index].orientation =
                simd_quatf(
                    angle: spin,
                    axis: SIMD3<Float>(0, 1, 0)
                ) * nextStates[index].orientation

            let size = mix(
                nextStates[index].startSize,
                nextStates[index].endSize,
                t
            )

            let material = materialPhaseAndIndex(
                for: nextStates[index],
                normalizedAge: t
            )

            updates.append(
                PortalEmberFrameUpdate(
                    index: index,
                    active: true,
                    position: nextStates[index].position,
                    orientation: nextStates[index].orientation,
                    size: size,
                    materialPhase: material.phase,
                    materialIndex: material.index
                )
            )
        }

        return Output(
            nextStates: nextStates,
            updates: updates
        )
    }

    private static func mix(
        _ a: Float,
        _ b: Float,
        _ t: Float
    ) -> Float {
        a + (b - a) * t
    }

    private static func materialPhaseAndIndex(
        for ember: PortalEmberParticleState,
        normalizedAge t: Float
    ) -> (phase: PortalEmberMaterialPhase, index: Int) {
        switch t {
        case ..<0.18:
            return (.birth, ember.birthMaterialIndex)
        case ..<0.50:
            return (.hot, ember.hotMaterialIndex)
        case ..<0.84:
            return (.red, ember.redMaterialIndex)
        default:
            return (.dark, ember.darkMaterialIndex)
        }
    }
}

private struct PortalEmber {
    var entity: ModelEntity
    var active: Bool = false
}

@MainActor
final class PortalEmberPool {
    private let root: Entity
    private var embers: [PortalEmber] = []
    private let simulationEngine: PortalFXStepper
    private var simulationTask: Task<Void, Never>?
    private var simulationInFlight = false
    private var completedSimulation: PortalEmberCompletedSimulation?
    private var pendingSpawnSamples: [PortalFXSpawnSample] = []
    private var stateRevision = 0

    var activeCount: Int {
        embers.reduce(0) { partialResult, ember in
            partialResult + (ember.active ? 1 : 0)
        }
    }

    init(
        root: Entity,
        maxActive: Int
    ) {
        self.root = root

        let resources = PortalFXSharedResources.shared
        self.simulationEngine = PortalFXStepper(
            capacity: maxActive,
            materialCounts: PortalEmberMaterialCounts(
                birth: resources.emberBirthMaterials.count,
                hot: resources.emberHotMaterials.count,
                red: resources.emberRedMaterials.count,
                dark: resources.emberDarkMaterials.count
            )
        )

        embers.reserveCapacity(maxActive)

        for index in 0..<maxActive {
            let entity = ModelEntity(
                mesh: resources.emberMesh,
                materials: [resources.emberDarkMaterials[0]]
            )

            entity.name = "PortalEmber_\(index)"
            entity.isEnabled = false
            entity.scale = SIMD3<Float>(
                repeating: PortalFXDefaults.emberStartSizeMetersMax
            )

            root.addChild(entity)

            embers.append(
                PortalEmber(entity: entity)
            )
        }

        print(
            """
            [PortalEmberPool] created
              maxActive: \(maxActive)
            """
        )
    }

    func spawn(
        position: SIMD3<Float>,
        velocity: SIMD3<Float>,
        life: Float
    ) {
        enqueueSpawns(
            [
                PortalFXSpawnSample(
                    position: position,
                    velocity: velocity,
                    life: life
                )
            ]
        )
    }

    func enqueueSpawns(
        _ samples: [PortalFXSpawnSample]
    ) {
        pendingSpawnSamples.append(
            contentsOf: samples
        )
    }

    func update(
        deltaTime: Float
    ) {
        applyCompletedSimulationIfAvailable()
        submitSimulationIfIdle(
            deltaTime: deltaTime
        )
    }

    func update(
        deltaTime: Float,
        timingProfiler: TimingProfiler?
    ) {
        if let timingProfiler {
            timingProfiler.measure("portal.ember.apply") {
                applyCompletedSimulationIfAvailable()
            }

            timingProfiler.measure("portal.ember.submit") {
                submitSimulationIfIdle(
                    deltaTime: deltaTime
                )
            }
        } else {
            update(
                deltaTime: deltaTime
            )
        }
    }

    private func submitSimulationIfIdle(
        deltaTime: Float
    ) {
        guard !simulationInFlight,
              completedSimulation == nil else {
            return
        }

        guard activeCount > 0 || !pendingSpawnSamples.isEmpty else {
            return
        }

        let revision = stateRevision
        let engine = simulationEngine
        let spawnSamples = pendingSpawnSamples
        pendingSpawnSamples.removeAll()

        simulationInFlight = true

        simulationTask = Task.detached(priority: .userInitiated) { [weak self, engine, spawnSamples, deltaTime, revision] in
            let output = await engine.step(
                spawnSamples: spawnSamples,
                deltaTime: deltaTime
            )

            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                self?.receiveSimulation(
                    output,
                    revision: revision
                )
            }
        }
    }

    private func receiveSimulation(
        _ output: PortalEmberFrameOutput,
        revision: Int
    ) {
        simulationInFlight = false
        simulationTask = nil

        guard revision == stateRevision else {
            return
        }

        completedSimulation = PortalEmberCompletedSimulation(
            revision: revision,
            output: output
        )
    }

    private func applyCompletedSimulationIfAvailable() {
        guard let completedSimulation else {
            return
        }

        self.completedSimulation = nil

        guard completedSimulation.revision == stateRevision else {
            return
        }

        apply(
            completedSimulation.output
        )
    }

    private func apply(
        _ output: PortalEmberFrameOutput
    ) {
        let resources = PortalFXSharedResources.shared

        for update in output.updates {
            guard embers.indices.contains(update.index) else {
                continue
            }

            let entity = embers[update.index].entity

            guard update.active else {
                entity.isEnabled = false
                embers[update.index].active = false
                continue
            }

            entity.position = update.position
            entity.orientation = update.orientation
            entity.scale = SIMD3<Float>(
                repeating: update.size
            )
            entity.model?.materials = [
                material(
                    resources: resources,
                    phase: update.materialPhase,
                    index: update.materialIndex
                )
            ]
            entity.isEnabled = true
            embers[update.index].active = true
        }
    }

    func setEnabled(
        _ enabled: Bool
    ) {
        root.isEnabled = enabled
    }

    func teardown() {
        simulationTask?.cancel()
        simulationTask = nil
        simulationInFlight = false
        completedSimulation = nil
        pendingSpawnSamples.removeAll()
        stateRevision += 1
        let engine = simulationEngine
        Task {
            await engine.reset()
        }

        root.children.removeAll()
        embers.removeAll()
    }

    private func material(
        resources: PortalFXSharedResources,
        phase: PortalEmberMaterialPhase,
        index: Int
    ) -> RealityKit.Material {
        switch phase {
        case .birth:
            return material(
                in: resources.emberBirthMaterials,
                at: index
            )
        case .hot:
            return material(
                in: resources.emberHotMaterials,
                at: index
            )
        case .red:
            return material(
                in: resources.emberRedMaterials,
                at: index
            )
        case .dark:
            return material(
                in: resources.emberDarkMaterials,
                at: index
            )
        }
    }

    private func material(
        in materials: [RealityKit.Material],
        at index: Int
    ) -> RealityKit.Material {
        guard materials.indices.contains(index) else {
            return materials[0]
        }

        return materials[index]
    }
}
