import Foundation
import Metal

@MainActor
final class MindEyePresentationCoordinator: MindEyePlacementAvailabilitySink {
    private struct PreparedVisual {
        let generation: UInt64
        let characterID: TuringConversationCharacterID
        let vignetteID: String
        let lease: MindEyeAssetLease
        let visual: any MindEyePresentationVisual
    }

    private struct ActivePresentation {
        var identity: MindEyePresentationIdentity
        var source: TuringSpokenPresentationSource
        var responseKey: MindEyeResponsePresentationKey?
        let lease: MindEyeAssetLease
        let visual: any MindEyePresentationVisual
        let providerID: String
        let providerRevision: UInt64
        var isAudible: Bool
        var isPaused: Bool
        var playbackClock: TuringPauseAwarePlaybackClock
        var authoredTrackLease: MindEyeAuthoredFrameTrackLease?
        var authoredPRID: String?
        var fillerTrackLease: MindEyeFillerFrameTrackLease?
    }

    private struct PreparedAuthoredTrack {
        let generation: UInt64
        let presentationKey: MindEyePresentationKey
        let lease: MindEyeAuthoredFrameTrackLease
        let track: MindEyeAuthoredFrameTrack
    }

    private struct DetachedMindEyeResources {
        let assetLease: MindEyeAssetLease
        let authoredTrackLease: MindEyeAuthoredFrameTrackLease?
        let fillerTrackLease: MindEyeFillerFrameTrackLease?
        let visual: any MindEyePresentationVisual
    }

    private let eventSource: any MindEyeSpokenPresentationEventStreaming
    private let assetMemory: any MindEyeAssetMemoryManaging
    private let visualBuilder: any MindEyePresentationVisualBuilding
    private let eligibility: any MindEyePresentationEligibilityChecking
    private let authoredPreparationSource: any MindEyeAuthoredPreparationStreaming
    private let revealSource: any MindEyeSpokenPresentationRevealStreaming
    private let authoredFrameStore: any MindEyeAuthoredFrameTrackManaging
    private let fillerFrameStore: MindEyeFillerFrameTrackStore
    private let physicalPresenceHub: MindEyePhysicalCharacterPresenceHub
    private let providerRegistry = MindEyePlacementProviderRegistry()

    private var eventTask: Task<Void, Never>?
    private var authoredPreparationEventTask: Task<Void, Never>?
    private var revealEventTask: Task<Void, Never>?
    private var authoredTrackTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var physicalPresenceTask: Task<Void, Never>?
    private var preparingCharacterID: TuringConversationCharacterID?
    private var buildGeneration: UInt64 = 0
    private var desiredContext: TuringSpokenPresentationContext?
    private var desiredPlaybackClock: TuringPauseAwarePlaybackClock?
    private var desiredIsPaused = false
    private var desiredIsAudible = false
    private var pendingRevealRequest: TuringSpokenPresentationRevealRequest?
    private var fillerTrackPreparationTask: Task<Void, Never>?
    private var responsePortraitLoadDecision: MindEyeResponsePortraitLoadDecision = .allowLoad
    private var prepared: PreparedVisual?
    private var preparedAuthoredTrack: PreparedAuthoredTrack?
    private var active: ActivePresentation?
    private var pendingGeneratedContinuity: TuringSpokenPresentationContinuity?
    private var authoredTrackGeneration: UInt64 = 0
    private var loggedFailureKeys = Set<String>()
    private var hasStarted = false
    private var physicalPresenceSnapshot = MindEyePhysicalCharacterPresenceSnapshot(
        generation: 0,
        claims: []
    )
    private var physicalSuppressionActive = false
    private var lifecycleAllowsPresentation = true
    private var applicationState: MindEyeApplicationLifecycleState = .active
    private var lifecycleGeneration: UInt64 = 0

    init(
        eventSource: any MindEyeSpokenPresentationEventStreaming,
        assetMemory: any MindEyeAssetMemoryManaging,
        visualBuilder: any MindEyePresentationVisualBuilding,
        eligibility: any MindEyePresentationEligibilityChecking =
            MindEyeDefaultPresentationEligibility(),
        authoredPreparationSource: any MindEyeAuthoredPreparationStreaming =
            MindEyeGlobalAuthoredPreparationSource(),
        revealSource: any MindEyeSpokenPresentationRevealStreaming =
            MindEyeGlobalSpokenPresentationRevealSource(),
        authoredFrameStore: any MindEyeAuthoredFrameTrackManaging =
            MindEyeAuthoredFrameTrackStore.shared,
        fillerFrameStore: MindEyeFillerFrameTrackStore = .shared,
        physicalPresenceHub: MindEyePhysicalCharacterPresenceHub = .shared
    ) {
        self.eventSource = eventSource
        self.assetMemory = assetMemory
        self.visualBuilder = visualBuilder
        self.eligibility = eligibility
        self.authoredPreparationSource = authoredPreparationSource
        self.revealSource = revealSource
        self.authoredFrameStore = authoredFrameStore
        self.fillerFrameStore = fillerFrameStore
        self.physicalPresenceHub = physicalPresenceHub
    }

    static func makeDefault(
        assetMemory: any MindEyeAssetMemoryManaging = MindEyeAssetMemoryManager.shared
    ) -> MindEyePresentationCoordinator {
        let builder: any MindEyePresentationVisualBuilding
        if let device = MTLCreateSystemDefaultDevice() {
            builder = MindEyeDynamicVisualFactory(
                pipeline: MindEyeCompositorPipeline(device: device)
            )
        } else {
            builder = MindEyeUnavailableDynamicVisualFactory()
        }
        return MindEyePresentationCoordinator(
            eventSource: MindEyeGlobalSpokenPresentationEventSource(),
            assetMemory: assetMemory,
            visualBuilder: builder
        )
    }

