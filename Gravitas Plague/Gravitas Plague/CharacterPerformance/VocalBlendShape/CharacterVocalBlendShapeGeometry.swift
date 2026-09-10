import Foundation
import Metal
import RealityKit
import simd

nonisolated struct CharacterVocalBlendShapeResponse: Sendable, Equatable {
    let increasingWeightHalfLifeSeconds: Float
    let decreasingWeightHalfLifeSeconds: Float
    let crossingHalfLifeSeconds: Float
    let maximumDeltaTimeSeconds: Float
    let assignmentEpsilon: Float

    init(_ descriptor: CharacterVocalBlendShapeResponseDescriptor) {
        increasingWeightHalfLifeSeconds = descriptor.increasingWeightHalfLifeSeconds
        decreasingWeightHalfLifeSeconds = descriptor.decreasingWeightHalfLifeSeconds
        crossingHalfLifeSeconds = descriptor.crossingHalfLifeSeconds
        maximumDeltaTimeSeconds = descriptor.maximumDeltaTimeSeconds
        assignmentEpsilon = descriptor.assignmentEpsilon
    }

    func step(current: Float, target: Float, deltaTime: Float) -> Float {
        let boundedDelta = min(maximumDeltaTimeSeconds, max(0, deltaTime))
        guard boundedDelta > 0 else { return current }

        let halfLife: Float
        if target > current {
            halfLife = increasingWeightHalfLifeSeconds
        } else if target < current {
            halfLife = decreasingWeightHalfLifeSeconds
        } else {
            return target
        }
        let isIntermediate = target > 0 && target < 1
        let resolvedHalfLife = isIntermediate ? crossingHalfLifeSeconds : halfLife
        let alpha = 1 - exp2(-boundedDelta / resolvedHalfLife)
        let result = current + (target - current) * alpha
        if abs(result - target) <= assignmentEpsilon { return target }
        return min(1, max(0, result))
    }
}

/// Immutable GPU resources retained by one installed Dad deformation binding.
/// Keeping them outside the Codable deformer value avoids copying a multi-MB
/// delta buffer every time the scalar mouth weight changes.
private nonisolated final class CharacterVocalGPUDeformerState: @unchecked Sendable {
    let pipeline: any MTLComputePipelineState
    let offsets: any MTLBuffer
    let vertexCount: Int

    init(
        pipeline: any MTLComputePipelineState,
        offsets: any MTLBuffer,
        vertexCount: Int
    ) {
        self.pipeline = pipeline
        self.offsets = offsets
        self.vertexCount = vertexCount
    }
}

