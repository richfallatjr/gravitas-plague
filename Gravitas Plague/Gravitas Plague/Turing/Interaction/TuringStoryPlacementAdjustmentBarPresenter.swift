import Foundation
import RealityKit
import UIKit
import simd

enum TuringStoryPlacementAdjustmentBarVisualState: Sendable, Equatable {
    case idle
    case hover
    case pinched
    case snapping
}

@MainActor
protocol TuringStoryPlacementAdjustmentBarPresenting: AnyObject {
    func install(sceneRoot: Entity)
    func show(activeSlots: [TuringStoryPropID: TuringStoryRuntimeSlot])
    func preview(slot: TuringStoryRuntimeSlot, duration: TimeInterval)
    func commit(slot: TuringStoryRuntimeSlot)
    func worldRightAxis(for propID: TuringStoryPropID) -> SIMD3<Float>
    func setVisualState(
        _ state: TuringStoryPlacementAdjustmentBarVisualState,
        propID: TuringStoryPropID
    )
    func setEnabled(_ enabled: Bool, propID: TuringStoryPropID)
    func hideAll(reason: String)
}

struct TuringStoryAdjustmentWallBasis: Sendable {
    let wallID: UUID
    let center: SIMD3<Float>
    let right: SIMD3<Float>
    let up: SIMD3<Float>
    let normal: SIMD3<Float>
    let floorWorldY: Float?
}

@MainActor
protocol TuringStoryAdjustmentWallProviding: AnyObject {
    func turingStoryAdjustmentWallBasis(
        for wallID: UUID
    ) -> TuringStoryAdjustmentWallBasis?
}

extension WallPlaneManager: TuringStoryAdjustmentWallProviding {
    func turingStoryAdjustmentWallBasis(
        for wallID: UUID
    ) -> TuringStoryAdjustmentWallBasis? {
        guard let wall = wallCandidates[wallID] else {
            return nil
        }
        return TuringStoryAdjustmentWallBasis(
            wallID: wall.id,
            center: wall.center,
            right: wall.right,
            up: wall.up,
            normal: wall.normal,
            floorWorldY: bestFloorCandidate(near: wall)?.worldY
        )
    }
}

struct TuringStoryAdjustmentBarPoseResolver: Sendable {
    static let visibleHeight: Float = 0.025
    static let visibleDepth: Float = 0.006
    static let collisionHeight: Float = 0.055
    static let collisionDepth: Float = 0.025
    static let wallOutwardOffset: Float = 0.020
    static let belowVisualOffset: Float = 0.060
    static let doorCenterAboveFloor: Float = 0.120
    static let floorVisualClearance: Float = 0.010

    func visualWidth(
        for slot: TuringStoryRuntimeSlot
    ) -> Float {
        min(0.35, max(0.20, slot.placement.visualWidth * 0.40))
    }

    func worldTransform(
        slot: TuringStoryRuntimeSlot,
        wall: TuringStoryAdjustmentWallBasis
    ) -> simd_float4x4 {
        let right = normalized(
            wall.right,
            fallback: SIMD3<Float>(1, 0, 0)
        )
        let up = normalized(
            wall.up,
            fallback: SIMD3<Float>(0, 1, 0)
        )
        let normal = normalized(
            wall.normal,
            fallback: SIMD3<Float>(0, 0, 1)
        )

        let localY: Float
        switch slot.placement {
        case .door(let placement):
            if let floorY = placement.floorWorldY ?? wall.floorWorldY,
                abs(up.y) > 0.05
            {
                localY = (floorY + Self.doorCenterAboveFloor - wall.center.y) / up.y
            } else {
                localY = placement.localY - placement.height * 0.5 + Self.doorCenterAboveFloor
            }

        case .window(let placement):
            localY = placement.localY - placement.height * 0.5 - Self.belowVisualOffset

        case .walkieShelf(let placement):
            localY = placement.localY - placement.height * 0.5 - Self.belowVisualOffset

        case .poster(let placement):
            localY = placement.localY - placement.height * 0.5 - Self.belowVisualOffset
        }

        var position =
            wall.center + right * slot.placement.localX + up * localY + normal
            * (slot.placement.depthOffset + Self.wallOutwardOffset)

        if let floorY = slot.placement.floorWorldY ?? wall.floorWorldY {
            let minimumY = floorY + Self.visibleHeight * 0.5 + Self.floorVisualClearance
            if position.y < minimumY, abs(up.y) > 0.05 {
                position += up * ((minimumY - position.y) / up.y)
            }
        }

        var matrix = matrix_identity_float4x4
        matrix.columns.0 = SIMD4<Float>(right.x, right.y, right.z, 0)
        matrix.columns.1 = SIMD4<Float>(up.x, up.y, up.z, 0)
        matrix.columns.2 = SIMD4<Float>(normal.x, normal.y, normal.z, 0)
        matrix.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return matrix
    }

