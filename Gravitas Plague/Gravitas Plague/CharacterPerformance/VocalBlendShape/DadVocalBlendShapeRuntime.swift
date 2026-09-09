import Foundation
import RealityKit

private nonisolated struct CharacterVocalActivePosePlayback: Sendable {
    let start: CharacterVocalPlaybackStart
    var track: TuringGeneratedSpeechFrameTrack?
}

@MainActor
final class DadVocalBlendShapeController {
    let sourceID: UUID
    let characterID = "dad"

    private let descriptor: CharacterVocalBlendShapeDescriptor
    private let response: CharacterVocalBlendShapeResponse
    private var bindings: [CharacterVocalBlendShapeBinding]
    private var presenceLoop: CharacterVocalActivePosePlayback?
    private var oneShot: CharacterVocalActivePosePlayback?
    private var deathIsTerminal = false
    private var lastAssignedWeight: Float

    private(set) var currentPose: MindEyeMouthPose = .rest
    private(set) var currentWeight: Float
    private(set) var targetWeight: Float

    init(
        sourceID: UUID,
        descriptor: CharacterVocalBlendShapeDescriptor,
        bindings: [CharacterVocalBlendShapeBinding]
    ) throws {
        self.sourceID = sourceID
        self.descriptor = descriptor
        response = .init(descriptor.response)
        self.bindings = bindings
        currentWeight = descriptor.fallbackWeight
        targetWeight = descriptor.fallbackWeight
        lastAssignedWeight = descriptor.fallbackWeight
        do {
            try assign(descriptor.fallbackWeight, force: true)
        } catch {
            for binding in self.bindings { binding.invalidate() }
            self.bindings.removeAll()
            throw error
        }
    }

    func receive(_ event: CharacterVocalPlaybackEvent) {
        guard event.sourceID == sourceID else { return }
        switch event {
        case .started(let start):
            guard start.identity.characterID == characterID,
                  start.identity.archetype == .dad else { return }
            if start.identity.role == .presenceLoop, start.identity.isLooping {
                presenceLoop = .init(start: start, track: nil)
            } else if start.identity.role != .presenceLoop, !start.identity.isLooping {
                if start.identity.role == .damageHit, deathIsTerminal { return }
                oneShot = .init(start: start, track: nil)
                if start.identity.role == .death { deathIsTerminal = true }
            }

        case .completed(let identity):
            if oneShot?.start.identity == identity { oneShot = nil }

        case .cancelled(let identity, _):
            if presenceLoop?.start.identity == identity { presenceLoop = nil }
            if oneShot?.start.identity == identity { oneShot = nil }

        case .sourceRemoved:
            reset(immediately: true, reason: "sourceRemoved")
        }
    }

    func trackDidBecomeReady(
        for identity: CharacterVocalPlaybackIdentity,
        track: TuringGeneratedSpeechFrameTrack
    ) {
        var didJoin = false
        if presenceLoop?.start.identity == identity {
            presenceLoop?.track = track
            didJoin = true
        }
        if oneShot?.start.identity == identity {
            oneShot?.track = track
            didJoin = true
        }
        if didJoin {
            print(
                "[DadVocalBlendShape] track joined " +
                "sourceID=\(sourceID.uuidString) role=\(identity.role.rawValue) " +
                "file=\(identity.fileName) frames=\(track.frameCount)"
            )
        }
    }

    func update(deltaTime: TimeInterval, now: ContinuousClock.Instant) {
        // A failed visual binding must fail soft once. Do not retry and log on
        // every immersive frame after the last binding has been retired.
        guard !bindings.isEmpty else { return }
        let previousPose = currentPose
        let pose = activePose(now: now)
        currentPose = pose
        targetWeight = descriptor.poseWeights.weight(for: pose)
        if pose != previousPose {
            print(
                "[DadVocalBlendShape] pose transition " +
                "sourceID=\(sourceID.uuidString) pose=\(pose.rawValue) " +
                "targetWeight=\(targetWeight) currentWeight=\(currentWeight)"
            )
        }
        currentWeight = response.step(
            current: currentWeight,
            target: targetWeight,
            deltaTime: Float(deltaTime)
        )
        do {
            try assign(currentWeight, force: false)
        } catch {
            print(
                "[DadVocalBlendShape] assignment failed sourceID=\(sourceID.uuidString) " +
                "reason=\(error.localizedDescription) visualOnly=true"
            )
        }
    }