/// Thread-safe process registry used by RealityKit's render-thread callback.
/// Registration and pipeline creation happen off the main thread. The callback
/// performs only a locked dictionary lookup and Metal encoding.
private nonisolated final class CharacterVocalGPUDeformerRegistry: @unchecked Sendable {
    static let shared = CharacterVocalGPUDeformerRegistry()

    private struct PipelineResources {
        let device: any MTLDevice
        let pipeline: any MTLComputePipelineState
    }

    /// RealityKit may already have queued a render callback when its component is
    /// removed on the main actor. Keep the registry entry alive beyond that
    /// handoff so the queued callback can still encode valid work.
    private static let retirementGraceSeconds: TimeInterval = 2

    private let lock = NSLock()
    private let retirementQueue = DispatchQueue(
        label: "com.gravitas-plague.character-vocal-gpu-retirement",
        qos: .utility
    )
    private var pipelineResources: PipelineResources?
    private var states: [UUID: CharacterVocalGPUDeformerState] = [:]
    /// One immutable, validated Dad buffer stays resident as a zero-weight copy
    /// source. The existing apply kernel is therefore also the fail-safe
    /// input-to-output passthrough kernel without another shader or allocation.
    private var passthroughStatesByVertexCount: [
        Int: CharacterVocalGPUDeformerState
    ] = [:]

    private init() {}

    func register(offsets: [SIMD3<Float>]) throws -> UUID {
        precondition(!Thread.isMainThread)
        guard !offsets.isEmpty else {
            throw CharacterVocalBlendShapeError.meshRepairFailed(
                "Dad GPU deformer received no offsets"
            )
        }

        let resources = try resolvePipelineResources()

        // Do the O(vertexCount) conversion and Metal allocation without holding
        // the callback registry lock. Existing Dad render callbacks consequently
        // never wait behind a new Dad's multi-megabyte upload.
        let alignedOffsets = offsets.map { SIMD4<Float>($0, 0) }
        let buffer: (any MTLBuffer)? = alignedOffsets.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return resources.device.makeBuffer(
                bytes: baseAddress,
                length: bytes.count,
                options: .storageModeShared
            )
        }
        guard let buffer else {
            throw CharacterVocalBlendShapeError.meshRepairFailed(
                "Dad GPU deformer offset upload failed"
            )
        }
        buffer.label = "DadVocalCloseDenseOffsets"

        let id = UUID()
        let state = CharacterVocalGPUDeformerState(
            pipeline: resources.pipeline,
            offsets: buffer,
            vertexCount: offsets.count
        )
        lock.lock()
        states[id] = state
        if passthroughStatesByVertexCount[state.vertexCount] == nil {
            passthroughStatesByVertexCount[state.vertexCount] = state
        }
        lock.unlock()
        return id
    }

    func state(for id: UUID) -> CharacterVocalGPUDeformerState? {
        lock.lock()
        defer { lock.unlock() }
        return states[id]
    }

    /// Returns either the requested active state or a validated zero-weight
    /// passthrough state with the same vertex domain. The latter guarantees that
    /// an expired/stale callback still writes every output position.
    func callbackState(
        for id: UUID,
        vertexCount: Int
    ) -> (state: CharacterVocalGPUDeformerState, appliesRequestedWeight: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        if let state = states[id], state.vertexCount == vertexCount {
            return (state, true)
        }
        guard let passthroughState = passthroughStatesByVertexCount[
            vertexCount
        ] else {
            return nil
        }
        return (passthroughState, false)
    }

    func retire(_ id: UUID) {
        retirementQueue.asyncAfter(
            deadline: .now() + Self.retirementGraceSeconds
        ) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.states.removeValue(forKey: id)
            self.lock.unlock()
        }
    }

    private func resolvePipelineResources() throws -> PipelineResources {
        lock.lock()
        if let pipelineResources {
            lock.unlock()
            return pipelineResources
        }
        lock.unlock()

        guard let createdDevice = MTLCreateSystemDefaultDevice(),
              let library = createdDevice.makeDefaultLibrary(),
              let function = library.makeFunction(
                name: "characterVocalApplyDenseOffsets"
              ) else {
            throw CharacterVocalBlendShapeError.meshRepairFailed(
                "Dad GPU deformer Metal function is unavailable"
            )
        }
        let createdPipeline: any MTLComputePipelineState
        do {
            createdPipeline = try createdDevice.makeComputePipelineState(
                function: function
            )
        } catch {
            throw CharacterVocalBlendShapeError.meshRepairFailed(
                "Dad GPU deformer pipeline failed: \(error.localizedDescription)"
            )
        }
        let created = PipelineResources(
            device: createdDevice,
            pipeline: createdPipeline
        )

        // Preparation is serial today, but keep double-checked publication so a
        // future parallel caller cannot replace resources used by callbacks.
        lock.lock()
        if let pipelineResources {
            lock.unlock()
            return pipelineResources
        }
        pipelineResources = created
        lock.unlock()
        return created
    }
}

private nonisolated enum CharacterVocalGPUDeformerPreparation {
    private static let queue = DispatchQueue(
        label: "com.gravitas-plague.character-vocal-gpu-deformer",
        qos: .userInitiated
    )

    static func prepare(offsets: [SIMD3<Float>]) async throws -> UUID {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                dispatchPrecondition(condition: .notOnQueue(.main))
                continuation.resume(with: Result {
                    try CharacterVocalGPUDeformerRegistry.shared.register(
                        offsets: offsets
                    )
                })
            }
        }
    }
}