    private func normalized(
        _ value: SIMD3<Float>,
        fallback: SIMD3<Float>
    ) -> SIMD3<Float> {
        let length = simd_length(value)
        return length > 0.000_01 ? value / length : fallback
    }
}

@MainActor
enum TuringStoryAdjustmentBarMaterialFactory {
    static func make(
        opacity: Float
    ) -> PhysicallyBasedMaterial {
        var material = TuringStoryWindowGlassMaterialFactory.makeGlassMaterial()
        material.baseColor = .init(
            tint: UIColor(
                white: 1.0,
                alpha: CGFloat(opacity)
            )
        )
        material.blending = .transparent(
            opacity: .init(floatLiteral: opacity)
        )
        material.faceCulling = .none
        return material
    }

    static func makeIndicator(
        opacity: Float
    ) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(
            tint: UIColor(
                white: 1.0,
                alpha: CGFloat(opacity)
            )
        )
        material.blending = .transparent(
            opacity: .init(floatLiteral: opacity)
        )
        return material
    }
}

@MainActor
final class TuringStoryPlacementAdjustmentBarPresenter:
    TuringStoryPlacementAdjustmentBarPresenting
{

    private static let registerAdjustmentBarComponentOnce: Void = {
        TuringStoryPlacementAdjustmentBarComponent.registerComponent()
    }()

    private final class BarRecord {
        let container: Entity
        let visual: ModelEntity
        let indicator: ModelEntity
        var slot: TuringStoryRuntimeSlot
        var visibleSize: SIMD3<Float>
        var collisionSize: SIMD3<Float>
        var state: TuringStoryPlacementAdjustmentBarVisualState = .idle
        var interactionEnabled = true

        init(
            container: Entity,
            visual: ModelEntity,
            indicator: ModelEntity,
            slot: TuringStoryRuntimeSlot,
            visibleSize: SIMD3<Float>,
            collisionSize: SIMD3<Float>
        ) {
            self.container = container
            self.visual = visual
            self.indicator = indicator
            self.slot = slot
            self.visibleSize = visibleSize
            self.collisionSize = collisionSize
        }
    }

    private weak var wallProvider:
        (
            any TuringStoryAdjustmentWallProviding
        )?
    private let root = Entity()
    private let poseResolver = TuringStoryAdjustmentBarPoseResolver()
    private var records: [TuringStoryPropID: BarRecord] = [:]
    private var snapFlashTasks: [TuringStoryPropID: Task<Void, Never>] = [:]

    init(
        wallProvider: any TuringStoryAdjustmentWallProviding
    ) {
        self.wallProvider = wallProvider
        _ = Self.registerAdjustmentBarComponentOnce
        root.name = "TuringStoryPlacementAdjustmentBars_Root"
        root.isEnabled = false
    }

    func install(
        sceneRoot: Entity
    ) {
        if root.parent == nil {
            sceneRoot.addChild(root)
        }
    }

    func show(
        activeSlots: [TuringStoryPropID: TuringStoryRuntimeSlot]
    ) {
        for task in snapFlashTasks.values {
            task.cancel()
        }
        snapFlashTasks.removeAll()
        clearRecords()

        for propID in TuringStoryPropID.allCases {
            guard let slot = activeSlots[propID],
                let wall = wallProvider?.turingStoryAdjustmentWallBasis(
                    for: slot.wallID
                )
            else {
                continue
            }
            let record = makeRecord(slot: slot)
            record.container.setTransformMatrix(
                poseResolver.worldTransform(slot: slot, wall: wall),
                relativeTo: nil
            )
            root.addChild(record.container)
            records[propID] = record
            applyVisualState(.idle, to: record)
        }

        root.isEnabled = !records.isEmpty
    }

    func preview(
        slot: TuringStoryRuntimeSlot,
        duration: TimeInterval
    ) {
        guard let record = records[slot.propID],
            let wall = wallProvider?.turingStoryAdjustmentWallBasis(
                for: slot.wallID
            )
        else {
            return
        }
        record.slot = slot
        resizeIfNeeded(record: record, slot: slot)
        let transform = poseResolver.worldTransform(slot: slot, wall: wall)
        if duration <= 0 {
            record.container.setTransformMatrix(transform, relativeTo: nil)
        } else {
            record.container.move(
                to: Transform(matrix: transform),
                relativeTo: nil,
                duration: duration,
                timingFunction: .easeInOut
            )
        }
    }

    func commit(
        slot: TuringStoryRuntimeSlot
    ) {
        guard let record = records[slot.propID],
            let wall = wallProvider?.turingStoryAdjustmentWallBasis(
                for: slot.wallID
            )
        else {
            return
        }
        record.slot = slot
        resizeIfNeeded(record: record, slot: slot)
        record.container.setTransformMatrix(
            poseResolver.worldTransform(slot: slot, wall: wall),
            relativeTo: nil
        )
    }

    func worldRightAxis(
        for propID: TuringStoryPropID
    ) -> SIMD3<Float> {
        guard let record = records[propID] else {
            return SIMD3<Float>(1, 0, 0)
        }
        let matrix = record.container.transformMatrix(relativeTo: nil)
        let right = SIMD3<Float>(
            matrix.columns.0.x,
            matrix.columns.0.y,
            matrix.columns.0.z
        )
        let length = simd_length(right)
        return length > 0.000_01 ? right / length : SIMD3<Float>(1, 0, 0)
    }

    func setVisualState(
        _ state: TuringStoryPlacementAdjustmentBarVisualState,
        propID: TuringStoryPropID
    ) {
        guard let record = records[propID] else {
            return
        }
        snapFlashTasks[propID]?.cancel()
        snapFlashTasks[propID] = nil
        applyVisualState(state, to: record)

        guard state == .snapping else {
            return
        }
        snapFlashTasks[propID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled,
                let self,
                let current = self.records[propID],
                current.state == .snapping
            else {
                return
            }
            self.applyVisualState(.pinched, to: current)
            self.snapFlashTasks[propID] = nil
        }
    }

    func setEnabled(
        _ enabled: Bool,
        propID: TuringStoryPropID
    ) {
        guard let record = records[propID] else {
            return
        }
        record.interactionEnabled = enabled
        if enabled {
            record.container.components.set(InputTargetComponent())
            record.container.components.set(HoverEffectComponent())
            applyVisualState(.idle, to: record)
        } else {
            record.container.components.remove(InputTargetComponent.self)
            record.container.components.remove(HoverEffectComponent.self)
            setVisualMaterial(
                opacity: 0.08,
                scale: 1.0,
                indicatorOpacity: 0.12,
                record: record
            )
        }
    }

    func hideAll(
        reason: String
    ) {
        for task in snapFlashTasks.values {
            task.cancel()
        }
        snapFlashTasks.removeAll()
        clearRecords()
        root.isEnabled = false
        print("[TuringPlacementAdjust] bars hidden reason=\(reason)")
    }

    private func makeRecord(
        slot: TuringStoryRuntimeSlot
    ) -> BarRecord {
        let width = poseResolver.visualWidth(for: slot)
        let visibleSize = SIMD3<Float>(
            width,
            TuringStoryAdjustmentBarPoseResolver.visibleHeight,
            TuringStoryAdjustmentBarPoseResolver.visibleDepth
        )
        let collisionSize = SIMD3<Float>(
            width,
            TuringStoryAdjustmentBarPoseResolver.collisionHeight,
            TuringStoryAdjustmentBarPoseResolver.collisionDepth
        )

        let container = Entity()
        container.name = "TuringStoryPlacementAdjustmentBar_\(slot.propID.rawValue)"
        container.components.set(
            TuringStoryPlacementAdjustmentBarComponent(propID: slot.propID)
        )
        container.components.set(InputTargetComponent())
        container.components.set(HoverEffectComponent())
        container.components.set(
            CollisionComponent(
                shapes: [.generateBox(size: collisionSize)]
            )
        )

        let visual = ModelEntity(
            mesh: .generateBox(
                size: visibleSize,
                cornerRadius: 0.008
            ),
            materials: [
                TuringStoryAdjustmentBarMaterialFactory.make(opacity: 0.18)
            ]
        )
        visual.name = "TuringStoryPlacementAdjustmentBar_Visual"
        visual.components.remove(InputTargetComponent.self)
        visual.components.remove(CollisionComponent.self)
        container.addChild(visual)

        let indicator = ModelEntity(
            mesh: .generateBox(
                size: SIMD3<Float>(0.018, 0.008, 0.008),
                cornerRadius: 0.003
            ),
            materials: [
                TuringStoryAdjustmentBarMaterialFactory.makeIndicator(
                    opacity: 0.30
                )
            ]
        )
        indicator.name = "TuringStoryPlacementAdjustmentBar_GrabIndicator"
        indicator.position.z = visibleSize.z * 0.5 + 0.0045
        indicator.components.remove(InputTargetComponent.self)
        indicator.components.remove(CollisionComponent.self)
        container.addChild(indicator)

        return BarRecord(
            container: container,
            visual: visual,
            indicator: indicator,
            slot: slot,
            visibleSize: visibleSize,
            collisionSize: collisionSize
        )
    }

    private func resizeIfNeeded(
        record: BarRecord,
        slot: TuringStoryRuntimeSlot
    ) {
        let width = poseResolver.visualWidth(for: slot)
        guard abs(width - record.visibleSize.x) > 0.000_5 else {
            return
        }

        let visibleSize = SIMD3<Float>(
            width,
            TuringStoryAdjustmentBarPoseResolver.visibleHeight,
            TuringStoryAdjustmentBarPoseResolver.visibleDepth
        )
        let collisionSize = SIMD3<Float>(
            width,
            TuringStoryAdjustmentBarPoseResolver.collisionHeight,
            TuringStoryAdjustmentBarPoseResolver.collisionDepth
        )

        if var model = record.visual.components[ModelComponent.self] {
            model.mesh = .generateBox(
                size: visibleSize,
                cornerRadius: 0.008
            )
            record.visual.components.set(model)
        }
        record.container.components.set(
            CollisionComponent(
                shapes: [.generateBox(size: collisionSize)]
            )
        )
        record.indicator.position.z = visibleSize.z * 0.5 + 0.0045
        record.visibleSize = visibleSize
        record.collisionSize = collisionSize
    }

    private func applyVisualState(
        _ state: TuringStoryPlacementAdjustmentBarVisualState,
        to record: BarRecord
    ) {
        record.state = state
        guard record.interactionEnabled else {
            setVisualMaterial(
                opacity: 0.08,
                scale: 1.0,
                indicatorOpacity: 0.12,
                record: record
            )
            return
        }

        switch state {
        case .idle:
            setVisualMaterial(
                opacity: 0.18,
                scale: 1.0,
                indicatorOpacity: 0.30,
                record: record
            )
        case .hover:
            setVisualMaterial(
                opacity: 0.40,
                scale: 1.03,
                indicatorOpacity: 0.55,
                record: record
            )
        case .pinched:
            setVisualMaterial(
                opacity: 0.65,
                scale: 1.05,
                indicatorOpacity: 0.75,
                record: record
            )
        case .snapping:
            setVisualMaterial(
                opacity: 0.65,
                scale: 1.05,
                indicatorOpacity: 1.0,
                record: record
            )
        }
    }

    private func setVisualMaterial(
        opacity: Float,
        scale: Float,
        indicatorOpacity: Float,
        record: BarRecord
    ) {
        if var model = record.visual.components[ModelComponent.self] {
            model.materials = [
                TuringStoryAdjustmentBarMaterialFactory.make(opacity: opacity)
            ]
            record.visual.components.set(model)
        }
        if var model = record.indicator.components[ModelComponent.self] {
            model.materials = [
                TuringStoryAdjustmentBarMaterialFactory.makeIndicator(
                    opacity: indicatorOpacity
                )
            ]
            record.indicator.components.set(model)
        }
        record.visual.scale = SIMD3<Float>(repeating: scale)
        record.indicator.scale = SIMD3<Float>(repeating: scale)
    }

    private func clearRecords() {
        root.children.removeAll()
        records.removeAll()
    }

    // MARK: - Internal test inspection

    var installedBarCount: Int {
        records.count
    }

    func barEntity(
        for propID: TuringStoryPropID
    ) -> Entity? {
        records[propID]?.container
    }

    func visualEntity(
        for propID: TuringStoryPropID
    ) -> ModelEntity? {
        records[propID]?.visual
    }

    func visibleSize(
        for propID: TuringStoryPropID
    ) -> SIMD3<Float>? {
        records[propID]?.visibleSize
    }

    func collisionSize(
        for propID: TuringStoryPropID
    ) -> SIMD3<Float>? {
        records[propID]?.collisionSize
    }
}