    func reset(immediately: Bool, reason: String) {
        presenceLoop = nil
        oneShot = nil
        deathIsTerminal = false
        currentPose = .rest
        targetWeight = descriptor.fallbackWeight
        if immediately {
            currentWeight = descriptor.fallbackWeight
            try? assign(descriptor.fallbackWeight, force: true)
        }
        print(
            "[DadVocalBlendShape] reset sourceID=\(sourceID.uuidString) " +
            "immediate=\(immediately) reason=\(reason) weight=\(targetWeight)"
        )
    }

    func shutdown(reason: String) {
        reset(immediately: true, reason: reason)
        for binding in bindings { binding.invalidate() }
        bindings.removeAll()
    }

    private func activePose(now: ContinuousClock.Instant) -> MindEyeMouthPose {
        if let oneShot {
            return sample(oneShot, now: now, loops: false) ?? .rest
        }
        if deathIsTerminal { return .rest }
        if let presenceLoop {
            return sample(presenceLoop, now: now, loops: true) ?? .rest
        }
        return .rest
    }

    private func sample(
        _ playback: CharacterVocalActivePosePlayback,
        now: ContinuousClock.Instant,
        loops: Bool
    ) -> MindEyeMouthPose? {
        guard let track = playback.track, track.frameCount > 0 else { return nil }
        let elapsed = max(0, Self.seconds(playback.start.clockOrigin.duration(to: now)))
        let rawFrame = Int((elapsed * Double(track.framesPerSecond)).rounded(.down))
        let frame: Int
        if loops {
            frame = rawFrame % track.frameCount
        } else {
            guard rawFrame < track.frameCount else { return nil }
            frame = rawFrame
        }
        return track.pose(atFrame: frame)?.mindEyePose
    }

    private func assign(_ value: Float, force: Bool) throws {
        guard force || abs(value - lastAssignedWeight) > response.assignmentEpsilon else {
            return
        }
        var firstError: Error?
        bindings = bindings.filter { binding in
            do {
                try binding.setWeight(value)
                return true
            } catch {
                if firstError == nil { firstError = error }
                binding.invalidate()
                return false
            }
        }
        if let firstError { throw firstError }
        guard !bindings.isEmpty else {
            throw CharacterVocalBlendShapeError.targetNotFound(descriptor.blendShapeName)
        }
        lastAssignedWeight = value
    }

    private nonisolated static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1.0e18
    }
}

@MainActor
final class DadVocalBlendShapeRuntimeRegistry {
    private struct TrackJoin {
        let sourceID: UUID
        let task: Task<Void, Never>
    }

    private let descriptorStore = CharacterVocalBlendShapeDescriptorStore()
    private let trackStore = CharacterVocalPoseTrackStore()
    private let eventHub: CharacterVocalPlaybackEventHub
    private var eventSubscription: CharacterVocalPlaybackEventHub.Subscription?
    private var controllers: [UUID: DadVocalBlendShapeController] = [:]
    private var registrationGeneration: [UUID: UUID] = [:]
    private var registrationTasks: [UUID: Task<Void, Never>] = [:]
    private var trackJoinTasks: [UUID: TrackJoin] = [:]
    private var pendingEvents: [UUID: [CharacterVocalPlaybackEvent]] = [:]
    private var prewarmTask: Task<Void, Never>?