/// Applies the authored mouth-close target in RealityKit's imported render-vertex
/// domain. This executes on Metal before skinning. Replacing the imported
/// MeshResource destroys private skeleton/basis state and is never permitted.
nonisolated struct CharacterVocalDenseOffsetDeformer: MeshDeformer {
    static let type = "com.gravitas-plague.character-vocal-dense-offset.v2"
    static let mode: MeshDeformerExecutionMode = .gpu

    let stateID: UUID
    let weight: Float
    let vertexCount: Int

    var options: MeshDeformerOptions {
        .init(
            cadence: .onDemand,
            inputSpec: .positions,
            outputSpec: .positions
        )
    }

    func deform(
        parameter: MeshDeformParameterGPU,
        encoder: any MTLComputeCommandEncoder
    ) {
        guard let input = parameter.inputBuffers.positions,
              let output = parameter.outputBuffers.positions,
              input.format == .float3,
              output.format == .float3,
              input.stride == 12,
              output.stride == 12,
              input.offset >= 0,
              output.offset >= 0,
              parameter.inputBuffers.count == vertexCount,
              parameter.outputBuffers.count == vertexCount,
              vertexCount > 0,
              vertexCount <= Int(UInt32.max),
              Self.rangeIsValid(
                offset: input.offset,
                stride: input.stride,
                count: parameter.inputBuffers.count,
                bufferLength: input.buffer.length
              ),
              Self.rangeIsValid(
                offset: output.offset,
                stride: output.stride,
                count: parameter.outputBuffers.count,
                bufferLength: output.buffer.length
              ),
              let callbackState = CharacterVocalGPUDeformerRegistry.shared
                .callbackState(for: stateID, vertexCount: vertexCount) else {
            // Missing position buffers or an invalid Metal range cannot be
            // dereferenced safely. All callback failures with a valid Dad buffer
            // contract take the explicit zero-weight passthrough below.
            return
        }

        let state = callbackState.state
        var boundedWeight: Float = callbackState.appliesRequestedWeight && weight.isFinite
            ? min(1, max(0, weight))
            : 0
        var count = UInt32(vertexCount)
        encoder.setComputePipelineState(state.pipeline)
        encoder.setBuffer(input.buffer, offset: input.offset, index: 0)
        encoder.setBuffer(output.buffer, offset: output.offset, index: 1)
        encoder.setBuffer(state.offsets, offset: 0, index: 2)
        encoder.setBytes(
            &boundedWeight,
            length: MemoryLayout<Float>.stride,
            index: 3
        )
        encoder.setBytes(
            &count,
            length: MemoryLayout<UInt32>.stride,
            index: 4
        )
        let width = max(1, state.pipeline.threadExecutionWidth)
        encoder.dispatchThreads(
            MTLSize(width: vertexCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
    }

    private static func rangeIsValid(
        offset: Int,
        stride: Int,
        count: Int,
        bufferLength: Int
    ) -> Bool {
        guard offset >= 0, stride > 0, count > 0 else { return false }
        let (byteCount, multipliedOverflow) = stride.multipliedReportingOverflow(
            by: count
        )
        guard !multipliedOverflow else { return false }
        let (end, additionOverflow) = offset.addingReportingOverflow(byteCount)
        return !additionOverflow && end <= bufferLength
    }

    func deform(parameter: MeshDeformParameterCPU) {}

    func isDeformerEqual(other: any MeshDeformer) -> Bool {
        guard let other = other as? Self else { return false }
        return self == other
    }
}

@MainActor
final class CharacterVocalBlendShapeBinding {
    weak var entity: ModelEntity?
    let entityPath: String
    let groupIndex: Int
    let weightIndex: Int
    let weightName: String
    private let deformerStateID: UUID
    private let vertexCount: Int
    private let originalDeformerComponent: MeshDeformerComponent?
    private var appliedWeight: Float
    private var installedDeformations: [MeshDeformationStack]?
    private var isInvalidated = false

    init(
        entity: ModelEntity,
        entityPath: String,
        groupIndex: Int,
        weightIndex: Int,
        weightName: String,
        deformerStateID: UUID,
        vertexCount: Int
    ) throws {
        guard entity.model?.mesh != nil,
              vertexCount > 0,
              Self.hasTargetContract(
                entity: entity,
                groupIndex: groupIndex,
                weightIndex: weightIndex,
                weightName: weightName
              ) else {
            throw CharacterVocalBlendShapeError.staleBinding
        }
        self.entity = entity
        self.entityPath = entityPath
        self.groupIndex = groupIndex
        self.weightIndex = weightIndex
        self.weightName = weightName
        self.deformerStateID = deformerStateID
        self.vertexCount = vertexCount
        self.originalDeformerComponent = entity.components[MeshDeformerComponent.self]
        self.appliedWeight = 0
        self.installedDeformations = nil
    }

    func setWeight(_ requested: Float) throws {
        guard !isInvalidated,
              let entity,
              entity.model?.mesh != nil,
              Self.hasTargetContract(
                entity: entity,
                groupIndex: groupIndex,
                weightIndex: weightIndex,
                weightName: weightName
              ),
              CharacterVocalGPUDeformerRegistry.shared.state(
                for: deformerStateID
              ) != nil else {
            throw CharacterVocalBlendShapeError.entityReleased(entityPath)
        }
        // RealityKit may normalize its imported deformation stack between the
        // async resolve and this first MainActor installation. That imported
        // stack is the state we intentionally replace with the explicit
        // custom/blend/skin stack below, so it must not be treated as stale.
        // Once installed, however, only replace the exact stack this binding
        // last wrote; an outside owner changing it retires this visual binding.
        let isFirstInstallation = installedDeformations == nil
        if let installedDeformations {
            let currentDeformations = entity.components[
                MeshDeformerComponent.self
            ]?.deformations
            guard currentDeformations == installedDeformations else {
                throw CharacterVocalBlendShapeError.staleBinding
            }
        }
        let value = min(1, max(0, requested))
        let stack = MeshDeformationStack(
            deformers: [
                CharacterVocalDenseOffsetDeformer(
                    stateID: deformerStateID,
                    weight: value,
                    vertexCount: vertexCount
                ),
                BlendShapeDeformer(),
                SkinningDeformer(skinsTangentFrame: true)
            ],
            targets: [.all]
        )
        let component = try MeshDeformerComponent(from: [stack])
        entity.components.set(component)
        installedDeformations = component.deformations
        appliedWeight = value
        if isFirstInstallation {
            print(
                "[DadVocalBlendShape] binding installed " +
                "entityPath=\(entityPath) initialWeight=\(value) " +
                "vertexCount=\(vertexCount) deformer=gpuOnDemandBeforeSkinning"
            )
        }
    }

    func currentWeight() throws -> Float {
        guard !isInvalidated,
              let entity,
              entity.model?.mesh != nil,
              Self.hasTargetContract(
                entity: entity,
                groupIndex: groupIndex,
                weightIndex: weightIndex,
                weightName: weightName
              ) else {
            throw CharacterVocalBlendShapeError.entityReleased(entityPath)
        }
        return appliedWeight
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        if let entity,
           let installedDeformations,
           entity.components[MeshDeformerComponent.self]?.deformations == installedDeformations {
            if let originalDeformerComponent {
                entity.components.set(originalDeformerComponent)
            } else {
                entity.components.remove(MeshDeformerComponent.self)
            }
        }
        CharacterVocalGPUDeformerRegistry.shared.retire(deformerStateID)
    }

    private static func hasTargetContract(
        entity: ModelEntity,
        groupIndex: Int,
        weightIndex: Int,
        weightName: String
    ) -> Bool {
        let names = entity.blendWeightNames
        guard names.indices.contains(groupIndex),
              names[groupIndex].indices.contains(weightIndex) else {
            return false
        }
        return names[groupIndex][weightIndex] == weightName
    }
}

@MainActor
struct CharacterVocalBlendShapeResolver {
    private struct Candidate {
        let entity: ModelEntity
        let entityPath: String
        let groupIndex: Int
        let weightIndex: Int
        let weightName: String
        let denseOffsets: [SIMD3<Float>]
    }

    func resolve(
        in root: Entity,
        targetName: String
    ) async throws -> [CharacterVocalBlendShapeBinding] {
        var candidates: [Candidate] = []
        try collect(
            entity: root,
            path: root.name,
            targetName: targetName,
            candidates: &candidates
        )
        guard !candidates.isEmpty else {
            throw CharacterVocalBlendShapeError.targetNotFound(targetName)
        }

        var bindings: [CharacterVocalBlendShapeBinding] = []
        do {
            for candidate in candidates {
                let offsets = candidate.denseOffsets
                let stateID = try await CharacterVocalGPUDeformerPreparation
                    .prepare(offsets: offsets)
                do {
                    let currentNames = candidate.entity.blendWeightNames
                    guard candidate.entity.model?.mesh != nil,
                          currentNames.indices.contains(candidate.groupIndex),
                          currentNames[candidate.groupIndex].indices.contains(
                            candidate.weightIndex
                          ),
                          currentNames[candidate.groupIndex][candidate.weightIndex] ==
                            candidate.weightName else {
                        throw CharacterVocalBlendShapeError.staleBinding
                    }
                    try zeroImportedWeight(
                        candidate.entity,
                        entityPath: candidate.entityPath,
                        groupIndex: candidate.groupIndex,
                        weightIndex: candidate.weightIndex
                    )
                    bindings.append(try .init(
                        entity: candidate.entity,
                        entityPath: candidate.entityPath,
                        groupIndex: candidate.groupIndex,
                        weightIndex: candidate.weightIndex,
                        weightName: candidate.weightName,
                        deformerStateID: stateID,
                        vertexCount: offsets.count
                    ))
                } catch {
                    CharacterVocalGPUDeformerRegistry.shared.retire(stateID)
                    throw error
                }
            }
        } catch {
            for binding in bindings { binding.invalidate() }
            throw error
        }
        return bindings
    }

    private func collect(
        entity: Entity,
        path: String,
        targetName: String,
        candidates: inout [Candidate]
    ) throws {
        if let model = entity as? ModelEntity {
            if model.components[BlendShapeWeightsComponent.self] == nil,
               !model.blendWeightNames.isEmpty,
               let mesh = model.model?.mesh {
                model.components.set(BlendShapeWeightsComponent(
                    weightsMapping: BlendShapeWeightsMapping(meshResource: mesh)
                ))
            }
            let names = model.blendWeightNames
            let weights = model.blendWeights
            guard names.count == weights.count else {
                throw CharacterVocalBlendShapeError.groupCountMismatch(entityPath: path)
            }
            for groupIndex in names.indices {
                guard names[groupIndex].count == weights[groupIndex].count else {
                    throw CharacterVocalBlendShapeError.weightCountMismatch(
                        entityPath: path,
                        groupIndex: groupIndex
                    )
                }
                let matches = names[groupIndex].indices.filter {
                    names[groupIndex][$0] == targetName
                }
                guard matches.count <= 1 else {
                    throw CharacterVocalBlendShapeError.duplicateTarget(
                        entityPath: path,
                        groupIndex: groupIndex
                    )
                }
                if let weightIndex = matches.first {
                    guard let mesh = model.model?.mesh else {
                        throw CharacterVocalBlendShapeError.staleBinding
                    }
                    let contents = mesh.contents
                    let allParts = contents.models.flatMap(\.parts)
                    guard allParts.count == 1,
                          let sourcePart = allParts.first,
                          sourcePart.blendShapeNames.contains(targetName) else {
                        throw CharacterVocalBlendShapeError.meshRepairFailed(
                            "Dad custom deformer requires its single imported mesh part"
                        )
                    }
                    let nativeSemantic = MeshBuffers.custom(
                        targetName + "|blendTargetPosDeltas",
                        type: SIMD3<Float>.self
                    )
                    guard let nativeOffsets: MeshBuffer<SIMD3<Float>> =
                            sourcePart[nativeSemantic],
                          nativeOffsets.elements.count == sourcePart.positions.elements.count else {
                        throw CharacterVocalBlendShapeError.meshRepairFailed(
                            "RealityKit native Dad target offsets are unavailable"
                        )
                    }

                    candidates.append(.init(
                        entity: model,
                        entityPath: path,
                        groupIndex: groupIndex,
                        weightIndex: weightIndex,
                        weightName: targetName,
                        denseOffsets: nativeOffsets.elements
                    ))
                }
            }
        }
        for child in entity.children {
            try collect(
                entity: child,
                path: path + "/" + child.name,
                targetName: targetName,
                candidates: &candidates
            )
        }
    }

    private func zeroImportedWeight(
        _ entity: ModelEntity,
        entityPath: String,
        groupIndex: Int,
        weightIndex: Int
    ) throws {
        if var component = entity.components[BlendShapeWeightsComponent.self] {
            var set = component.weightSet
            guard set.indices.contains(groupIndex) else {
                throw CharacterVocalBlendShapeError.groupCountMismatch(
                    entityPath: entityPath
                )
            }
            var data = set[groupIndex]
            var weights = data.weights
            guard weights.indices.contains(weightIndex) else {
                throw CharacterVocalBlendShapeError.weightCountMismatch(
                    entityPath: entityPath,
                    groupIndex: groupIndex
                )
            }
            weights[weightIndex] = 0
            data.weights = weights
            set[groupIndex] = data
            component.weightSet = set
            entity.components.set(component)
            return
        }

        var groups = entity.blendWeights
        guard groups.indices.contains(groupIndex),
              groups[groupIndex].indices.contains(weightIndex) else {
            throw CharacterVocalBlendShapeError.weightCountMismatch(
                entityPath: entityPath,
                groupIndex: groupIndex
            )
        }
        groups[groupIndex][weightIndex] = 0
        entity.blendWeights = groups
    }
}

nonisolated struct SingleBlendShapeOffsetPayload: Sendable, Equatable {
    struct Record: Sendable, Equatable {
        let pointIndex: Int
        let basePosition: SIMD3<Float>
        let offset: SIMD3<Float>
    }

    struct Mesh: Sendable, Equatable {
        let sourcePrimPath: String
        let sourcePointCount: Int
        let records: [Record]
    }

    let meshes: [Mesh]

    init(data: Data, expectedMeshCount: Int, expectedRecordCount: Int) throws {
        var reader = SingleBlendShapeOffsetPayloadReader(data: data)
        guard try reader.readBytes(count: 8) == Data("GRDADV1\0".utf8) else {
            throw CharacterVocalBlendShapeError.invalidOffsetPayload("magic")
        }
        guard try reader.readUInt32() == 1 else {
            throw CharacterVocalBlendShapeError.invalidOffsetPayload("schemaVersion")
        }
        let meshCount = Int(try reader.readUInt32())
        guard meshCount == expectedMeshCount, meshCount > 0 else {
            throw CharacterVocalBlendShapeError.invalidOffsetPayload("meshCount")
        }
        var result: [Mesh] = []
        var totalRecords = 0
        result.reserveCapacity(meshCount)
        for _ in 0..<meshCount {
            let pathLength = Int(try reader.readUInt32())
            let pointCount = Int(try reader.readUInt32())
            let recordCount = Int(try reader.readUInt32())
            guard try reader.readUInt32() == 0,
                  pathLength > 0, pointCount > 0, recordCount > 0 else {
                throw CharacterVocalBlendShapeError.invalidOffsetPayload("meshHeader")
            }
            let pathData = try reader.readBytes(count: pathLength)
            guard let path = String(data: pathData, encoding: .utf8), path.hasPrefix("/") else {
                throw CharacterVocalBlendShapeError.invalidOffsetPayload("sourcePrimPath")
            }
            var records: [Record] = []
            records.reserveCapacity(recordCount)
            var previous = -1
            for _ in 0..<recordCount {
                let index = Int(try reader.readUInt32())
                let base = try reader.readVector3()
                let offset = try reader.readVector3()
                guard index > previous, index < pointCount,
                      base.isFinite, offset.isFinite,
                      simd_length_squared(offset) > 0 else {
                    throw CharacterVocalBlendShapeError.invalidOffsetPayload("record")
                }
                previous = index
                records.append(.init(pointIndex: index, basePosition: base, offset: offset))
            }
            totalRecords += records.count
            result.append(.init(sourcePrimPath: path, sourcePointCount: pointCount, records: records))
        }
        guard reader.isAtEnd, totalRecords == expectedRecordCount else {
            throw CharacterVocalBlendShapeError.invalidOffsetPayload("length")
        }
        meshes = result
    }
}

private nonisolated struct SingleBlendShapeOffsetPayloadReader {
    let data: Data
    var cursor = 0
    var isAtEnd: Bool { cursor == data.count }

    mutating func readBytes(count: Int) throws -> Data {
        guard count >= 0, cursor <= data.count - count else {
            throw CharacterVocalBlendShapeError.invalidOffsetPayload("truncated")
        }
        defer { cursor += count }
        return data.subdata(in: cursor..<(cursor + count))
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readBytes(count: 4)
        return bytes.withUnsafeBytes {
            UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self))
        }
    }

    mutating func readVector3() throws -> SIMD3<Float> {
        try SIMD3(
            Float(bitPattern: readUInt32()),
            Float(bitPattern: readUInt32()),
            Float(bitPattern: readUInt32())
        )
    }
}