    func bindPlacementProviders(
        _ providers: [any MindEyePlacementProviding]
    ) {
        for provider in providers {
            if case .failure(let failure) = providerRegistry.bind(provider, sink: self) {
                logFailureOnce(failure, context: nil, stage: "bindPlacementProvider")
            }
        }
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await eventSource.events()
            for await event in stream {
                guard !Task.isCancelled else { return }
                await handle(event)
            }
        }
        authoredPreparationEventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await authoredPreparationSource.events()
            for await hint in stream {
                guard !Task.isCancelled else { return }
                await handleAuthoredPreparationHint(hint)
            }
        }
        revealEventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await revealSource.events()
            for await request in stream {
                guard !Task.isCancelled else { return }
                await handleRevealRequest(request)
            }
        }
        physicalPresenceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await physicalPresenceHub.stream()
            for await snapshot in stream {
                guard !Task.isCancelled else { return }
                await applyPhysicalPresence(snapshot)
            }
        }
        Task { [authoredFrameStore] in
            _ = await authoredFrameStore.prepareIndex()
        }
        Task { [fillerFrameStore] in
            _ = await fillerFrameStore.prepareIndex()
        }
        print("[MindEyePresentation] event stream started")
    }

    func arm(
        characterID: TuringConversationCharacterID,
        reason: String
    ) async {
        guard lifecycleAllowsPresentation,
              applicationState == .active,
              !physicalSuppressionActive else { return }
        if let active,
           active.identity.speakerCharacterID != characterID {
            return
        }
        if prepared?.characterID == characterID { return }
        let task = schedulePreparation(
            characterID: characterID,
            reason: "arm.\(reason)"
        )
        await task?.value
    }

    func reset(reason: String) async {
        _ = await releaseAllPresentationState(
            scope: .storyBoundary,
            reason: reason,
            keepEventSubscriptions: true
        )
        loggedFailureKeys.removeAll(keepingCapacity: false)
        print("[MindEyePresentation] reset reason=\(reason)")
    }

    func setLifecycleAllowsPresentation(_ allowed: Bool, reason: String) {
        guard lifecycleAllowsPresentation != allowed else { return }
        lifecycleAllowsPresentation = allowed
        print("[MindEyeLifecycle] presentation gate allowed=\(allowed) reason=\(reason)")
    }

    func setResponsePortraitLoadDecision(
        _ decision: MindEyeResponsePortraitLoadDecision,
        reason: String
    ) {
        responsePortraitLoadDecision = decision
        print("[MindEyeLifecycle] response portrait load=\(decision) reason=\(reason)")
    }

    func setApplicationState(
        _ state: MindEyeApplicationLifecycleState,
        reason: String
    ) {
        applicationState = state
        print("[MindEyeLifecycle] application state=\(state.rawValue) reason=\(reason)")
    }

    func suspendForApplicationInactive(reason: String) async {
        active?.visual.setVisualSuspension(
            .applicationInactive,
            active: true,
            resampleAt: nil,
            diagnosticReason: reason
        )
        preparationTask?.cancel()
        preparationTask = nil
        preparingCharacterID = nil
        authoredTrackTask?.cancel()
        authoredTrackTask = nil
        fillerTrackPreparationTask?.cancel()
        fillerTrackPreparationTask = nil
        await releasePreparedAuthoredTrack(reason: "applicationInactive.\(reason)")
        await releasePrepared(reason: "applicationInactive.\(reason)")
    }

    func resumeAfterApplicationInactive(
        at instant: ContinuousClock.Instant,
        reason: String
    ) async {
        active?.visual.setVisualSuspension(
            .applicationInactive,
            active: false,
            resampleAt: instant,
            diagnosticReason: reason
        )
        guard let desiredContext,
              lifecycleAllowsPresentation,
              !physicalSuppressionActive else { return }
        if canReuseActiveResponsePortrait(for: desiredContext) {
            await reuseActiveResponsePortrait(for: desiredContext)
        } else if active == nil {
            if case .authored(let prerecordingID, _) = desiredContext.source {
                let clock = desiredPlaybackClock ??
                    TuringPauseAwarePlaybackClock(origin: desiredContext.clockOrigin)
                scheduleAuthoredTrackAcquisition(
                    context: desiredContext,
                    clock: clock,
                    prID: prerecordingID
                )
            }
            await attemptPresentDesiredContext(reason: "applicationActiveLateJoin")
        }
    }

    func releasePreparedAndEvictInactive(reason: String) async {
        buildGeneration &+= 1
        authoredTrackGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        preparingCharacterID = nil
        authoredTrackTask?.cancel()
        authoredTrackTask = nil
        fillerTrackPreparationTask?.cancel()
        fillerTrackPreparationTask = nil
        await releasePreparedAuthoredTrack(reason: reason)
        await releasePrepared(reason: reason)
        _ = await assetMemory.evictInactive(reason: reason)
        await authoredFrameStore.evictInactive(reason: reason)
        await fillerFrameStore.evictInactive(reason: reason)
    }

    func releaseAllPresentationState(
        scope: MindEyeTeardownScope,
        reason: String,
        keepEventSubscriptions: Bool
    ) async -> MindEyeTeardownReport {
        lifecycleGeneration &+= 1
        buildGeneration &+= 1
        authoredTrackGeneration &+= 1
        let hadActive = active != nil
        let hadPrepared = prepared != nil
        let hadActiveTrack = active?.authoredTrackLease != nil
        let hadPreparedTrack = preparedAuthoredTrack != nil
        desiredContext = nil
        desiredPlaybackClock = nil
        desiredIsPaused = false
        desiredIsAudible = false
        pendingRevealRequest = nil
        pendingGeneratedContinuity = nil
        preparationTask?.cancel()
        preparationTask = nil
        preparingCharacterID = nil
        authoredTrackTask?.cancel()
        authoredTrackTask = nil
        fillerTrackPreparationTask?.cancel()
        fillerTrackPreparationTask = nil
        if let resources = detachActiveImmediately(reason: "\(scope.rawValue).\(reason)") {
            await releaseDetached(resources, reason: "\(scope.rawValue).\(reason)")
        }
        await releasePreparedAuthoredTrack(reason: "\(scope.rawValue).\(reason)")
        await releasePrepared(reason: "\(scope.rawValue).\(reason)")
        switch scope {
        case .memoryCritical, .applicationBackground, .immersiveShutdown:
            await fillerFrameStore.forceEvictAll(reason: "\(scope.rawValue).\(reason)")
        default:
            await fillerFrameStore.evictInactive(reason: "\(scope.rawValue).\(reason)")
        }
        if !keepEventSubscriptions {
            eventTask?.cancel()
            eventTask = nil
            authoredPreparationEventTask?.cancel()
            authoredPreparationEventTask = nil
            revealEventTask?.cancel()
            revealEventTask = nil
            physicalPresenceTask?.cancel()
            physicalPresenceTask = nil
            hasStarted = false
        }
        return await makeTeardownReport(
            scope: scope,
            reason: reason,
            activeVisualRemoved: hadActive,
            preparedVisualRemoved: hadPrepared,
            activeAuthoredTrackReleased: hadActiveTrack,
            preparedAuthoredTrackReleased: hadPreparedTrack
        )
    }

    func prepareForTuringHighMemoryRun(
        runID: String,
        policy: MindEyeActiveHighMemoryRetentionPolicy,
        continuity: TuringSpokenPresentationContinuity?
    ) async -> MindEyeHighMemoryPreparationReport {
        let beforeAsset = await assetMemory.snapshot()
        let beforeTracks = await authoredFrameStore.snapshot()
        let hadPreparedVisual = prepared != nil
        let hadPreparedTrack = preparedAuthoredTrack != nil
        buildGeneration &+= 1
        authoredTrackGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        preparingCharacterID = nil
        authoredTrackTask?.cancel()
        authoredTrackTask = nil
        await releasePreparedAuthoredTrack(reason: "qwenPreflight.\(runID)")
        await releasePrepared(reason: "qwenPreflight.\(runID)")

        var activeRetained = false
        var activeReleased = false
        var retainedRunID: String?
        // The child identity is useful even when its authored parent metadata
        // is absent. It tells us which portrait belongs on the device while
        // the generated response is still computing.
        pendingGeneratedContinuity = continuity
        if let active {
            let matches = active.identity.key.playbackRunID == runID
            let shouldRetain: Bool
            switch policy {
            case .retainMatchingRunActive:
                shouldRetain = matches
            case .retainActivePresentation:
                let exactParentMatch = Self.matchesContinuityParent(
                    active: active,
                    runID: runID,
                    continuity: continuity
                )
                // Qwen preflight must never tear down an authored portrait
                // whose PR lifecycle is still active. The current speaker's
                // authored mouth, blink, and motion systems continue until the
                // authored audio completion event, even when incomplete or
                // stale continuity metadata prevents the exact handoff match.
                let activeAuthoredPlayback: Bool
                if case .authored = active.source {
                    activeAuthoredPlayback = true
                } else {
                    activeAuthoredPlayback = false
                }
                shouldRetain = exactParentMatch || activeAuthoredPlayback
                if activeAuthoredPlayback && !exactParentMatch {
                    print(
                        "[MindEyePresentation] active authored playback retained " +
                            "despite continuity metadata mismatch " +
                            "authoredRun=\(active.identity.key.playbackRunID) " +
                            "generatedRun=\(runID)"
                    )
                }
            case .releaseAll:
                shouldRetain = false
            }
            if shouldRetain {
                activeRetained = true
                retainedRunID = active.identity.key.playbackRunID
                if policy == .retainActivePresentation,
                   let continuity {
                    print(
                        "[MindEyePresentation] authored portrait retained " +
                            "for generated handoff authoredRun=" +
                            "\(active.identity.key.playbackRunID) " +
                            "generatedRun=\(runID) " +
                            "continuity=\(continuity.continuityID.uuidString)"
                    )
                }
            } else if let resources = detachActiveImmediately(reason: "qwenPreflight.\(runID)") {
                await releaseDetached(resources, reason: "qwenPreflight.\(runID)")
                activeReleased = true
            }
        }
        if pendingGeneratedContinuity == nil, let continuity {
            // Generic detach clears all presentation state. This child still
            // owns the compute interval, so restore its exact preview identity.
            pendingGeneratedContinuity = continuity
        }
        _ = await assetMemory.evictInactive(reason: "qwenPreflight.\(runID)")
        await authoredFrameStore.evictInactive(reason: "qwenPreflight.\(runID)")
        await fillerFrameStore.evictInactive(reason: "qwenPreflight.\(runID)")

        var afterAsset = await assetMemory.snapshot()
        var afterTracks = await authoredFrameStore.snapshot()
        var forced = false
        if !activeRetained,
           afterAsset.uniqueResidentPackageCount > 0 || !afterTracks.cachedPRIDs.isEmpty {
            forced = true
            await assetMemory.forceEvictAll(reason: "qwenPreflight.fallback.\(runID)")
            await authoredFrameStore.forceEvictAll(reason: "qwenPreflight.fallback.\(runID)")
            await fillerFrameStore.forceEvictAll(reason: "qwenPreflight.fallback.\(runID)")
            afterAsset = await assetMemory.snapshot()
            afterTracks = await authoredFrameStore.snapshot()
        }
        if active == nil, let continuity {
            beginUpcomingGeneratedIdle(
                continuity,
                reason: "qwenPreflight.noAudiblePortrait"
            )
        } else if let active, let continuity {
            print(
                "[MindEyePresentation] upcoming generated portrait staged " +
                    "generatedRun=\(continuity.childPlaybackRunID) " +
                    "upcomingSpeaker=\(continuity.speakerCharacterID.rawValue) " +
                    "upcomingSurface=\(continuity.interactionSurface.rawValue) " +
                    "activeSpeaker=\(active.identity.speakerCharacterID.rawValue) " +
                    "activeMedia=\(active.identity.mediaIdentity) " +
                    "transition=afterAudibleCompletion"
            )
        }
        return MindEyeHighMemoryPreparationReport(
            runID: runID,
            policy: policy,
            preparedVisualReleased: hadPreparedVisual,
            preparedAuthoredTrackReleased: hadPreparedTrack,
            activePresentationRetained: activeRetained,
            activePresentationReleased: activeReleased,
            retainedActiveRunID: retainedRunID,
            assetCacheBefore: beforeAsset.uniqueResidentPackageCount,
            assetCacheAfter: afterAsset.uniqueResidentPackageCount,
            authoredTrackCacheBefore: beforeTracks.cachedPRIDs.count,
            authoredTrackCacheAfter: afterTracks.cachedPRIDs.count,
            forcedEvictionApplied: forced,
            visualRegistryEntriesAfter: MindEyeMotionFrameRegistry.shared.entryCount,
            authoredRegistryEntriesAfter: MindEyeAuthoredFramePlaybackRegistry.shared.entryCount,
            generatedRegistryEntriesAfter: MindEyeGeneratedFramePlaybackRegistry.shared.entryCount
        )
    }

    private static func matchesContinuityParent(
        active: ActivePresentation,
        runID: String,
        continuity: TuringSpokenPresentationContinuity?
    ) -> Bool {
        guard let continuity,
              let parent = continuity.parent,
              continuity.childPlaybackRunID == runID else { return false }
        let playbackRunMatches =
            active.identity.key.playbackRunID == parent.playbackRunID
        let flowMatches = active.identity.flowInstanceID == parent.flowInstanceID
        let mediaMatches = active.identity.mediaIdentity == parent.mediaIdentity
        let surfaceMatches =
            active.identity.interactionSurface == continuity.interactionSurface
        let matches = playbackRunMatches &&
            flowMatches &&
            mediaMatches &&
            surfaceMatches
        if !matches {
            print(
                "[MindEyePresentation] authored continuity parent mismatch " +
                    "activeRun=\(active.identity.key.playbackRunID) " +
                    "parentRun=\(parent.playbackRunID) " +
                    "activeFlow=\(active.identity.flowInstanceID.uuidString) " +
                    "parentFlow=\(parent.flowInstanceID.uuidString) " +
                    "activeMedia=\(active.identity.mediaIdentity) " +
                    "parentMedia=\(parent.mediaIdentity) " +
                    "activeSpeaker=\(active.identity.speakerCharacterID.rawValue) " +
                    "childSpeaker=\(continuity.speakerCharacterID.rawValue) " +
                    "playbackRunMatches=\(playbackRunMatches) " +
                    "flowMatches=\(flowMatches) " +
                    "mediaMatches=\(mediaMatches) " +
                    "surfaceMatches=\(surfaceMatches)"
            )
        }
        return matches
    }

    func shutdown(reason: String) async -> MindEyeTeardownReport {
        let report = await releaseAllPresentationState(
            scope: .immersiveShutdown,
            reason: reason,
            keepEventSubscriptions: false
        )
        providerRegistry.removeAll()
        await assetMemory.forceEvictAll(reason: "mindEyeShutdown.\(reason)")
        await authoredFrameStore.forceEvictAll(reason: "mindEyeShutdown.\(reason)")
        await fillerFrameStore.forceEvictAll(reason: "mindEyeShutdown.\(reason)")
        print("[MindEyePresentation] shutdown reason=\(reason)")
        return report
    }

    func mindEyePlacementProviderDidBecomeAvailable(
        providerID: String,
        surfaces: Set<StoryInteractionSurfaceID>,
        revision: UInt64
    ) {
        guard let desiredContext,
              surfaces.contains(desiredContext.interactionSurface) else { return }
        Task { @MainActor [weak self] in
            await self?.attemptPresentDesiredContext(
                reason: "providerAvailable.\(providerID).\(revision)"
            )
        }
    }

    func mindEyePlacementProviderDidInvalidate(
        providerID: String,
        surfaces: Set<StoryInteractionSurfaceID>,
        revision: UInt64,
        reason: String
    ) {
        guard let active,
              active.providerID == providerID,
              surfaces.contains(active.identity.interactionSurface) else { return }
        if let resources = detachActiveImmediately(
            reason: "providerInvalidated.\(providerID).\(reason)"
        ) {
            Task { @MainActor [weak self] in
                guard let self else { return }
                await releaseDetached(
                    resources,
                    reason: "providerInvalidated.\(providerID).\(reason)"
                )
                guard let context = desiredContext,
                      case .authored(let prerecordingID, _) = context.source else {
                    return
                }
                let clock = desiredPlaybackClock ??
                    TuringPauseAwarePlaybackClock(origin: context.clockOrigin)
                scheduleAuthoredTrackAcquisition(
                    context: context,
                    clock: clock,
                    prID: prerecordingID
                )
            }
        }
        print(
            "[MindEyePlacement] active visual invalidated provider=\(providerID) " +
                "revision=\(revision) reason=\(reason)"
        )
    }

    func enqueueActiveFrameForTesting(
        _ frame: MindEyeCompositeFrameState,
        identity: MindEyePresentationIdentity
    ) {
        guard active?.identity == identity else { return }
        active?.visual.enqueueFrame(frame)
    }

    private func handle(_ event: TuringSpokenPresentationEvent) async {
        switch event {
        case .started(let context):
            await spokenMediaStarted(context)
        case .paused(let context, _, let clock, let reason):
            let key = MindEyePresentationKey(context: context)
            if desiredContext.map({ MindEyePresentationKey(context: $0) }) == key {
                desiredPlaybackClock = clock
                desiredIsPaused = true
            }
            if var active, active.identity.key == key {
                active.isPaused = true
                active.playbackClock = clock
                // Pausing spoken audio for a live-microphone turn freezes only
                // the speech-driven mouth timeline. Keep-alive motion owns the
                // blink scheduler, so globally suspending frame updates here
                // would make the portrait look dead while the listener talks.
                (active.visual as? any MindEyeAuthoredMouthControlling)?
                    .updateAuthoredMouthClock(
                        clock,
                        paused: true,
                        instant: nil,
                        reason: reason
                    )
                (active.visual as? any MindEyeGeneratedMouthControlling)?
                    .updateGeneratedMouthClock(
                        clock,
                        paused: true,
                        instant: nil,
                        reason: reason
                    )
                self.active = active
                print(
                    "[MindEyePresentation] spoken animation paused " +
                        "run=\(context.run.playbackRunID) " +
                        "reason=\(reason) mouth=frozen " +
                        "keepAlive=continues blink=continues"
                )
            }
        case .resumed(let context, let instant, let clock, let reason):
            let key = MindEyePresentationKey(context: context)
            if desiredContext.map({ MindEyePresentationKey(context: $0) }) == key {
                desiredPlaybackClock = clock
                desiredIsPaused = false
            }
            if var active, active.identity.key == key {
                active.isPaused = false
                active.playbackClock = clock
                (active.visual as? any MindEyeAuthoredMouthControlling)?
                    .updateAuthoredMouthClock(
                        clock,
                        paused: false,
                        instant: instant,
                        reason: reason
                    )
                (active.visual as? any MindEyeGeneratedMouthControlling)?
                    .updateGeneratedMouthClock(
                        clock,
                        paused: false,
                        instant: instant,
                        reason: reason
                    )
                self.active = active
                print(
                    "[MindEyePresentation] spoken animation resumed " +
                        "run=\(context.run.playbackRunID) " +
                        "reason=\(reason) mouth=resumed " +
                        "keepAlive=continues blink=continues"
                )
            }
        case .authoredItemCompleted(let context, _):
            await spokenMediaEnded(
                key: MindEyePresentationKey(context: context),
                reason: "spokenItemCompleted"
            )
        case .fillerItemCompleted(let context, _, let successfully):
            await fillerItemEnded(
                context: context,
                reason: successfully ? "fillerCompleted" : "fillerFailed"
            )
        case .generatedSegmentCompleted(let context, let clock):
            await generatedSegmentEnded(context: context, clock: clock)
        case .generatedTrackBecameAvailable(let context, let ticketID, let timing):
            await generatedTrackBecameAvailable(
                context: context,
                ticketID: ticketID,
                timing: timing
            )
        case .responseCompleted(let run):
            await responseEnded(
                run: run,
                reason: "responseCompleted"
            )
        case .cancelled(let context, _, let reason):
            await spokenMediaEnded(
                key: MindEyePresentationKey(context: context),
                reason: "cancelled.\(reason)"
            )
        case .failed(let run, let source, _, let message):
            await spokenMediaFailed(
                run: run,
                source: source,
                message: message
            )
        }
    }

    private func spokenMediaStarted(
        _ context: TuringSpokenPresentationContext
    ) async {
        guard !physicalSuppressionActive else {
            print(
                "[MindEyePresentation] actual start suppressed reason=physicalMikeEncounter " +
                    "speaker=\(context.speakerCharacterID.rawValue) " +
                    "media=\(context.source.mediaIdentity)"
            )
            return
        }
        guard applicationState != .background,
              lifecycleAllowsPresentation || applicationState == .inactive else {
            print(
                "[MindEyePresentation] actual start suppressed reason=lifecycleGate " +
                    "state=\(applicationState.rawValue) media=\(context.source.mediaIdentity)"
            )
            return
        }
        let identity = MindEyePresentationIdentity(context: context)
        if desiredContext.map({ MindEyePresentationKey(context: $0) }) == identity.key {
            return
        }

        if applicationState == .active,
           canPromotePreAudioReveal(to: context) {
            await promotePreAudioReveal(to: context)
            return
        }
        if applicationState == .active,
           canPromoteGeneratedContinuity(to: context) {
            await promoteGeneratedContinuity(to: context)
            return
        }
        if pendingRevealRequest?.key == Self.revealKey(for: context) {
            pendingRevealRequest = nil
        }

        if applicationState == .active,
           canReuseActiveResponsePortrait(for: context) {
            await reuseActiveResponsePortrait(for: context)
            return
        }

        authoredTrackGeneration &+= 1
        authoredTrackTask?.cancel()
        authoredTrackTask = nil
        await releasePreparedAuthoredTrack(reason: "replacement.\(identity.mediaIdentity)")
        desiredContext = nil
        desiredPlaybackClock = nil
        desiredIsPaused = false
        desiredIsAudible = false
        if let resources = detachActiveImmediately(
            reason: "replacement.\(identity.mediaIdentity)"
        ) {
            await releaseDetached(resources, reason: "replacement.\(identity.mediaIdentity)")
        }

        switch eligibility.decision(for: context) {
        case .suppressed(let reason):
            print(
                "[MindEyePresentation] start suppressed speaker=" +
                    "\(identity.speakerCharacterID.rawValue) media=" +
                    "\(identity.mediaIdentity) reason=\(reason)"
            )
            return
        case .eligible:
            desiredContext = context
            let clock = TuringPauseAwarePlaybackClock(origin: context.clockOrigin)
            desiredPlaybackClock = clock
            desiredIsPaused = false
            desiredIsAudible = true
            if case .authored(let prerecordingID, _) = context.source {
                guard applicationState == .active else { break }
                scheduleAuthoredTrackAcquisition(
                    context: context,
                    clock: clock,
                    prID: prerecordingID
                )
            }
        }
        guard applicationState == .active else {
            print(
                "[MindEyeLifecycle] actual start deferred while inactive " +
                    "media=\(identity.mediaIdentity)"
            )
            return
        }
        await attemptPresentDesiredContext(reason: "actualSpokenStart")
        if case .filler(let identity) = context.source,
           let clip = await resolveFillerDescriptor(identity: identity) {
            await acquireAndInstallFillerTrack(
                clip: clip,
                context: context,
                reason: "actualFillerStart"
            )
        }
    }

    private func canReuseActiveResponsePortrait(
        for context: TuringSpokenPresentationContext
    ) -> Bool {
        guard let requested = context.responsePresentationKey,
              let active else { return false }
        return active.responseKey == requested &&
            active.identity.speakerCharacterID == context.speakerCharacterID &&
            active.identity.interactionSurface == context.interactionSurface
    }

    private func canPromoteGeneratedContinuity(
        to context: TuringSpokenPresentationContext
    ) -> Bool {
        guard context.source.participatesInResponseContinuity,
              let continuity = pendingGeneratedContinuity,
              let active else {
            return false
        }
        return continuity.childPlaybackRunID ==
                context.run.playbackRunID &&
            continuity.childFlowInstanceID == context.run.flowInstanceID &&
            context.run.continuity?.continuityID == continuity.continuityID &&
            continuity.speakerCharacterID == context.speakerCharacterID &&
            continuity.interactionSurface == context.interactionSurface &&
            active.identity.speakerCharacterID ==
                context.speakerCharacterID &&
            active.identity.interactionSurface == context.interactionSurface
    }

    private func promoteGeneratedContinuity(
        to context: TuringSpokenPresentationContext
    ) async {
        guard var active,
              canPromoteGeneratedContinuity(to: context) else {
            return
        }
        pendingGeneratedContinuity = nil
        (active.visual as? any MindEyeAuthoredMouthControlling)?
            .stopAuthoredMouthPlayback(
                reason: "promoteGeneratedContinuity",
                resetToRest: true
            )
        if let lease = active.authoredTrackLease {
            await authoredFrameStore.release(
                lease,
                reason: "promoteGeneratedContinuity"
            )
            active.authoredTrackLease = nil
            active.authoredPRID = nil
            self.active = active
        }
        await reuseActiveResponsePortrait(for: context)
        print(
            "[MindEyePresentation] authored portrait promoted to generated " +
                "run=\(context.run.playbackRunID) " +
                "media=\(context.source.mediaIdentity) cardRebuilt=false"
        )
    }

    private func canPromotePreAudioReveal(
        to context: TuringSpokenPresentationContext
    ) -> Bool {
        guard let request = pendingRevealRequest,
              request.key == Self.revealKey(for: context),
              let active else { return false }
        return portraitMatches(active.identity, request: request)
    }

    private func promotePreAudioReveal(
        to context: TuringSpokenPresentationContext
    ) async {
        guard var active,
              let request = pendingRevealRequest,
              request.key == Self.revealKey(for: context),
              portraitMatches(active.identity, request: request) else {
            return
        }
        let identity = MindEyePresentationIdentity(context: context)
        let clock = TuringPauseAwarePlaybackClock(origin: context.clockOrigin)
        (active.visual as? any MindEyeAuthoredMouthControlling)?
            .stopAuthoredMouthPlayback(
                reason: "preAudioRevealPromoted",
                resetToRest: true
            )
        (active.visual as? any MindEyeGeneratedMouthControlling)?
            .stopGeneratedMouthPlayback(
                reason: "preAudioRevealPromoted",
                resetToRest: true
            )
        active.identity = identity
        active.source = context.source
        active.responseKey = context.responsePresentationKey
        active.isAudible = true
        active.isPaused = false
        active.playbackClock = clock
        self.active = active
        desiredContext = context
        desiredPlaybackClock = clock
        desiredIsPaused = false
        desiredIsAudible = true
        pendingRevealRequest = nil

        switch context.source {
        case .authored(let prerecordingID, _):
            scheduleAuthoredTrackAcquisition(
                context: context,
                clock: clock,
                prID: prerecordingID
            )
        case .generated:
            startGeneratedMouthIfAvailable(
                context: context,
                active: active,
                reason: "preAudioRevealPromoted"
            )
        case .filler(let identity):
            if let clip = await resolveFillerDescriptor(identity: identity) {
                await acquireAndInstallFillerTrack(
                    clip: clip,
                    context: context,
                    reason: "preAudioRevealPromoted"
                )
            }
        }
        print(
            "[MindEyePresentation] idle reveal promoted to audible playback " +
                "media=\(context.source.mediaIdentity) motionRestarted=false"
        )
    }

    private func reuseActiveResponsePortrait(
        for context: TuringSpokenPresentationContext
    ) async {
        guard var active else { return }
        let identity = MindEyePresentationIdentity(context: context)
        let clock = TuringPauseAwarePlaybackClock(origin: context.clockOrigin)
        (active.visual as? any MindEyeGeneratedMouthControlling)?
            .stopGeneratedMouthPlayback(reason: "replaceResponseClip", resetToRest: true)
        (active.visual as? any MindEyeAuthoredMouthControlling)?
            .stopAuthoredMouthPlayback(reason: "replaceResponseClip", resetToRest: true)
        if let lease = active.fillerTrackLease {
            await fillerFrameStore.release(lease, reason: "replaceResponseClip")
            active.fillerTrackLease = nil
        }
        active.identity = identity
        active.source = context.source
        active.responseKey = context.responsePresentationKey
        active.isAudible = true
        active.isPaused = false
        active.playbackClock = clock
        self.active = active
        desiredContext = context
        desiredPlaybackClock = clock
        desiredIsPaused = false
        desiredIsAudible = true
        switch context.source {
        case .generated:
            fillerTrackPreparationTask?.cancel()
            fillerTrackPreparationTask = nil
            startGeneratedMouthIfAvailable(
                context: context,
                active: active,
                reason: "reuseResponsePortrait"
            )
        case .filler(let identity):
            if let clip = await resolveFillerDescriptor(identity: identity) {
                await acquireAndInstallFillerTrack(
                    clip: clip,
                    context: context,
                    reason: "reuseResponsePortrait"
                )
            }
        case .authored:
            break
        }
        print(
            "[MindEyePresentation] response portrait reused run=\(context.run.playbackRunID) " +
                "media=\(context.source.mediaIdentity) cardRebuilt=false motionRestarted=false"
        )
    }

    private func generatedSegmentEnded(
        context: TuringSpokenPresentationContext,
        clock: TuringPauseAwarePlaybackClock
    ) async {
        let key = MindEyePresentationKey(context: context)
        guard desiredContext.map({ MindEyePresentationKey(context: $0) }) == key ||
                active?.identity.key == key else {
            print(
                "[MindEyeGenerated] stale segment completion ignored run=\(key.playbackRunID) " +
                    "handle=\(key.playbackHandleID.uuidString)"
            )
            return
        }
        if desiredContext.map({ MindEyePresentationKey(context: $0) }) == key {
            desiredContext = nil
            desiredPlaybackClock = nil
            desiredIsPaused = false
            desiredIsAudible = false
        }
        if var active, active.identity.key == key {
            active.playbackClock = clock
            active.isAudible = false
            (active.visual as? any MindEyeGeneratedMouthControlling)?
                .stopGeneratedMouthPlayback(
                    reason: "generatedSegmentCompleted",
                    resetToRest: true
                )
            self.active = active
        }
        print(
            "[MindEyeGenerated] segment complete; portrait retained run=\(key.playbackRunID) " +
                "media=\(context.source.mediaIdentity) mouth=rest"
        )
    }

    private func generatedTrackBecameAvailable(
        context: TuringSpokenPresentationContext,
        ticketID: UUID,
        timing: TuringGeneratedSpeechAnalysisTiming
    ) async {
        let key = MindEyePresentationKey(context: context)
        if desiredContext.map({ MindEyePresentationKey(context: $0) }) == key {
            desiredContext = context
        }
        guard var active,
              active.identity.key == key,
              case .generated(let activeSegment) = active.source,
              case .generated(let incomingSegment) = context.source,
              activeSegment == incomingSegment,
              active.identity.speakerCharacterID == context.speakerCharacterID,
              active.identity.interactionSurface == context.interactionSurface else {
            print(
                "[MindEyeGenerated] stale late track rejected " +
                    "ticket=\(ticketID.uuidString) media=\(context.source.mediaIdentity)"
            )
            return
        }
        active.playbackClock = desiredPlaybackClock ?? active.playbackClock
        if let track = context.generatedSpeechFrameTrack {
            let duration = Duration.seconds(
                Double(track.sampleCount) / Double(track.sampleRate)
            )
            let elapsed = active.playbackClock.elapsed(at: .now)
            if duration - elapsed < .milliseconds(350) {
                print(
                    "[MindEyeGenerated] late track discarded reason=lateTooCloseToEnd " +
                        "ticket=\(ticketID.uuidString) segment=\(incomingSegment)"
                )
                return
            }
        }
        self.active = active
        startGeneratedMouthIfAvailable(
            context: context,
            active: active,
            reason: "lateAnalysisTicket.\(ticketID.uuidString)"
        )
        print(
            "[MindEyeGenerated] late track attached ticket=\(ticketID.uuidString) " +
                "segment=\(incomingSegment) queueNs=\(timing.queueDelayNanoseconds ?? 0) " +
                "computeNs=\(timing.computeNanoseconds ?? 0) clock=currentElapsed"
        )
    }

    private func fillerItemEnded(
        context: TuringSpokenPresentationContext,
        reason: String
    ) async {
        fillerTrackPreparationTask?.cancel()
        fillerTrackPreparationTask = nil
        let key = MindEyePresentationKey(context: context)
        if desiredContext.map({ MindEyePresentationKey(context: $0) }) == key {
            desiredContext = nil
            desiredPlaybackClock = nil
            desiredIsPaused = false
            desiredIsAudible = false
        }
        guard var active,
              active.identity.key == key,
              case .filler(let completedClip) = context.source,
              case .filler(let activeClip) = active.source,
              completedClip.fillerID == activeClip.fillerID else {
            print("[MindEyeFiller] stale completion ignored media=\(context.source.mediaIdentity)")
            return
        }
        (active.visual as? any MindEyeAuthoredMouthControlling)?
            .stopAuthoredMouthPlayback(reason: reason, resetToRest: true)
        active.isAudible = false
        if let lease = active.fillerTrackLease {
            await fillerFrameStore.release(lease, reason: reason)
            active.fillerTrackLease = nil
        }
        self.active = active
        print(
            "[MindEyeFiller] clip complete; response portrait retained " +
                "media=\(context.source.mediaIdentity) mouth=rest"
        )
    }

    private func resolveFillerDescriptor(
        identity: TuringFillerClipIdentity
    ) async -> TuringFillerClipDescriptor? {
        guard let resourceRoot = Bundle.main.resourceURL else { return nil }
        let url = resourceRoot.appendingPathComponent(identity.audioResourcePath)
        return TuringFillerClipDescriptor(
            identity: identity,
            fileURL: url,
            weight: 1,
            authoringMode: identity.trackResourcePath == nil
                ? .untrackedFallback
                : .manualTranscript
        )
    }

    private func acquireAndInstallFillerTrack(
        clip: TuringFillerClipDescriptor,
        context: TuringSpokenPresentationContext,
        reason: String
    ) async {
        guard clip.isTrackedForMindEye,
              let current = active,
              current.identity.key == MindEyePresentationKey(context: context) else {
            return
        }
        if current.fillerTrackLease?.fillerID == clip.identity.fillerID {
            return
        }
        let acquisition = await fillerFrameStore.acquire(
            clip: clip,
            expectedSurface: context.interactionSurface,
            reason: reason
        )
        fillerTrackPreparationTask = nil
        guard case .ready(let lease, let track) = acquisition else {
            if case .unavailable(let failure) = acquisition {
                logFailureOnce(failure, context: context, stage: "acquireFillerTrack")
            }
            return
        }
        let key = MindEyePresentationKey(context: context)
        guard var active,
              active.identity.key == key,
              case .filler(let activeClip) = active.source,
              activeClip.fillerID == clip.identity.fillerID,
              let visual = active.visual as? any MindEyeAuthoredMouthControlling else {
            await fillerFrameStore.release(lease, reason: "staleFillerTrackAcquisition")
            return
        }
        let responseRootSeed = MindEyeMotionSeedFactory.rootSeed(
            for: active.identity.makeMotionSeedDescriptor(
                vignetteID: active.visual.descriptor.vignetteID
            )
        )
        let fillerRootSeed = MindEyeMotionSeedFactory.substreamSeed(
            root: responseRootSeed,
            tag: [
                "filler-mouth",
                clip.identity.fillerID,
                clip.identity.audioSHA256 ?? "untracked",
                context.playbackHandle.id.uuidString.lowercased()
            ].joined(separator: "|")
        )
        let result = visual.startAuthoredMouthPlayback(
            context: MindEyeAuthoredMouthPlaybackContext(
                presentationKey: key,
                track: track,
                clock: active.playbackClock,
                rootSeed: fillerRootSeed,
                explicitTestSeed: nil
            )
        )
        switch result {
        case .failure(let failure):
            await fillerFrameStore.release(lease, reason: "fillerPlaybackStartFailed")
            logFailureOnce(failure, context: context, stage: "startFillerMouth")
        case .success:
            if let previous = active.fillerTrackLease, previous != lease {
                await fillerFrameStore.release(previous, reason: "replaceFillerTrack")
            }
            active.fillerTrackLease = lease
            self.active = active
            print(
                "[MindEyeFiller] mouth track installed fillerID=\(clip.identity.fillerID) " +
                    "clockOrigin=actualEndpointStart"
            )
        }
    }

    private func startGeneratedMouthIfAvailable(
        context: TuringSpokenPresentationContext,
        active: ActivePresentation,
        reason: String
    ) {
        guard case .generated(let segmentIndex) = context.source else { return }
        guard active.identity.key == MindEyePresentationKey(context: context),
              active.identity.speakerCharacterID == context.speakerCharacterID else {
            logFailureOnce(
                MindEyeFailure(
                    code: .generatedMouthSpeakerMismatch,
                    characterID: context.speakerCharacterID,
                    vignetteID: active.visual.descriptor.vignetteID,
                    resourcePath: nil,
                    message: "Generated mouth speaker does not match the active portrait."
                ),
                context: context,
                stage: "startGeneratedMouth"
            )
            return
        }
        guard active.identity.interactionSurface == context.interactionSurface else {
            logFailureOnce(
                MindEyeFailure(
                    code: .generatedMouthSurfaceMismatch,
                    characterID: context.speakerCharacterID,
                    vignetteID: active.visual.descriptor.vignetteID,
                    resourcePath: nil,
                    message: "Generated mouth surface does not match the active portrait."
                ),
                context: context,
                stage: "startGeneratedMouth"
            )
            return
        }
        guard let controller = active.visual as? any MindEyeGeneratedMouthControlling else {
            return
        }
        guard let sourceTrack = context.generatedSpeechFrameTrack else {
            controller.stopGeneratedMouthPlayback(
                reason: "generatedAnalysisUnavailable.\(reason)",
                resetToRest: true
            )
            return
        }
        let track: MindEyeGeneratedFrameTrack
        switch MindEyeGeneratedFrameTrackAdapter.adapt(sourceTrack) {
        case .failure(let failure):
            logFailureOnce(failure, context: context, stage: "adaptGeneratedTrack")
            controller.stopGeneratedMouthPlayback(
                reason: "generatedTrackInvalid",
                resetToRest: true
            )
            return
        case .success(let value): track = value
        }
        let identity = MindEyePresentationIdentity(context: context)
        let rootSeed = MindEyeMotionSeedFactory.rootSeed(
            for: identity.makeMotionSeedDescriptor(
                vignetteID: active.visual.descriptor.vignetteID
            )
        )
        let result = controller.startGeneratedMouthPlayback(
            context: MindEyeGeneratedMouthPlaybackContext(
                presentationKey: identity.key,
                segmentIndex: segmentIndex,
                track: track,
                clock: active.playbackClock,
                rootSeed: rootSeed,
                explicitTestSeed: nil
            )
        )
        if case .failure(let failure) = result {
            logFailureOnce(failure, context: context, stage: "startGeneratedMouth")
            controller.stopGeneratedMouthPlayback(
                reason: "generatedPlaybackStartFailed",
                resetToRest: true
            )
        } else {
            #if GR_MIND_EYE_QUALIFICATION
            MindEyeReleaseQualificationHooks.shared.fireAndForget(
                .generatedMouthStarted,
                playbackRunID: context.run.playbackRunID,
                mediaIdentity: context.source.mediaIdentity,
                speakerCharacterID: context.speakerCharacterID.rawValue,
                interactionSurface: context.interactionSurface.rawValue
            )
            #endif
        }
    }

    private func spokenMediaEnded(
        key: MindEyePresentationKey,
        reason: String
    ) async {
        let desiredMatches = desiredContext.map {
            MindEyePresentationKey(context: $0)
        } == key
        let activeMatches = active?.identity.key == key
        guard desiredMatches || activeMatches else {
            print(
                "[MindEyePresentation] stale end ignored run=\(key.playbackRunID) " +
                    "handle=\(key.playbackHandleID.uuidString) reason=\(reason)"
            )
            return
        }
        #if GR_MIND_EYE_QUALIFICATION
        MindEyeReleaseQualificationHooks.shared.fireAndForget(
            .speechCompleted,
            playbackRunID: key.playbackRunID
        )
        #endif
        if desiredMatches {
            desiredContext = nil
            desiredPlaybackClock = nil
            desiredIsPaused = false
            desiredIsAudible = false
            authoredTrackGeneration &+= 1
            authoredTrackTask?.cancel()
            authoredTrackTask = nil
            await releasePreparedAuthoredTrack(reason: reason)
        }
        if activeMatches,
           reason == "spokenItemCompleted",
           await settleAuthoredPortraitForGeneratedContinuity(
                key: key,
                reason: reason
           ) {
            return
        }
        if activeMatches,
           let resources = detachActiveImmediately(reason: reason) {
            await releaseDetached(resources, reason: reason)
        }
    }

    private func responseEnded(
        run: TuringSpokenPresentationRunIdentity,
        reason: String
    ) async {
        let continuityMatches = pendingGeneratedContinuity?
            .continuityID == run.continuity?.continuityID
        let desiredMatches = desiredContext?.run.playbackRunID == run.playbackRunID &&
            desiredContext?.run.flowInstanceID == run.flowInstanceID
        let activeMatches = active?.identity.key.playbackRunID == run.playbackRunID &&
            active?.identity.flowInstanceID == run.flowInstanceID
        guard desiredMatches || activeMatches || continuityMatches else { return }
        if pendingRevealRequest?.run.playbackRunID == run.playbackRunID,
           pendingRevealRequest?.run.flowInstanceID == run.flowInstanceID {
            pendingRevealRequest = nil
        }
        #if GR_MIND_EYE_QUALIFICATION
        MindEyeReleaseQualificationHooks.shared.fireAndForget(
            .speechCompleted,
            playbackRunID: run.playbackRunID
        )
        #endif
        if desiredMatches {
            desiredContext = nil
            desiredPlaybackClock = nil
            desiredIsPaused = false
            desiredIsAudible = false
            authoredTrackGeneration &+= 1
            authoredTrackTask?.cancel()
            authoredTrackTask = nil
            await releasePreparedAuthoredTrack(reason: reason)
        }
        if activeMatches,
           pendingGeneratedContinuity != nil,
           !continuityMatches,
           let activeKey = active?.identity.key,
           await settleAuthoredPortraitForGeneratedContinuity(
                key: activeKey,
                reason: reason
           ) {
            return
        }
        if continuityMatches {
            pendingGeneratedContinuity = nil
        }
        if (activeMatches || continuityMatches),
           let resources = detachActiveImmediately(reason: reason) {
            await releaseDetached(resources, reason: reason)
        }
    }

    private func settleAuthoredPortraitForGeneratedContinuity(
        key: MindEyePresentationKey,
        reason: String
    ) async -> Bool {
        guard let continuity = pendingGeneratedContinuity,
              var active,
              active.identity.key == key else {
            return false
        }
        let canReuseCurrentPortrait =
            active.identity.speakerCharacterID == continuity.speakerCharacterID &&
            active.identity.interactionSurface == continuity.interactionSurface
        (active.visual as? any MindEyeAuthoredMouthControlling)?
            .stopAuthoredMouthPlayback(
                reason: "awaitGeneratedContinuity.\(reason)",
                resetToRest: true
            )
        if let lease = active.authoredTrackLease {
            await authoredFrameStore.release(
                lease,
                reason: "awaitGeneratedContinuity.\(reason)"
            )
            active.authoredTrackLease = nil
            active.authoredPRID = nil
        }
        if canReuseCurrentPortrait {
            active.isAudible = false
            active.isPaused = false
            self.active = active
            print(
                "[MindEyePresentation] authored portrait idling for generated " +
                    "handoff authoredRun=\(key.playbackRunID) " +
                    "generatedRun=\(continuity.childPlaybackRunID) " +
                    "speaker=\(continuity.speakerCharacterID.rawValue) " +
                    "motion=keepAlive blink=enabled mouth=rest cardRebuilt=false"
            )
            return true
        }

        print(
            "[MindEyePresentation] authored portrait handing device to upcoming speaker " +
                "authoredRun=\(key.playbackRunID) " +
                "generatedRun=\(continuity.childPlaybackRunID) " +
                "outgoingSpeaker=\(active.identity.speakerCharacterID.rawValue) " +
                "upcomingSpeaker=\(continuity.speakerCharacterID.rawValue) " +
                "surface=\(continuity.interactionSurface.rawValue)"
        )
        if let resources = detachActiveImmediately(
            reason: "replaceWithUpcomingGenerated.\(reason)"
        ) {
            await releaseDetached(
                resources,
                reason: "replaceWithUpcomingGenerated.\(reason)"
            )
        }
        // detachActiveImmediately clears continuity as part of general teardown;
        // restore this still-live child handoff before scheduling its portrait.
        pendingGeneratedContinuity = continuity
        beginUpcomingGeneratedIdle(
            continuity,
            reason: "authoredCompletion.\(reason)"
        )
        return true
    }

    private func beginUpcomingGeneratedIdle(
        _ continuity: TuringSpokenPresentationContinuity,
        reason: String
    ) {
        guard lifecycleAllowsPresentation,
              applicationState == .active,
              !physicalSuppressionActive,
              pendingGeneratedContinuity?.continuityID == continuity.continuityID,
              active == nil else {
            return
        }
        let context = upcomingGeneratedPreviewContext(for: continuity)
        desiredContext = context
        desiredPlaybackClock = TuringPauseAwarePlaybackClock(
            origin: context.clockOrigin
        )
        desiredIsPaused = false
        desiredIsAudible = false
        _ = schedulePreparation(
            characterID: continuity.speakerCharacterID,
            reason: "upcomingGeneratedIdle.\(reason)"
        )
        print(
            "[MindEyePresentation] upcoming generated idle requested " +
                "run=\(continuity.childPlaybackRunID) " +
                "speaker=\(continuity.speakerCharacterID.rawValue) " +
                "surface=\(continuity.interactionSurface.rawValue) " +
                "motion=keepAlive blink=enabled mouth=rest reason=\(reason)"
        )
    }

    private func upcomingGeneratedPreviewContext(
        for continuity: TuringSpokenPresentationContinuity
    ) -> TuringSpokenPresentationContext {
        let previewIdentity = TuringFlowIdentity(
            flowInstanceID: continuity.childFlowInstanceID,
            scriptPointID: "conversation.\(continuity.childFlowInstanceID.uuidString)",
            characterID: continuity.speakerCharacterID.rawValue,
            prerecordingID: "none",
            voicePromptID: "generatedComputePreview",
            interactionSurface: continuity.interactionSurface,
            playbackRunID: continuity.childPlaybackRunID,
            spokenPresentationContinuity: continuity
        )
        let handleID = continuity.continuityID
        let route: TuringAudioRouteID
        switch continuity.interactionSurface {
        case .walkie:
            route = .storyWalkie
        case .dadFrame:
            route = .richHeadTracked
        case .crankRadio:
            route = .rollingBenchRadio
        case .hamReceiver:
            route = .hamReceiver
        }
        return TuringSpokenPresentationContext(
            run: .init(flowIdentity: previewIdentity),
            playbackHandle: TuringAudioPlaybackHandle(
                id: handleID,
                requestID: handleID,
                runID: continuity.childPlaybackRunID,
                route: route
            ),
            speakerCharacterID: continuity.speakerCharacterID,
            interactionSurface: continuity.interactionSurface,
            source: .generated(segmentIndex: 0),
            clockOrigin: .now,
            generatedSpeechFrameTrack: nil
        )
    }

    private func spokenMediaFailed(
        run: TuringSpokenPresentationRunIdentity,
        source: TuringSpokenPresentationSource?,
        message: String
    ) async {
        if case .filler = source {
            if desiredContext?.run.playbackRunID == run.playbackRunID,
               desiredContext?.run.flowInstanceID == run.flowInstanceID {
                desiredContext = nil
                desiredPlaybackClock = nil
                desiredIsPaused = false
                desiredIsAudible = false
            }
            if var active,
               active.identity.key.playbackRunID == run.playbackRunID,
               active.identity.flowInstanceID == run.flowInstanceID {
                active.isAudible = false
                (active.visual as? any MindEyeAuthoredMouthControlling)?
                    .stopAuthoredMouthPlayback(
                        reason: "fillerStartFailure",
                        resetToRest: true
                    )
                if let lease = active.fillerTrackLease {
                    await fillerFrameStore.release(lease, reason: "fillerStartFailure")
                    active.fillerTrackLease = nil
                }
                self.active = active
            }
            print(
                "[MindEyeFiller] start failed; response portrait retained message=\(message)"
            )
            return
        }
        let sourceIdentity = source?.mediaIdentity
        let desiredMatches = desiredContext?.run.playbackRunID == run.playbackRunID &&
            desiredContext?.run.flowInstanceID == run.flowInstanceID &&
            (sourceIdentity == nil || desiredContext?.source.mediaIdentity == sourceIdentity)
        let activeMatches = active?.identity.key.playbackRunID == run.playbackRunID &&
            active?.identity.flowInstanceID == run.flowInstanceID &&
            (sourceIdentity == nil || active?.identity.mediaIdentity == sourceIdentity)
        let continuityMatches = pendingGeneratedContinuity?
            .continuityID == run.continuity?.continuityID
        guard desiredMatches || activeMatches || continuityMatches else { return }
        print("[MindEyePresentation] spoken source failed run=\(run.playbackRunID) message=\(message)")
        await responseEnded(
            run: run,
            reason: "spokenFailure"
        )
    }

    private func attemptPresentDesiredContext(reason: String) async {
        guard lifecycleAllowsPresentation,
              applicationState == .active,
              !physicalSuppressionActive else { return }
        guard let context = desiredContext else { return }
        let identity = MindEyePresentationIdentity(context: context)
        guard active?.identity.key != identity.key else { return }

        if context.responsePresentationKey != nil {
            switch responsePortraitLoadDecision {
            case .allowLoad:
                break
            case .reuseExistingOnly:
                guard prepared?.characterID == identity.speakerCharacterID else { return }
            case .deny:
                return
            }
        }

        guard let prepared,
              prepared.characterID == identity.speakerCharacterID else {
            _ = schedulePreparation(
                characterID: identity.speakerCharacterID,
                reason: "desired.\(identity.mediaIdentity).\(reason)"
            )
            return
        }

        guard let initialTarget = providerRegistry.target(
            for: identity.interactionSurface
        ) else {
            logFailureOnce(
                MindEyeFailure(
                    code: .placementProviderMissing,
                    characterID: identity.speakerCharacterID,
                    vignetteID: prepared.vignetteID,
                    resourcePath: nil,
                    message: "No active placement target for \(identity.interactionSurface.rawValue)."
                ),
                context: context,
                stage: "resolvePlacementTarget"
            )
            return
        }

        let placement: MindEyeResolvedPlacement
        switch MindEyePlacementResolver.resolve(
            geometry: initialTarget.geometry,
            tuning: prepared.visual.descriptor.placementTuning
        ) {
        case .failure(let failure):
            logFailureOnce(failure, context: context, stage: "resolvePlacement")
            return
        case .success(let value):
            placement = value
        }

        guard await assetMemory.activate(
            prepared.lease,
            reason: "present.\(identity.mediaIdentity)"
        ) else {
            await discardPrepared(reason: "activationRejected")
            _ = schedulePreparation(
                characterID: identity.speakerCharacterID,
                reason: "activationRejected.\(reason)"
            )
            return
        }

        guard let currentDesired = desiredContext,
              MindEyePresentationKey(context: currentDesired) == identity.key,
              self.prepared?.lease == prepared.lease else {
            await assetMemory.deactivate(
                prepared.lease,
                reason: "presentationBecameStale"
            )
            return
        }

        guard let currentTarget = providerRegistry.target(
            for: identity.interactionSurface
        ),
              currentTarget.providerID == initialTarget.providerID,
              currentTarget.revision == initialTarget.revision else {
            await assetMemory.deactivate(
                prepared.lease,
                reason: "placementTargetBecameStale"
            )
            return
        }

        #if GR_MIND_EYE_QUALIFICATION
        MindEyeReleaseQualificationHooks.shared.fireAndForget(
            .beforeVisualAttach,
            playbackRunID: context.run.playbackRunID,
            mediaIdentity: context.source.mediaIdentity,
            speakerCharacterID: context.speakerCharacterID.rawValue,
            interactionSurface: context.interactionSurface.rawValue
        )
        #endif
        switch prepared.visual.attach(to: currentTarget, placement: placement) {
        case .failure(let failure):
            await assetMemory.deactivate(prepared.lease, reason: "visualAttachFailed")
            logFailureOnce(failure, context: context, stage: "attach")
        case .success:
            let playbackClock = desiredPlaybackClock ??
                TuringPauseAwarePlaybackClock(origin: context.clockOrigin)
            active = ActivePresentation(
                identity: identity,
                source: context.source,
                responseKey: context.responsePresentationKey,
                lease: prepared.lease,
                visual: prepared.visual,
                providerID: currentTarget.providerID,
                providerRevision: currentTarget.revision,
                isAudible: desiredIsAudible,
                isPaused: desiredIsPaused,
                playbackClock: playbackClock,
                authoredTrackLease: nil,
                authoredPRID: nil,
                fillerTrackLease: nil
            )
            // Ownership transfers to `active`; retaining the same lease as
            // `prepared` would leave a disposed visual eligible for reuse on
            // the second playback run.
            self.prepared = nil
            #if GR_MIND_EYE_QUALIFICATION
            MindEyeReleaseQualificationHooks.shared.fireAndForget(
                .afterVisualAttach,
                playbackRunID: context.run.playbackRunID,
                mediaIdentity: context.source.mediaIdentity,
                speakerCharacterID: context.speakerCharacterID.rawValue,
                interactionSurface: context.interactionSurface.rawValue,
                timing: MindEyeReleaseTimingSnapshot(
                    visualReadyAfterActualStartMilliseconds: Double(
                        MindEyeDurationNanoseconds.clampedUInt64(
                            context.clockOrigin.duration(to: .now)
                        )
                    ) / 1_000_000
                )
            )
            #endif
            let keepAlive = prepared.visual.startKeepAlive(
                context: MindEyeKeepAliveContext(
                    seedDescriptor: identity.makeMotionSeedDescriptor(
                        vignetteID: prepared.visual.descriptor.vignetteID
                    )
                )
            )
            if case .failure(let failure) = keepAlive {
                logFailureOnce(
                    failure,
                    context: context,
                    stage: "startKeepAlive"
                )
            }
            // A visual that finishes preparing while its audio is paused must
            // still idle and blink. The paused playback clock installed below
            // keeps its mouth track stationary without suspending keep-alive.
            if pendingRevealRequest == nil {
                await installMatchingPreparedAuthoredTrackIfAvailable(
                    reason: "visualAttached"
                )
                if let installed = self.active {
                    startGeneratedMouthIfAvailable(
                        context: context,
                        active: installed,
                        reason: "visualAttached"
                    )
                }
                if case .filler(let identity) = context.source,
                   let clip = await resolveFillerDescriptor(identity: identity) {
                    await acquireAndInstallFillerTrack(
                        clip: clip,
                        context: context,
                        reason: "visualAttached"
                    )
                }
            }
            let speakerDescription = identity.speakerCharacterID.rawValue
            let surfaceDescription = identity.interactionSurface.rawValue
            let positionDescription = String(describing: placement.localPosition)
            let message = "[MindEyePresentation] dynamic card shown " +
                "speaker=\(speakerDescription) vignette=\(prepared.vignetteID) " +
                "surface=\(surfaceDescription) media=\(identity.mediaIdentity) " +
                "provider=\(currentTarget.providerID) revision=\(currentTarget.revision) " +
                "localPosition=\(positionDescription) followsHeadset=false " +
                    "artistRGBMask=true straightAlphaOutput=true"
            print(message)
        }
    }

    @discardableResult
    private func schedulePreparation(
        characterID: TuringConversationCharacterID,
        reason: String
    ) -> Task<Void, Never>? {
        guard lifecycleAllowsPresentation,
              applicationState == .active,
              !physicalSuppressionActive else { return nil }
        if prepared?.characterID == characterID {
            Task { @MainActor [weak self] in
                await self?.attemptPresentDesiredContext(
                    reason: "preparedAlreadyAvailable"
                )
            }
            return nil
        }
        if preparingCharacterID == characterID,
           let preparationTask {
            return preparationTask
        }

        preparationTask?.cancel()
        buildGeneration &+= 1
        let token = buildGeneration
        preparingCharacterID = characterID
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareVisual(
                characterID: characterID,
                token: token,
                reason: reason
            )
        }
        preparationTask = task
        return task
    }

    private func prepareVisual(
        characterID: TuringConversationCharacterID,
        token: UInt64,
        reason: String
    ) async {
        defer {
            if buildGeneration == token {
                preparationTask = nil
                preparingCharacterID = nil
            }
        }
        if prepared?.characterID == characterID {
            await attemptPresentDesiredContext(reason: "preparationAlreadyComplete")
            return
        }
        if let active,
           active.identity.speakerCharacterID != characterID {
            return
        }
        if prepared != nil, active == nil {
            await releasePrepared(reason: "replacePrepared.\(characterID.rawValue)")
        }
        guard !Task.isCancelled, buildGeneration == token else { return }

        #if GR_MIND_EYE_QUALIFICATION
        MindEyeReleaseQualificationHooks.shared.fireAndForget(
            .beforePackagePrewarm,
            speakerCharacterID: characterID.rawValue,
            notes: [reason]
        )
        #endif
        let acquisition = await assetMemory.prewarm(
            characterID: characterID,
            reason: "phase4.\(reason)"
        )
        guard !Task.isCancelled, buildGeneration == token else {
            if case .ready(let lease) = acquisition {
                await assetMemory.release(lease, reason: "stalePreparationAcquisition")
            }
            return
        }

        let lease: MindEyeAssetLease
        switch acquisition {
        case .unavailable(let failure):
            logFailureOnce(
                failure,
                context: desiredContext?.speakerCharacterID == characterID
                    ? desiredContext : nil,
                stage: "prewarm"
            )
            return
        case .ready(let value):
            lease = value
        }

        guard await assetMemory.activate(lease, reason: "buildDynamicVisual") else {
            await assetMemory.release(lease, reason: "buildActivationRejected")
            return
        }
        guard let package = await assetMemory.package(forActive: lease) else {
            await assetMemory.deactivate(lease, reason: "buildMissingActivePackage")
            await assetMemory.release(lease, reason: "buildMissingActivePackage")
            return
        }
        let visualResult = await visualBuilder.build(package: package)
        await assetMemory.deactivate(lease, reason: "dynamicVisualPrepared")

        guard !Task.isCancelled, buildGeneration == token else {
            if case .success(let visual) = visualResult {
                visual.dispose(reason: "staleVisualBuild")
            }
            await assetMemory.release(lease, reason: "staleVisualBuild")
            return
        }

        switch visualResult {
        case .failure(let failure):
            await assetMemory.release(lease, reason: "dynamicVisualBuildFailed")
            logFailureOnce(
                failure,
                context: desiredContext?.speakerCharacterID == characterID
                    ? desiredContext : nil,
                stage: "buildDynamicVisual"
            )
        case .success(let visual):
            prepared = PreparedVisual(
                generation: token,
                characterID: characterID,
                vignetteID: visual.descriptor.vignetteID,
                lease: lease,
                visual: visual
            )
            #if GR_MIND_EYE_QUALIFICATION
            MindEyeReleaseQualificationHooks.shared.fireAndForget(
                .afterPackagePrewarm,
                speakerCharacterID: characterID.rawValue,
                notes: [reason]
            )
            #endif
            print(
                "[MindEyePresentation] dynamic visual prepared speaker=" +
                    "\(characterID.rawValue) vignette=" +
                    "\(visual.descriptor.vignetteID) reason=\(reason)"
            )
            await attemptPresentDesiredContext(reason: "lateJoinAfterPreparation")
        }
    }

    private func discardPrepared(reason: String) async {
        guard let prepared,
              active?.lease != prepared.lease else { return }
        self.prepared = nil
        prepared.visual.dispose(reason: reason)
        await assetMemory.release(prepared.lease, reason: reason)
    }

    private func releasePrepared(reason: String) async {
        await discardPrepared(reason: reason)
    }

    private func handleAuthoredPreparationHint(
        _ hint: TuringAuthoredPresentationPreparationHint
    ) async {
        guard lifecycleAllowsPresentation,
              applicationState == .active,
              !physicalSuppressionActive else { return }
        let visualTask = schedulePreparation(
            characterID: hint.speakerCharacterID,
            reason: "authoredHint.\(hint.key)"
        )
        let result = await authoredFrameStore.prewarm(
            prID: hint.prerecordingID,
            expectedSpeaker: hint.speakerCharacterID,
            expectedSurface: hint.interactionSurface,
            reason: "turingHint.\(hint.key)"
        )
        if case .failure(let failure) = result {
            logFailureOnce(failure, context: nil, stage: "authoredTrackPrewarm")
        }
        await visualTask?.value
    }

    private func handleRevealRequest(
        _ request: TuringSpokenPresentationRevealRequest
    ) async {
        guard lifecycleAllowsPresentation,
              applicationState == .active,
              !physicalSuppressionActive else {
            await resolveReveal(request, outcome: .audioOnly)
            return
        }

        let previewContext = request.previewContext()
        guard case .eligible = eligibility.decision(for: previewContext) else {
            await resolveReveal(request, outcome: .audioOnly)
            return
        }

        // A pre-audio reveal never owns the one card over media that is
        // already audible. This check precedes continuity promotion because
        // promotion also changes the active source and stops its mouth track.
        // Selecting the new device and starting its compute remain independent;
        // its portrait can join at actual audio start after this PR completes.
        if let active, active.isAudible {
            print(
                "[MindEyePresentation] pre-audio reveal deferred; audible owner retained " +
                    "activeRun=\(active.identity.key.playbackRunID) " +
                    "activeMedia=\(active.identity.mediaIdentity) " +
                    "requestedRun=\(request.run.playbackRunID) " +
                    "requestedMedia=\(request.source.mediaIdentity) " +
                    "requestedSurface=\(request.interactionSurface.rawValue) " +
                    "deviceSelectionContinues=true computeContinues=true"
            )
            await resolveReveal(request, outcome: .audioOnly)
            return
        }

        if canPromoteGeneratedContinuity(to: previewContext) {
            await promoteGeneratedContinuity(to: previewContext)
            pendingRevealRequest = request
            await scheduleFillerTrackPrewarm(for: request)
            await resolveReveal(request, outcome: .alreadyVisible)
            return
        }

        if let active,
           portraitMatches(active.identity, request: request) {
            pendingRevealRequest = request
            await scheduleFillerTrackPrewarm(for: request)
            await resolveReveal(request, outcome: .alreadyVisible)
            return
        }

        switch responsePortraitLoadDecision {
        case .allowLoad:
            break
        case .reuseExistingOnly:
            guard prepared?.characterID == request.speakerCharacterID else {
                await resolveReveal(request, outcome: .audioOnly)
                return
            }
        case .deny:
            await resolveReveal(request, outcome: .audioOnly)
            return
        }

        authoredTrackGeneration &+= 1
        authoredTrackTask?.cancel()
        authoredTrackTask = nil
        await releasePreparedAuthoredTrack(reason: "preAudioRevealReplacement")
        if let resources = detachActiveImmediately(reason: "preAudioRevealReplacement") {
            await releaseDetached(resources, reason: "preAudioRevealReplacement")
        }

        pendingRevealRequest = request
        desiredContext = previewContext
        desiredPlaybackClock = TuringPauseAwarePlaybackClock(
            origin: previewContext.clockOrigin
        )
        desiredIsPaused = false
        desiredIsAudible = false
        let preparation = schedulePreparation(
            characterID: request.speakerCharacterID,
            reason: "preAudioReveal.\(request.key)"
        )
        await scheduleFillerTrackPrewarm(for: request)
        await preparation?.value

        guard pendingRevealRequest?.id == request.id,
              desiredContext.map(Self.revealKey(for:)) == request.key else {
            await resolveReveal(request, outcome: .audioOnly)
            return
        }
        await attemptPresentDesiredContext(reason: "preAudioReveal")
        guard let active,
              portraitMatches(active.identity, request: request) else {
            pendingRevealRequest = nil
            desiredContext = nil
            desiredPlaybackClock = nil
            desiredIsAudible = false
            await resolveReveal(request, outcome: .audioOnly)
            return
        }
        await resolveReveal(request, outcome: .revealed)
        print(
            "[MindEyePresentation] idle portrait revealed before audio " +
                "media=\(request.source.mediaIdentity) motion=keepAlive mouth=rest"
        )
    }

    private func resolveReveal(
        _ request: TuringSpokenPresentationRevealRequest,
        outcome: TuringSpokenPresentationRevealOutcome
    ) async {
        await TuringSpokenPresentationRevealHub.shared.resolve(
            requestID: request.id,
            outcome: outcome
        )
    }

    private func scheduleFillerTrackPrewarm(
        for request: TuringSpokenPresentationRevealRequest
    ) async {
        fillerTrackPreparationTask?.cancel()
        guard case .filler(let identity) = request.source,
              let clip = await resolveFillerDescriptor(identity: identity) else {
            fillerTrackPreparationTask = nil
            return
        }
        let store = fillerFrameStore
        let surface = request.interactionSurface
        fillerTrackPreparationTask = Task {
            await store.prewarm(
                clip: clip,
                expectedSurface: surface,
                reason: "preAudioReveal.\(request.key)"
            )
        }
    }

    private func portraitMatches(
        _ identity: MindEyePresentationIdentity,
        request: TuringSpokenPresentationRevealRequest
    ) -> Bool {
        identity.key.playbackRunID == request.run.playbackRunID &&
            identity.flowInstanceID == request.run.flowInstanceID &&
            identity.speakerCharacterID == request.speakerCharacterID &&
            identity.interactionSurface == request.interactionSurface
    }

    private static func revealKey(
        for context: TuringSpokenPresentationContext
    ) -> String {
        [
            context.run.playbackRunID,
            context.run.flowInstanceID.uuidString.lowercased(),
            context.source.mediaIdentity
        ].joined(separator: "|")
    }

    private func scheduleAuthoredTrackAcquisition(
        context: TuringSpokenPresentationContext,
        clock: TuringPauseAwarePlaybackClock,
        prID: String
    ) {
        authoredTrackTask?.cancel()
        authoredTrackGeneration &+= 1
        let generation = authoredTrackGeneration
        let key = MindEyePresentationKey(context: context)
        authoredTrackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let acquisition = await authoredFrameStore.acquire(
                prID: prID,
                expectedSpeaker: context.speakerCharacterID,
                expectedSurface: context.interactionSurface,
                reason: "actualStart.\(context.source.mediaIdentity)"
            )
            guard !Task.isCancelled,
                  authoredTrackGeneration == generation else {
                if case .ready(let lease, _) = acquisition {
                    await authoredFrameStore.release(
                        lease,
                        reason: "staleAuthoredTrackAcquisition"
                    )
                }
                return
            }
            await handleAuthoredTrackAcquisition(
                acquisition,
                generation: generation,
                key: key,
                initialClock: clock
            )
        }
    }

    private func handleAuthoredTrackAcquisition(
        _ acquisition: MindEyeAuthoredFrameTrackAcquisition,
        generation: UInt64,
        key: MindEyePresentationKey,
        initialClock: TuringPauseAwarePlaybackClock
    ) async {
        switch acquisition {
        case .unavailable(let failure):
            let matchingContext = desiredContext.flatMap {
                MindEyePresentationKey(context: $0) == key ? $0 : nil
            }
            logFailureOnce(failure, context: matchingContext, stage: "acquireAuthoredTrack")
        case .ready(let lease, let track):
            let desiredMatches = desiredContext.map {
                MindEyePresentationKey(context: $0)
            } == key
            let activeMatches = active?.identity.key == key
            guard desiredMatches || activeMatches else {
                await authoredFrameStore.release(
                    lease,
                    reason: "authoredTrackNoLongerDesired"
                )
                return
            }
            let preparedTrack = PreparedAuthoredTrack(
                generation: generation,
                presentationKey: key,
                lease: lease,
                track: track
            )
            if activeMatches {
                await installAuthoredTrack(
                    preparedTrack,
                    initialClock: active?.playbackClock ?? initialClock,
                    reason: "lateTrackJoin"
                )
            } else {
                await releasePreparedAuthoredTrack(reason: "replacePreparedAuthoredTrack")
                preparedAuthoredTrack = preparedTrack
            }
        }
    }

    private func installMatchingPreparedAuthoredTrackIfAvailable(
        reason: String
    ) async {
        guard let active,
              let prepared = preparedAuthoredTrack,
              prepared.presentationKey == active.identity.key else { return }
        await installAuthoredTrack(
            prepared,
            initialClock: active.playbackClock,
            reason: reason
        )
    }

    private func installAuthoredTrack(
        _ prepared: PreparedAuthoredTrack,
        initialClock: TuringPauseAwarePlaybackClock,
        reason: String
    ) async {
        guard var active,
              active.identity.key == prepared.presentationKey else {
            await authoredFrameStore.release(
                prepared.lease,
                reason: "installAuthoredTrackStale"
            )
            if preparedAuthoredTrack?.lease == prepared.lease {
                preparedAuthoredTrack = nil
            }
            return
        }
        guard case .authored(let expectedPRID, _) = active.source,
              expectedPRID == prepared.track.descriptor.prID else {
            await authoredFrameStore.release(
                prepared.lease,
                reason: "installAuthoredTrackSourceMismatch"
            )
            if preparedAuthoredTrack?.lease == prepared.lease {
                preparedAuthoredTrack = nil
            }
            return
        }
        guard let visual = active.visual as? any MindEyeAuthoredMouthControlling else {
            await authoredFrameStore.release(
                prepared.lease,
                reason: "visualDoesNotSupportAuthoredMouth"
            )
            if preparedAuthoredTrack?.lease == prepared.lease {
                preparedAuthoredTrack = nil
            }
            return
        }

        let rootSeed = MindEyeMotionSeedFactory.rootSeed(
            for: active.identity.makeMotionSeedDescriptor(
                vignetteID: active.visual.descriptor.vignetteID
            )
        )
        let currentClock = active.playbackClock
        let result = visual.startAuthoredMouthPlayback(
            context: MindEyeAuthoredMouthPlaybackContext(
                presentationKey: active.identity.key,
                track: prepared.track,
                clock: currentClock,
                rootSeed: rootSeed,
                explicitTestSeed: nil
            )
        )
        switch result {
        case .failure(let failure):
            await authoredFrameStore.release(
                prepared.lease,
                reason: "authoredPlaybackStartFailed"
            )
            if preparedAuthoredTrack?.lease == prepared.lease {
                preparedAuthoredTrack = nil
            }
            logFailureOnce(
                failure,
                context: desiredContext,
                stage: "startAuthoredMouthPlayback"
            )
        case .success:
            if let oldLease = active.authoredTrackLease,
               oldLease != prepared.lease {
                await authoredFrameStore.release(
                    oldLease,
                    reason: "replaceActiveAuthoredTrack"
                )
            }
            active.authoredTrackLease = prepared.lease
            active.authoredPRID = prepared.track.descriptor.prID
            self.active = active
            #if GR_MIND_EYE_QUALIFICATION
            MindEyeReleaseQualificationHooks.shared.fireAndForget(
                .authoredMouthStarted,
                playbackRunID: active.identity.key.playbackRunID,
                mediaIdentity: active.identity.mediaIdentity,
                speakerCharacterID: active.identity.speakerCharacterID.rawValue,
                interactionSurface: active.identity.interactionSurface.rawValue
            )
            #endif
            if preparedAuthoredTrack?.lease == prepared.lease {
                preparedAuthoredTrack = nil
            }
            print(
                "[MindEyeAuthored] installed prID=\(prepared.track.descriptor.prID) " +
                    "reason=\(reason) initialClockPaused=\(initialClock.isPaused)"
            )
        }
    }

    private func releasePreparedAuthoredTrack(reason: String) async {
        guard let prepared = preparedAuthoredTrack else { return }
        preparedAuthoredTrack = nil
        await authoredFrameStore.release(prepared.lease, reason: reason)
    }

    private func detachActiveImmediately(reason: String) -> DetachedMindEyeResources? {
        guard let active else { return nil }
        pendingGeneratedContinuity = nil
        (active.visual as? any MindEyeAuthoredMouthControlling)?
            .stopAuthoredMouthPlayback(reason: reason, resetToRest: false)
        (active.visual as? any MindEyeGeneratedMouthControlling)?
            .stopGeneratedMouthPlayback(reason: reason, resetToRest: false)
        active.visual.stopKeepAlive(reason: reason)
        active.visual.detach(reason: reason)
        self.active = nil
        return DetachedMindEyeResources(
            assetLease: active.lease,
            authoredTrackLease: active.authoredTrackLease,
            fillerTrackLease: active.fillerTrackLease,
            visual: active.visual
        )
    }

    private func releaseDetached(
        _ resources: DetachedMindEyeResources,
        reason: String
    ) async {
        resources.visual.dispose(reason: reason)
        await assetMemory.deactivate(resources.assetLease, reason: reason)
        await assetMemory.release(resources.assetLease, reason: reason)
        if let lease = resources.authoredTrackLease {
            await authoredFrameStore.release(lease, reason: reason)
        }
        if let lease = resources.fillerTrackLease {
            await fillerFrameStore.release(lease, reason: reason)
        }
        #if GR_MIND_EYE_QUALIFICATION
        MindEyeReleaseQualificationHooks.shared.visualReleased()
        #endif
    }

    func currentTeardownReport(
        scope: MindEyeTeardownScope,
        reason: String
    ) async -> MindEyeTeardownReport {
        await makeTeardownReport(
            scope: scope,
            reason: reason,
            activeVisualRemoved: false,
            preparedVisualRemoved: false,
            activeAuthoredTrackReleased: false,
            preparedAuthoredTrackReleased: false
        )
    }

    func runtimeSnapshot(
        applicationState: MindEyeApplicationLifecycleState,
        memoryPressure: MindEyeMemoryPressureLevel,
        allowsNewPresentation: Bool
    ) async -> MindEyeRuntimeSnapshot {
        let asset = await assetMemory.snapshot()
        let tracks = await authoredFrameStore.snapshot()
        return MindEyeRuntimeSnapshot(
            applicationState: applicationState,
            memoryPressure: memoryPressure,
            physicalSuppressionActive: physicalSuppressionActive,
            lifecycleGeneration: lifecycleGeneration,
            allowsNewPresentation: allowsNewPresentation && !physicalSuppressionActive,
            activePresentation: active?.identity,
            desiredMediaIdentity: desiredContext?.source.mediaIdentity,
            preparedVignetteID: prepared?.vignetteID,
            preparedAuthoredPRID: preparedAuthoredTrack?.track.descriptor.prID,
            motionRegistryEntries: MindEyeMotionFrameRegistry.shared.entryCount,
            authoredRegistryEntries: MindEyeAuthoredFramePlaybackRegistry.shared.entryCount,
            generatedRegistryEntries: MindEyeGeneratedFramePlaybackRegistry.shared.entryCount,
            assetMemorySnapshot: asset,
            authoredStoreSnapshot: tracks
        )
    }

    func releaseResourceSnapshot() async -> MindEyeReleaseResourceSnapshot {
        let process = TuringMemoryBudgetProbe.snapshot()
        let asset = await assetMemory.snapshot()
        let tracks = await authoredFrameStore.snapshot()
        let visual = active?.visual.releaseResourceSnapshot() ??
            prepared?.visual.releaseResourceSnapshot() ?? .empty
        let activePackages = asset.activeLeaseCount > 0 ? 1 : 0
        let inactivePackages = max(0, asset.uniqueResidentPackageCount - activePackages)
        return MindEyeReleaseResourceSnapshot(
            process: process,
            vignetteID: active?.lease.vignetteID ?? prepared?.vignetteID ?? asset.residentVignetteID,
            sourceTextureCount: asset.residentSourceTextureCount,
            sourceTextureAllocatedBytes: asset.residentSourceTextureAllocatedBytes,
            outputTextureCount: visual.outputTextureCount,
            outputTextureAllocatedBytes: visual.outputTextureAllocatedBytes,
            activeAssetPackageCount: activePackages,
            inactiveAssetPackageCount: inactivePackages,
            cachedAuthoredTrackCount: tracks.cachedPRIDs.count,
            activeAuthoredTrackLeaseCount: tracks.leasedPRIDs.count,
            motionRegistryCount: MindEyeMotionFrameRegistry.shared.entryCount,
            authoredRegistryCount: MindEyeAuthoredFramePlaybackRegistry.shared.entryCount,
            generatedRegistryCount: MindEyeGeneratedFramePlaybackRegistry.shared.entryCount,
            activeCardCount: visual.activeCardCount,
            orphanCardCount: visual.orphanCardCount,
            compositorInFlightCount: visual.compositorInFlightCount,
            compositorPendingFrameCount: visual.compositorPendingFrameCount,
            cropClampCount: visual.cropClampCount,
            coalescedFrameCount: visual.coalescedFrameCount,
            authoredCompactFrameBytes: max(
                visual.authoredCompactFrameBytes,
                tracks.estimatedCompactBytes
            ),
            generatedCompactFrameBytes: visual.generatedCompactFrameBytes
        )
    }

    private func applyPhysicalPresence(
        _ snapshot: MindEyePhysicalCharacterPresenceSnapshot
    ) async {
        physicalPresenceSnapshot = snapshot
        let shouldSuppress = snapshot.suppressesAllPresentations
        if shouldSuppress && !physicalSuppressionActive {
            physicalSuppressionActive = true
            await releaseForPhysicalSuppression(
                reason: "physicalPresence.generation\(snapshot.generation)"
            )
        } else if !shouldSuppress && physicalSuppressionActive {
            physicalSuppressionActive = false
            print(
                "[MindEyePresentation] physical suppression cleared " +
                    "generation=\(snapshot.generation) policy=freshActualStartRequired"
            )
        }
    }

    private func releaseForPhysicalSuppression(reason: String) async {
        TuringMemoryBudgetProbe.log(
            label: "mindEye.physicalSuppression.before",
            details: ["reason": reason]
        )
        _ = await releaseAllPresentationState(
            scope: .physicalSuppression,
            reason: reason,
            keepEventSubscriptions: true
        )
        _ = await assetMemory.evictInactive(reason: "physicalSuppression.\(reason)")
        await authoredFrameStore.evictInactive(reason: "physicalSuppression.\(reason)")
        await fillerFrameStore.evictInactive(reason: "physicalSuppression.\(reason)")
        TuringMemoryBudgetProbe.log(
            label: "mindEye.physicalSuppression.after",
            details: ["reason": reason]
        )
    }

    private func makeTeardownReport(
        scope: MindEyeTeardownScope,
        reason: String,
        activeVisualRemoved: Bool,
        preparedVisualRemoved: Bool,
        activeAuthoredTrackReleased: Bool,
        preparedAuthoredTrackReleased: Bool
    ) async -> MindEyeTeardownReport {
        let asset = await assetMemory.snapshot()
        let tracks = await authoredFrameStore.snapshot()
        return MindEyeTeardownReport(
            scope: scope,
            reason: reason,
            lifecycleGeneration: lifecycleGeneration,
            activeVisualRemoved: activeVisualRemoved,
            preparedVisualRemoved: preparedVisualRemoved,
            activeAuthoredTrackReleased: activeAuthoredTrackReleased,
            preparedAuthoredTrackReleased: preparedAuthoredTrackReleased,
            motionRegistryEntries: MindEyeMotionFrameRegistry.shared.entryCount,
            authoredRegistryEntries: MindEyeAuthoredFramePlaybackRegistry.shared.entryCount,
            generatedRegistryEntries: MindEyeGeneratedFramePlaybackRegistry.shared.entryCount,
            cachedAssetPackages: asset.uniqueResidentPackageCount,
            cachedAuthoredTracks: tracks.cachedPRIDs.count,
            providerCount: providerRegistry.providerCount,
            desiredContextPresent: desiredContext != nil,
            preparationTaskPresent: preparationTask != nil,
            authoredTrackTaskPresent: authoredTrackTask != nil
        )
    }

    private func logFailureOnce(
        _ failure: MindEyeFailure,
        context: TuringSpokenPresentationContext?,
        stage: String
    ) {
        let key = [
            stage,
            failure.code.rawValue,
            context?.run.playbackRunID ?? "noRun",
            context?.source.mediaIdentity ?? "noMedia",
            failure.vignetteID ?? "noVignette",
            failure.resourcePath ?? "noResource"
        ].joined(separator: "|")
        guard loggedFailureKeys.insert(key).inserted else { return }
        print(
            "[MindEyePresentation] visual unavailable stage=\(stage) " +
                "code=\(failure.code.rawValue) speaker=" +
                "\(context?.speakerCharacterID.rawValue ?? failure.characterID?.rawValue ?? "unknown") " +
                "message=\(failure.message) fallback=audioOnly"
        )
    }
}