    init(eventHub: CharacterVocalPlaybackEventHub) {
        self.eventHub = eventHub
        eventSubscription = eventHub.subscribe { [weak self] event in
            self?.receive(event)
        }
    }

    func register(
        sourceID: UUID,
        characterID: String,
        rootEntity: Entity,
        portalMirrorRoot: Entity?,
        reason: String
    ) {
        guard characterID == "dad" else { return }
        unregister(sourceID: sourceID, reason: "replacementRegistration")
        let generation = UUID()
        registrationGeneration[sourceID] = generation
        pendingEvents[sourceID] = []
        startPrewarmIfNeeded()

        let task = Task { @MainActor [weak self, weak rootEntity, weak portalMirrorRoot] in
            guard let self else { return }
            do {
                let resources = try await descriptorStore.loadDad()
                try Task.checkCancellation()
                guard registrationGeneration[sourceID] == generation,
                      let rootEntity else { return }

                let descriptor = resources.descriptor
                if let payload = resources.offsetPayload {
                    let sourceReport = try SingleBlendShapeMeshImportValidator.validate(
                        root: rootEntity,
                        targetName: descriptor.blendShapeName,
                        payload: payload
                    )
                    let meshDiagnostic = [
                        "[DadVocalBlendShape] mesh ready",
                        "sourceID=\(sourceID.uuidString)",
                        "nativeParts=\(sourceReport.nativePartCount)",
                        "skeletons=\(sourceReport.skeletonCount)",
                        "importedPositions=\(sourceReport.maximumImportedPositionCount)",
                        "matchedSourceRecords=\(sourceReport.matchedSourceRecordCount)",
                        "matchedRenderVertices=\(sourceReport.matchedRenderVertexCount)",
                        "splitRenderVertices=\(sourceReport.splitRenderVertexCount)",
                        "maximumNativeOffset=\(sourceReport.maximumNativeOffset)",
                        "meshMutation=false",
                        "deformer=gpuOnDemandBeforeSkinning"
                    ].joined(separator: " ")
                    print(meshDiagnostic)
                    if let portalMirrorRoot {
                        _ = try SingleBlendShapeMeshImportValidator.validate(
                            root: portalMirrorRoot,
                            targetName: descriptor.blendShapeName,
                            payload: payload
                        )
                    }
                }

                let resolver = CharacterVocalBlendShapeResolver()
                var bindings: [CharacterVocalBlendShapeBinding] = []
                do {
                    bindings = try await resolver.resolve(
                        in: rootEntity,
                        targetName: descriptor.blendShapeName
                    )
                    if let portalMirrorRoot {
                        bindings += try await resolver.resolve(
                            in: portalMirrorRoot,
                            targetName: descriptor.blendShapeName
                        )
                    }
                } catch {
                    for binding in bindings { binding.invalidate() }
                    throw error
                }
                let controller = try DadVocalBlendShapeController(
                    sourceID: sourceID,
                    descriptor: descriptor,
                    bindings: bindings
                )
                guard registrationGeneration[sourceID] == generation else {
                    controller.shutdown(reason: "staleRegistration")
                    return
                }
                controllers[sourceID] = controller
                registrationTasks.removeValue(forKey: sourceID)

                let buffered = pendingEvents.removeValue(forKey: sourceID) ?? []
                for event in buffered {
                    controller.receive(event)
                    if case .started(let start) = event { requestTrack(for: start) }
                }
                print(
                    "[DadVocalBlendShape] registered sourceID=\(sourceID.uuidString) " +
                    "bindings=\(bindings.count) portalBound=\(portalMirrorRoot != nil) " +
                    "reason=\(reason) bufferedEvents=\(buffered.count)"
                )
            } catch is CancellationError {
                return
            } catch {
                guard registrationGeneration[sourceID] == generation else { return }
                registrationGeneration.removeValue(forKey: sourceID)
                registrationTasks.removeValue(forKey: sourceID)
                pendingEvents.removeValue(forKey: sourceID)
                cancelTrackJoins(sourceID: sourceID)
                print(
                    "[DadVocalBlendShape] disabled sourceID=\(sourceID.uuidString) " +
                    "reason=\(error.localizedDescription) audioAndGameplayUnaffected=true"
                )
            }
        }
        registrationTasks[sourceID] = task
    }