private nonisolated extension SIMD3 where Scalar == Float {
    var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

@MainActor
enum SingleBlendShapeMeshImportValidator {
    struct Report: Sendable, Equatable {
        let nativePartCount: Int
        let skeletonCount: Int
        let matchedSourceRecordCount: Int
        let matchedRenderVertexCount: Int
        let splitRenderVertexCount: Int
        let maximumImportedPositionCount: Int
        let maximumNativeOffset: Float
    }

    static func validate(
        root: Entity,
        targetName: String,
        payload: SingleBlendShapeOffsetPayload
    ) throws -> Report {
        var nativeParts = 0
        var skeletons = 0
        var matchedSourceRecords = 0
        var matchedRenderVertices = 0
        var splitRenderVertices = 0
        var maximumImportedPositions = 0
        var maximumNativeOffset: Float = 0
        var visited = Set<ObjectIdentifier>()

        try visit(root) { entity in
            guard let model = entity as? ModelEntity,
                  let mesh = model.model?.mesh,
                  visited.insert(ObjectIdentifier(mesh)).inserted else { return }
            let contents = mesh.contents
            skeletons += contents.skeletons.count
            for sourceModel in contents.models {
                for sourcePart in sourceModel.parts {
                    guard sourcePart.blendShapeNames.contains(targetName) else {
                        continue
                    }
                    guard sourcePart.skeletonID != nil,
                          !contents.skeletons.isEmpty else {
                        throw CharacterVocalBlendShapeError.meshRepairFailed(
                            "Dad target is not attached to an imported skeleton"
                        )
                    }

                    let positions = sourcePart.positions.elements
                    maximumImportedPositions = max(
                        maximumImportedPositions,
                        positions.count
                    )
                    let nativeSemantic = MeshBuffers.custom(
                        targetName + "|blendTargetPosDeltas",
                        type: SIMD3<Float>.self
                    )
                    let originalIndexSemantic = MeshBuffers.custom(
                        "originalPartVertexIndex",
                        type: UInt32.self
                    )
                    guard let nativeOffsets: MeshBuffer<SIMD3<Float>> =
                            sourcePart[nativeSemantic],
                          let originalIndices: MeshBuffer<UInt32> =
                            sourcePart[originalIndexSemantic] else {
                        throw CharacterVocalBlendShapeError.meshRepairFailed(
                            "RealityKit native Dad blendshape buffers are missing"
                        )
                    }

                    let importedOffsets = nativeOffsets.elements
                    let importedOriginalIndices = originalIndices.elements
                    guard let maximumOriginalIndex = importedOriginalIndices.max() else {
                        throw CharacterVocalBlendShapeError.meshRepairFailed(
                            "RealityKit original vertex map is empty"
                        )
                    }
                    let importedSourcePointCount = Int(maximumOriginalIndex) + 1
                    let matches = payload.meshes.filter { candidate in
                        candidate.sourcePointCount == importedSourcePointCount
                    }
                    guard matches.count == 1, let source = matches.first else {
                        throw CharacterVocalBlendShapeError.meshRepairFailed(
                            "could not establish exact imported vertex registration"
                        )
                    }

                    let validation = try validateNativeOffsets(
                        source: source,
                        importedPositions: positions,
                        originalPartVertexIndices: importedOriginalIndices,
                        nativeOffsets: importedOffsets,
                        registrationTolerance: 0.000_002
                    )
                    nativeParts += 1
                    matchedSourceRecords += validation.matchedSourceRecordCount
                    matchedRenderVertices += validation.matchedRenderVertexCount
                    splitRenderVertices += validation.splitRenderVertexCount
                    maximumNativeOffset = max(
                        maximumNativeOffset,
                        validation.maximumNativeOffset
                    )
                }
            }
        }
        guard nativeParts > 0 else {
            throw CharacterVocalBlendShapeError.meshRepairFailed(
                "no imported part exposes \(targetName)"
            )
        }
        return .init(
            nativePartCount: nativeParts,
            skeletonCount: skeletons,
            matchedSourceRecordCount: matchedSourceRecords,
            matchedRenderVertexCount: matchedRenderVertices,
            splitRenderVertexCount: splitRenderVertices,
            maximumImportedPositionCount: maximumImportedPositions,
            maximumNativeOffset: maximumNativeOffset
        )
    }

    /// RealityKit expands USD points at render seams and exposes the authoritative
    /// render-to-USD mapping plus its actual blend-target deltas as custom buffers.
    /// The public blendShapeOffsets accessor returns an all-zero compatibility
    /// buffer for this skinned asset. Never replace the imported MeshResource:
    /// doing so discards RealityKit's private skeleton/basis state.
    static func validateNativeOffsets(
        source: SingleBlendShapeOffsetPayload.Mesh,
        importedPositions: [SIMD3<Float>],
        originalPartVertexIndices: [UInt32],
        nativeOffsets: [SIMD3<Float>],
        registrationTolerance: Float
    ) throws -> (
        matchedSourceRecordCount: Int,
        matchedRenderVertexCount: Int,
        splitRenderVertexCount: Int,
        maximumNativeOffset: Float
    ) {
        guard importedPositions.count == originalPartVertexIndices.count,
              importedPositions.count == nativeOffsets.count,
              !importedPositions.isEmpty else {
            throw CharacterVocalBlendShapeError.meshRepairFailed(
                "RealityKit native Dad buffer lengths differ"
            )
        }

        let recordsByIndex = Dictionary(
            uniqueKeysWithValues: source.records.map { ($0.pointIndex, $0) }
        )
        var encounteredSourceRecords = Set<Int>()
        var matchedRenderVertices = 0
        var maximumNativeOffset: Float = 0

        for renderIndex in importedPositions.indices {
            let sourceIndex = Int(originalPartVertexIndices[renderIndex])
            guard sourceIndex < source.sourcePointCount else {
                throw CharacterVocalBlendShapeError.meshRepairFailed(
                    "RealityKit original vertex map exceeds the authored point count"
                )
            }
            let actualOffset = nativeOffsets[renderIndex]
            maximumNativeOffset = max(maximumNativeOffset, simd_length(actualOffset))
            if let record = recordsByIndex[sourceIndex] {
                guard simd_distance(
                    importedPositions[renderIndex],
                    record.basePosition
                ) <= registrationTolerance,
                simd_distance(actualOffset, record.offset) <= registrationTolerance else {
                    throw CharacterVocalBlendShapeError.meshRepairFailed(
                        "RealityKit native Dad blendshape differs from the authored payload"
                    )
                }
                encounteredSourceRecords.insert(sourceIndex)
                matchedRenderVertices += 1
            } else if simd_length(actualOffset) > registrationTolerance {
                throw CharacterVocalBlendShapeError.meshRepairFailed(
                    "RealityKit native Dad blendshape moves an unauthored point"
                )
            }
        }

        guard encounteredSourceRecords.count == source.records.count else {
            throw CharacterVocalBlendShapeError.meshRepairFailed(
                "RealityKit native Dad blendshape omits authored points"
            )
        }
        return (
            source.records.count,
            matchedRenderVertices,
            matchedRenderVertices - source.records.count,
            maximumNativeOffset
        )
    }

    private static func visit(_ entity: Entity, body: (Entity) throws -> Void) throws {
        try body(entity)
        for child in entity.children { try visit(child, body: body) }
    }
}
