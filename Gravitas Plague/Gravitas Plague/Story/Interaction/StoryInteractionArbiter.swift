import Foundation

actor StoryInteractionArbiter {
    static let shared = StoryInteractionArbiter()

    private var revision: UInt64 = 0
    private var turingGates:
        [StoryInteractionSurfaceID: StoryTuringGateState] = [
            .walkie: .closed,
            .dadFrame: .closed,
            .crankRadio: .closed,
            .hamReceiver: .closed
        ]
    private var doorState: StoryDoorLifecycleState = .closedUnloaded
    private var exclusiveLease: StoryInteractionLease?
    private var battleDoorPermissions: [UUID: StoryBattleDoorPermission] = [:]
    private var stableInteractionPolicy: StoryStableInteractionPolicy =
        .unrestricted
    private let snapshotHub = StoryInteractionSnapshotHub()

    func snapshots() async -> AsyncStream<StoryInteractionSnapshot> {
        await snapshotHub.stream(initial: makeSnapshot())
    }

    func currentSnapshot() -> StoryInteractionSnapshot {
        makeSnapshot()
    }

    func updateTuringGate(_ gate: StoryTuringGateState, reason: String) async {
        await updateTuringGate(
            gate,
            surfaceID: .walkie,
            reason: reason
        )
    }

    func updateTuringGate(
        _ gate: StoryTuringGateState,
        surfaceID: StoryInteractionSurfaceID,
        reason: String
    ) async {
        guard turingGates[surfaceID] != gate else { return }
        turingGates[surfaceID] = gate
        await publish(
            reason: "turingGate.\(surfaceID.rawValue).\(reason)"
        )
    }

    func updateTuringGates(
        _ gates: [StoryInteractionSurfaceID: StoryTuringGateState],
        reason: String
    ) async {
        var changed = false
        for (surfaceID, gate) in gates where turingGates[surfaceID] != gate {
            turingGates[surfaceID] = gate
            changed = true
        }
        guard changed else { return }
        await publish(reason: "turingGateBatch.\(reason)")
    }

    func updateDoorState(_ state: StoryDoorLifecycleState, reason: String) async {
        guard doorState != state else { return }
        if state != .closedUnloaded,
           exclusiveLease == nil {
            print("""
            [StoryInteraction] door state rejected
              requestedState: \(state.rawValue)
              currentState: \(doorState.rawValue)
              currentOwner: none
              reason: \(reason)
            """)
            return
        }
        doorState = state
        await publish(reason: "doorState.\(reason)")
    }

    func setBattleDoorPermission(
        _ permission: StoryBattleDoorPermission,
        battleLease: StoryInteractionLease,
        reason: String
    ) async throws {
        guard exclusiveLease == battleLease,
              case .battle(let battleInstanceID) = battleLease.owner else {
            throw StoryInteractionClaimError.staleLease
        }
        guard battleDoorPermissions[battleInstanceID] != permission else {
            return
        }
        battleDoorPermissions[battleInstanceID] = permission
        await publish(reason: "battleDoorPermission.\(reason)")
    }

    func claimManualTuring(
        runID: String,
        source: String
    ) async throws -> StoryInteractionLease {
        try await claimManualTuring(
            runID: runID,
            surfaceID: .walkie,
            source: source
        )
    }

    func claimManualTuring(
        runID: String,
        surfaceID: StoryInteractionSurfaceID,
        source: String
    ) async throws -> StoryInteractionLease {
        guard exclusiveLease == nil else {
            return try reject(.exclusiveOwnerActive, requested: "turingFlow.\(runID)", source: source)
        }
        guard stableInteractionPolicy.allowedTuringSurfaces.contains(surfaceID) else {
            return try reject(
                .interactionNotPermitted,
                requested: "turingFlow.\(runID)",
                source: source
            )
        }
        let gate = turingGates[surfaceID] ?? .closed
        guard gate == .play || gate == .microphone else {
            return try reject(.turingGateNotInteractive, requested: "turingFlow.\(runID)", source: source)
        }
        guard doorState == .closedUnloaded else {
            return try reject(.doorNotClosedAndUnloaded, requested: "turingFlow.\(runID)", source: source)
        }
        return await accept(
            owner: .turingFlow(runID: runID),
            source: source
        )
    }

    func claimAutomaticTuring(
        runID: String,
        source: String
    ) async throws -> StoryInteractionLease {
        try await claimAutomaticTuring(
            runID: runID,
            surfaceID: .walkie,
            source: source
        )
    }

    func claimAutomaticTuring(
        runID: String,
        surfaceID: StoryInteractionSurfaceID,
        source: String
    ) async throws -> StoryInteractionLease {
        guard exclusiveLease == nil else {
            return try reject(.exclusiveOwnerActive, requested: "turingFlow.\(runID)", source: source)
        }
        guard stableInteractionPolicy.allowedTuringSurfaces.contains(surfaceID) else {
            return try reject(
                .interactionNotPermitted,
                requested: "turingFlow.\(runID)",
                source: source
            )
        }
        guard doorState == .closedUnloaded else {
            return try reject(.doorNotClosedAndUnloaded, requested: "turingFlow.\(runID)", source: source)
        }
        return await accept(
            owner: .turingFlow(runID: runID),
            source: source
        )
    }

    func claimManualDoor(source: String) async throws -> StoryInteractionLease {
        guard exclusiveLease == nil else {
            return try reject(.exclusiveOwnerActive, requested: "doorPortal", source: source)
        }
        guard stableInteractionPolicy.permitsDoorInteraction else {
            return try reject(
                .interactionNotPermitted,
                requested: "doorPortal",
                source: source
            )
        }
        guard turingGates.values.contains(.busy) == false else {
            return try reject(.turingGateNotInteractive, requested: "doorPortal", source: source)
        }
        guard doorState == .closedUnloaded else {
            return try reject(.doorNotClosedAndUnloaded, requested: "doorPortal", source: source)
        }
        return await accept(
            owner: .doorPortal(sessionID: UUID()),
            source: source
        )
    }

    func claimBattle(
        battleInstanceID: UUID,
        source: String
    ) async throws -> StoryInteractionLease {
        guard exclusiveLease == nil else {
            return try reject(.exclusiveOwnerActive, requested: "battle.\(battleInstanceID.uuidString)", source: source)
        }
        return await accept(
            owner: .battle(battleInstanceID: battleInstanceID),
            source: source
        )
    }

    func claimStoryTransition(
        transitionID: UUID,
        source: String
    ) async throws -> StoryInteractionLease {
        guard exclusiveLease == nil else {
            return try reject(
                .exclusiveOwnerActive,
                requested: "storyTransition.\(transitionID.uuidString)",
                source: source
            )
        }
        guard doorState == .closedUnloaded else {
            return try reject(
                .doorNotClosedAndUnloaded,
                requested: "storyTransition.\(transitionID.uuidString)",
                source: source
            )
        }
        return await accept(
            owner: .storyTransition(transitionID: transitionID),
            source: source
        )
    }

    func transferDoorToTuring(
        doorLease: StoryInteractionLease,
        runID: String,
        reason: String
    ) async throws -> StoryInteractionLease {
        guard exclusiveLease == doorLease else {
            throw StoryInteractionClaimError.staleLease
        }
        guard case .doorPortal = doorLease.owner,
              doorState == .closedUnloaded else {
            throw StoryInteractionClaimError.invalidTransfer
        }
        return await transfer(
            from: doorLease,
            to: .turingFlow(runID: runID),
            reason: reason
        )
    }

    func transferDoorToStoryTransition(
        doorLease: StoryInteractionLease,
        transitionID: UUID,
        reason: String
    ) async throws -> StoryInteractionLease {
        guard exclusiveLease == doorLease else {
            throw StoryInteractionClaimError.staleLease
        }
        guard case .doorPortal = doorLease.owner,
              doorState == .closedUnloaded else {
            throw StoryInteractionClaimError.invalidTransfer
        }
        return await transfer(
            from: doorLease,
            to: .storyTransition(transitionID: transitionID),
            reason: reason
        )
    }

    func transferTuringToBattle(
        turingLease: StoryInteractionLease,
        battleInstanceID: UUID,
        reason: String
    ) async throws -> StoryInteractionLease {
        guard exclusiveLease == turingLease else {
            throw StoryInteractionClaimError.staleLease
        }
        guard case .turingFlow = turingLease.owner else {
            throw StoryInteractionClaimError.invalidTransfer
        }
        return await transfer(
            from: turingLease,
            to: .battle(battleInstanceID: battleInstanceID),
            reason: reason
        )
    }

    func transferTuringToStoryTransition(
        turingLease: StoryInteractionLease,
        transitionID: UUID,
        reason: String
    ) async throws -> StoryInteractionLease {
        guard exclusiveLease == turingLease else {
            throw StoryInteractionClaimError.staleLease
        }
        guard case .turingFlow = turingLease.owner else {
            throw StoryInteractionClaimError.invalidTransfer
        }
        return await transfer(
            from: turingLease,
            to: .storyTransition(transitionID: transitionID),
            reason: reason
        )
    }

    func transferStoryTransitionToBattle(
        storyTransitionLease: StoryInteractionLease,
        battleInstanceID: UUID,
        reason: String
    ) async throws -> StoryInteractionLease {
        guard exclusiveLease == storyTransitionLease else {
            throw StoryInteractionClaimError.staleLease
        }
        guard case .storyTransition = storyTransitionLease.owner else {
            throw StoryInteractionClaimError.invalidTransfer
        }
        return await transfer(
            from: storyTransitionLease,
            to: .battle(battleInstanceID: battleInstanceID),
            reason: reason
        )
    }

    func transferBattleToStoryTransition(
        battleLease: StoryInteractionLease,
        transitionID: UUID,
        reason: String
    ) async throws -> StoryInteractionLease {
        guard exclusiveLease == battleLease else {
            throw StoryInteractionClaimError.staleLease
        }
        guard case .battle = battleLease.owner else {
            throw StoryInteractionClaimError.invalidTransfer
        }
        return await transfer(
            from: battleLease,
            to: .storyTransition(transitionID: transitionID),
            reason: reason
        )
    }

    func transferBattleToTuring(
        battleLease: StoryInteractionLease,
        runID: String,
        surfaceID _: StoryInteractionSurfaceID,
        reason: String
    ) async throws -> StoryInteractionLease {
        guard exclusiveLease == battleLease else {
            throw StoryInteractionClaimError.staleLease
        }
        guard case .battle = battleLease.owner,
              doorState == .closedUnloaded else {
            throw StoryInteractionClaimError.invalidTransfer
        }
        return await transfer(
            from: battleLease,
            to: .turingFlow(runID: runID),
            reason: reason
        )
    }

    func requireCurrent(_ lease: StoryInteractionLease) throws {
        guard exclusiveLease == lease else {
            throw StoryInteractionClaimError.staleLease
        }
    }

    func setStableInteractionPolicy(
        _ policy: StoryStableInteractionPolicy,
        storyTransitionLease: StoryInteractionLease,
        reason: String
    ) async throws {
        guard exclusiveLease == storyTransitionLease else {
            throw StoryInteractionClaimError.staleLease
        }
        guard case .storyTransition = storyTransitionLease.owner else {
            throw StoryInteractionClaimError.invalidTransfer
        }
        guard stableInteractionPolicy != policy else { return }
        stableInteractionPolicy = policy
        await publish(reason: "stablePolicy.\(reason)")
    }

    func resetStableInteractionPolicy(reason: String) async {
        guard exclusiveLease == nil else {
            print(
                "[StoryInteraction] stable policy reset deferred " +
                    "owner=\(exclusiveLease?.owner.logValue ?? "none") reason=\(reason)"
            )
            return
        }
        guard stableInteractionPolicy != .unrestricted else { return }
        stableInteractionPolicy = .unrestricted
        await publish(reason: "stablePolicyReset.\(reason)")
    }

    func release(_ lease: StoryInteractionLease, reason: String) async {
        _ = await releaseAndCurrentSnapshot(lease, reason: reason)
    }

    func releaseCurrentStoryTransition(
        transitionID: UUID,
        reason: String
    ) async {
        guard let exclusiveLease,
              case .storyTransition(let currentID) = exclusiveLease.owner,
              currentID == transitionID else {
            return
        }
        await release(exclusiveLease, reason: reason)
    }

    @discardableResult
    func releaseAndCurrentSnapshot(
        _ lease: StoryInteractionLease,
        reason: String
    ) async -> StoryInteractionSnapshot {
        guard exclusiveLease == lease else {
            print("""
            [StoryInteraction] stale release ignored
              leaseID: \(lease.id.uuidString)
              owner: \(lease.owner.logValue)
              reason: \(reason)
            """)
            return makeSnapshot()
        }
        if case .battle(let battleInstanceID) = lease.owner {
            battleDoorPermissions.removeValue(forKey: battleInstanceID)
        }
        exclusiveLease = nil
        print("""
        [StoryInteraction] lease released
          leaseID: \(lease.id.uuidString)
          owner: \(lease.owner.logValue)
          reason: \(reason)
        """)
        await publish(reason: "release.\(reason)")
        return makeSnapshot()
    }

    func reset(reason: String) async {
        turingGates = [
            .walkie: .closed,
            .dadFrame: .closed,
            .crankRadio: .closed,
            .hamReceiver: .closed
        ]
        doorState = .closedUnloaded
        exclusiveLease = nil
        battleDoorPermissions.removeAll(keepingCapacity: false)
        stableInteractionPolicy = .unrestricted
        await publish(reason: "reset.\(reason)")
    }

    private func accept(
        owner: StoryInteractionExclusiveOwner,
        source: String
    ) async -> StoryInteractionLease {
        if case .battle(let battleInstanceID) = owner {
            battleDoorPermissions[battleInstanceID] = .hiddenAndLocked
        }
        let lease = StoryInteractionLease(id: UUID(), owner: owner)
        exclusiveLease = lease
        print("""
        [StoryInteraction] claim accepted
          leaseID: \(lease.id.uuidString)
          owner: \(owner.logValue)
          source: \(source)
        """)
        await publish(reason: "claim.\(source)")
        return lease
    }

    private func transfer(
        from oldLease: StoryInteractionLease,
        to owner: StoryInteractionExclusiveOwner,
        reason: String
    ) async -> StoryInteractionLease {
        if case .battle(let oldBattleInstanceID) = oldLease.owner {
            battleDoorPermissions.removeValue(forKey: oldBattleInstanceID)
        }
        if case .battle(let newBattleInstanceID) = owner {
            battleDoorPermissions[newBattleInstanceID] = .hiddenAndLocked
        }
        let newLease = StoryInteractionLease(id: UUID(), owner: owner)
        exclusiveLease = newLease
        print("""
        [StoryInteraction] ownership transferred
          from: \(oldLease.owner.logValue)
          to: \(owner.logValue)
          oldLeaseID: \(oldLease.id.uuidString)
          newLeaseID: \(newLease.id.uuidString)
          reason: \(reason)
        """)
        await publish(reason: "transfer.\(reason)")
        return newLease
    }

    private func reject<T>(
        _ error: StoryInteractionClaimError,
        requested: String,
        source: String
    ) throws -> T {
        print("""
        [StoryInteraction] claim rejected
          requestedOwner: \(requested)
          currentOwner: \(exclusiveLease?.owner.logValue ?? "none")
          turingGate: \((turingGates[.walkie] ?? .closed).rawValue)
          doorState: \(doorState.rawValue)
          source: \(source)
          reason: \(error.localizedDescription)
        """)
        throw error
    }

    private func makeSnapshot() -> StoryInteractionSnapshot {
        let capabilities: Set<StoryInteractionCapability>
        let walkie: StoryWalkiePresentation
        let door: StoryDoorPresentation
        let dadFrame: StoryDadFramePresentation
        let crankRadio:
            StoryCrankRadioPresentation
        let hamReceiver:
            StoryHamReceiverPresentation

        if let exclusiveLease {
            switch exclusiveLease.owner {
            case .turingFlow, .storyTransition:
                capabilities = []
                walkie = .hidden
                door = .hidden
                dadFrame = .hidden
                crankRadio = .hidden
                hamReceiver = .hidden
            case .battle(let battleInstanceID):
                let permission = battleDoorPermissions[battleInstanceID]
                    ?? .hiddenAndLocked
                if permission == .playerMayOpen,
                   doorState == .closedReady {
                    capabilities = [.doorOpen]
                    door = .open
                } else {
                    capabilities = []
                    door = .hidden
                }
                walkie = .hidden
                dadFrame = .hidden
                crankRadio = .hidden
                hamReceiver = .hidden
            case .doorPortal:
                if doorState == .open {
                    capabilities = [.doorClose]
                    walkie = .hidden
                    door = .close
                    dadFrame = .hidden
                    crankRadio = .hidden
                    hamReceiver = .hidden
                } else {
                    capabilities = []
                    walkie = .hidden
                    door = .hidden
                    dadFrame = .hidden
                    crankRadio = .hidden
                    hamReceiver = .hidden
                }
            }
        } else if doorState != .closedUnloaded {
            capabilities = []
            walkie = .hidden
            door = .hidden
            dadFrame = .hidden
            crankRadio = .hidden
            hamReceiver = .hidden
        } else {
            let walkieGate = stableInteractionPolicy.allowedTuringSurfaces
                .contains(.walkie)
                ? (turingGates[.walkie] ?? .closed)
                : .closed
            let dadGate = stableInteractionPolicy.allowedTuringSurfaces
                .contains(.dadFrame)
                ? (turingGates[.dadFrame] ?? .closed)
                : .closed
            let crankRadioGate = stableInteractionPolicy.allowedTuringSurfaces
                .contains(.crankRadio)
                ? (turingGates[.crankRadio] ?? .closed)
                : .closed
            let hamReceiverGate = stableInteractionPolicy.allowedTuringSurfaces
                .contains(.hamReceiver)
                ? (turingGates[.hamReceiver] ?? .closed)
                : .closed

            let anyTuringSurfaceBusy =
                turingGates.values.contains(.busy)

            if anyTuringSurfaceBusy {
                capabilities = []
                walkie = .hidden
                door = .hidden
                dadFrame = .hidden
                crankRadio = .hidden
                hamReceiver = .hidden
            } else {
                var resolvedCapabilities:
                    Set<StoryInteractionCapability> =
                        stableInteractionPolicy.permitsDoorInteraction
                        ? [.doorOpen]
                        : []

                switch walkieGate {
                case .play:
                    resolvedCapabilities.insert(.walkiePlay)
                    walkie = .play
                case .microphone:
                    resolvedCapabilities.insert(.walkieMicrophone)
                    walkie = .microphone
                case .closed, .busy:
                    walkie = .hidden
                }

                switch dadGate {
                case .play:
                    resolvedCapabilities.insert(.dadFramePlay)
                    dadFrame = .play
                case .microphone:
                    resolvedCapabilities.insert(.dadFrameMicrophone)
                    dadFrame = .microphone
                case .closed, .busy:
                    dadFrame = .hidden
                }

                switch crankRadioGate {
                case .play:
                    resolvedCapabilities.insert(
                        .crankRadioPlay
                    )
                    crankRadio = .play
                case .microphone:
                    resolvedCapabilities.insert(
                        .crankRadioMicrophone
                    )
                    crankRadio = .microphone
                case .closed, .busy:
                    crankRadio = .hidden
                }

                switch hamReceiverGate {
                case .play:
                    resolvedCapabilities.insert(
                        .hamReceiverPlay
                    )
                    hamReceiver = .play
                case .microphone:
                    resolvedCapabilities.insert(
                        .hamReceiverMicrophone
                    )
                    hamReceiver = .microphone
                case .closed, .busy:
                    hamReceiver = .hidden
                }

                capabilities = resolvedCapabilities
                door = stableInteractionPolicy.permitsDoorInteraction
                    ? .open
                    : .hidden
            }
        }

        return StoryInteractionSnapshot(
            revision: revision,
            turingGate: turingGates[.walkie] ?? .closed,
            doorState: doorState,
            exclusiveOwner: exclusiveLease?.owner,
            capabilities: capabilities,
            walkiePresentation: walkie,
            doorPresentation: door,
            dadFramePresentation: dadFrame,
            crankRadioPresentation: crankRadio,
            hamReceiverPresentation: hamReceiver
        )
    }

    private func publish(reason: String) async {
        revision &+= 1
        let snapshot = makeSnapshot()
        print("""
        [StoryInteraction] snapshot
          revision: \(snapshot.revision)
          turingGate: \(snapshot.turingGate.rawValue)
          dadFrameGate: \((turingGates[.dadFrame] ?? .closed).rawValue)
          crankRadioGate: \((turingGates[.crankRadio] ?? .closed).rawValue)
          hamReceiverGate: \((turingGates[.hamReceiver] ?? .closed).rawValue)
          doorState: \(snapshot.doorState.rawValue)
          exclusiveOwner: \(snapshot.exclusiveOwner?.logValue ?? "none")
          stablePolicy: \(stableInteractionPolicy.id.rawValue)
          capabilities: \(snapshot.capabilities.map(\.rawValue).sorted())
          walkie: \(snapshot.walkiePresentation.rawValue)
          door: \(snapshot.doorPresentation.rawValue)
          dadFrame: \(snapshot.dadFramePresentation.rawValue)
          crankRadio: \(snapshot.crankRadioPresentation.rawValue)
          hamReceiver: \(snapshot.hamReceiverPresentation.rawValue)
          reason: \(reason)
        """)
        await snapshotHub.yield(snapshot)
    }
}