    func unregister(sourceID: UUID, reason: String) {
        registrationGeneration.removeValue(forKey: sourceID)
        registrationTasks.removeValue(forKey: sourceID)?.cancel()
        pendingEvents.removeValue(forKey: sourceID)
        cancelTrackJoins(sourceID: sourceID)
        if let controller = controllers.removeValue(forKey: sourceID) {
            controller.shutdown(reason: reason)
        }
    }

    func update(deltaTime: TimeInterval, now: ContinuousClock.Instant = .now) {
        for controller in controllers.values {
            controller.update(deltaTime: deltaTime, now: now)
        }
    }

    func removeAll(reason: String) {
        for sourceID in Array(registrationGeneration.keys) {
            unregister(sourceID: sourceID, reason: reason)
        }
    }

    private func receive(_ event: CharacterVocalPlaybackEvent) {
        let sourceID = event.sourceID
        if case .sourceRemoved(_, let reason) = event {
            unregister(sourceID: sourceID, reason: reason)
            return
        }
        switch event {
        case .completed(let identity), .cancelled(let identity, _):
            trackJoinTasks.removeValue(forKey: identity.playbackID)?.task.cancel()
        case .started, .sourceRemoved:
            break
        }
        if let controller = controllers[sourceID] {
            controller.receive(event)
        } else if registrationGeneration[sourceID] != nil {
            var buffered = pendingEvents[sourceID] ?? []
            if buffered.count == 16 { buffered.removeFirst() }
            buffered.append(event)
            pendingEvents[sourceID] = buffered
        } else {
            return
        }
        if case .started(let start) = event {
            requestTrack(for: start)
        }
    }

    private func requestTrack(for start: CharacterVocalPlaybackStart) {
        guard let asset = DadVocalAudioInventory.asset(for: start) else {
            print(
                "[DadVocalTrack] exact file unavailable file=\(start.identity.fileName) " +
                "role=\(start.identity.role.rawValue) audioUnaffected=true"
            )
            return
        }
        let playbackID = start.identity.playbackID
        trackJoinTasks[playbackID]?.task.cancel()
        let task = Task { @MainActor [weak self] in
            guard let self,
                  let prepared = await trackStore.prepare(asset),
                  !Task.isCancelled else { return }
            controllers[start.identity.sourceID]?.trackDidBecomeReady(
                for: start.identity,
                track: prepared.track
            )
            trackJoinTasks.removeValue(forKey: playbackID)
        }
        trackJoinTasks[playbackID] = TrackJoin(
            sourceID: start.identity.sourceID,
            task: task
        )
    }

    private func startPrewarmIfNeeded() {
        guard prewarmTask == nil else { return }
        let assets = DadVocalAudioInventory.assets()
        let expectedCount = DadVocalAudioInventory.ordered.count
        if assets.count != expectedCount {
            print(
                "[DadVocalTrack] prewarm inventory incomplete found=\(assets.count) " +
                "expected=\(expectedCount) audioUnaffected=true"
            )
        }
        prewarmTask = Task { [trackStore] in
            for asset in assets {
                guard !Task.isCancelled else { return }
                _ = await trackStore.prepare(asset)
            }
            print("[DadVocalTrack] prewarm finished preparedOrderCount=\(assets.count)")
        }
    }

    private func cancelTrackJoins(sourceID: UUID) {
        let playbackIDs = trackJoinTasks.compactMap { playbackID, join in
            join.sourceID == sourceID ? playbackID : nil
        }
        for playbackID in playbackIDs {
            trackJoinTasks.removeValue(forKey: playbackID)?.task.cancel()
        }
    }
}
