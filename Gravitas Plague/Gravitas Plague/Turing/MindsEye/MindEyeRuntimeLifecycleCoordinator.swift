import Foundation

@MainActor
final class MindEyeRuntimeLifecycleCoordinator: MindEyeHighMemoryPreparing {
    private let presentation: MindEyePresentationCoordinator
    private let assetMemory: any MindEyeAssetMemoryManaging
    private let authoredFrameStore: any MindEyeAuthoredFrameTrackManaging
    private let memoryPressureSource: any MindEyeMemoryPressureStreaming
    private let physicalPresenceHub: MindEyePhysicalCharacterPresenceHub

    private var memoryPressureTask: Task<Void, Never>?
    private(set) var applicationState: MindEyeApplicationLifecycleState = .active
    private(set) var memoryPressure: MindEyeMemoryPressureLevel = .normal
    private var lifecycleGeneration: UInt64 = 0
    private var started = false
    private var shutdownComplete = false

    var allowsNewPresentation: Bool {
        applicationState == .active && !shutdownComplete
    }

    init(
        presentation: MindEyePresentationCoordinator,
        assetMemory: any MindEyeAssetMemoryManaging = MindEyeAssetMemoryManager.shared,
        authoredFrameStore: any MindEyeAuthoredFrameTrackManaging =
            MindEyeAuthoredFrameTrackStore.shared,
        memoryPressureSource: any MindEyeMemoryPressureStreaming =
            MindEyeDispatchMemoryPressureSource(),
        physicalPresenceHub: MindEyePhysicalCharacterPresenceHub = .shared
    ) {
        self.presentation = presentation
        self.assetMemory = assetMemory
        self.authoredFrameStore = authoredFrameStore
        self.memoryPressureSource = memoryPressureSource
        self.physicalPresenceHub = physicalPresenceHub
    }

    func start() {
        guard !started, !shutdownComplete else { return }
        started = true
        presentation.start()
        presentation.setApplicationState(applicationState, reason: "lifecycleStart")
        presentation.setLifecycleAllowsPresentation(
            allowsNewPresentation,
            reason: "lifecycleStart"
        )
        presentation.setResponsePortraitLoadDecision(
            .allowLoad,
            reason: "lifecycleStart"
        )
        memoryPressureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await memoryPressureSource.start()
            let stream = await memoryPressureSource.events()
            for await level in stream {
                guard !Task.isCancelled else { return }
                await handleMemoryPressure(level)
            }
        }
    }

    func applicationStateChanged(
        to newState: MindEyeApplicationLifecycleState,
        reason: String
    ) async {
        guard !shutdownComplete, applicationState != newState else { return }
        let previous = applicationState
        applicationState = newState
        lifecycleGeneration &+= 1
        presentation.setApplicationState(newState, reason: reason)

        switch newState {
        case .active:
            presentation.setResponsePortraitLoadDecision(
                memoryPressure == .warning ? .reuseExistingOnly : .allowLoad,
                reason: "applicationActive.\(reason)"
            )
            presentation.setLifecycleAllowsPresentation(
                true,
                reason: "applicationActive.\(reason)"
            )
            if previous == .inactive {
                await presentation.resumeAfterApplicationInactive(
                    at: ContinuousClock.now,
                    reason: reason
                )
            }
        case .inactive:
            TuringMemoryBudgetProbe.log(label: "mindEye.lifecycle.inactive.before")
            presentation.setLifecycleAllowsPresentation(
                false,
                reason: "applicationInactive.\(reason)"
            )
            presentation.setResponsePortraitLoadDecision(
                .deny,
                reason: "applicationInactive.\(reason)"
            )
            await presentation.suspendForApplicationInactive(reason: reason)
            await presentation.releasePreparedAndEvictInactive(
                reason: "applicationInactive.\(reason)"
            )
            TuringMemoryBudgetProbe.log(label: "mindEye.lifecycle.inactive.after")
        case .background:
            TuringMemoryBudgetProbe.log(label: "mindEye.lifecycle.background.before")
            await TuringGeneratedSpeechAnalysisCoordinator.shared.cancelAll(
                reason: "applicationBackground.\(reason)"
            )
            presentation.setLifecycleAllowsPresentation(
                false,
                reason: "applicationBackground.\(reason)"
            )
            presentation.setResponsePortraitLoadDecision(
                .deny,
                reason: "applicationBackground.\(reason)"
            )
            _ = await presentation.releaseAllPresentationState(
                scope: .applicationBackground,
                reason: reason,
                keepEventSubscriptions: true
            )
            await assetMemory.forceEvictAll(reason: "applicationBackground.\(reason)")
            await authoredFrameStore.forceEvictAll(reason: "applicationBackground.\(reason)")
            clearRegistriesAfterTeardown(reason: "applicationBackground.\(reason)")
            TuringMemoryBudgetProbe.log(label: "mindEye.lifecycle.background.after")
        }
    }

    func resetForStoryBoundary(
        scope: MindEyeTeardownScope,
        reason: String
    ) async -> MindEyeTeardownReport {
        guard !shutdownComplete else {
            return await presentation.currentTeardownReport(
                scope: scope,
                reason: "alreadyShutdown.\(reason)"
            )
        }
        lifecycleGeneration &+= 1
        await TuringGeneratedSpeechAnalysisCoordinator.shared.cancelAll(
            reason: "\(scope.rawValue).\(reason)"
        )
        presentation.setLifecycleAllowsPresentation(false, reason: "\(scope.rawValue).\(reason)")
        let report = await presentation.releaseAllPresentationState(
            scope: scope,
            reason: reason,
            keepEventSubscriptions: true
        )
        _ = await assetMemory.evictInactive(reason: "\(scope.rawValue).\(reason)")
        await authoredFrameStore.evictInactive(reason: "\(scope.rawValue).\(reason)")
        if allowsNewPresentation {
            presentation.setLifecycleAllowsPresentation(
                true,
                reason: "\(scope.rawValue).complete"
            )
        }
        return report
    }

    func prepareForTuringHighMemoryRun(
        runID: String,
        policy: MindEyeActiveHighMemoryRetentionPolicy = .retainMatchingRunActive,
        continuity: TuringSpokenPresentationContinuity? = nil
    ) async -> MindEyeHighMemoryPreparationReport {
        #if GR_MIND_EYE_QUALIFICATION
        MindEyeReleaseQualificationHooks.shared.fireAndForget(
            .qwenPreflightBefore,
            playbackRunID: runID
        )
        #endif
        TuringMemoryBudgetProbe.log(label: "mindEye.qwenPreflight.before", runID: runID)
        // An active authored PR is audible media, not an inactive cache. A
        // system memory warning is diagnostic evidence for Turing; it must not
        // convert this visual policy into a destructive release.
        let effectivePolicy = policy
        let report = await presentation.prepareForTuringHighMemoryRun(
            runID: runID,
            policy: effectivePolicy,
            continuity: continuity
        )
        _ = await assetMemory.evictInactive(reason: "qwenPreflight.\(runID)")
        await authoredFrameStore.evictInactive(reason: "qwenPreflight.\(runID)")
        TuringMemoryBudgetProbe.log(
            label: "mindEye.qwenPreflight.after",
            runID: runID,
            details: [
                "activeRetained": String(report.activePresentationRetained),
                "assetCacheAfter": String(report.assetCacheAfter),
                "authoredTrackCacheAfter": String(report.authoredTrackCacheAfter)
            ]
        )
        #if GR_MIND_EYE_QUALIFICATION
        MindEyeReleaseQualificationHooks.shared.fireAndForget(
            .qwenPreflightAfter,
            playbackRunID: runID,
            notes: [
                "activeRetained=\(report.activePresentationRetained)",
                "assetCacheAfter=\(report.assetCacheAfter)",
                "authoredTrackCacheAfter=\(report.authoredTrackCacheAfter)"
            ]
        )
        #endif
        return report
    }

    func runtimeSnapshot() async -> MindEyeRuntimeSnapshot {
        await presentation.runtimeSnapshot(
            applicationState: applicationState,
            memoryPressure: memoryPressure,
            allowsNewPresentation: allowsNewPresentation
        )
    }

    func shutdown(reason: String) async -> MindEyeTeardownReport {
        guard !shutdownComplete else {
            return await presentation.currentTeardownReport(
                scope: .immersiveShutdown,
                reason: "alreadyShutdown.\(reason)"
            )
        }
        shutdownComplete = true
        started = false
        lifecycleGeneration &+= 1
        TuringMemoryBudgetProbe.log(label: "mindEye.immersiveShutdown.before")
        memoryPressureTask?.cancel()
        memoryPressureTask = nil
        await memoryPressureSource.stop()
        await TuringGeneratedSpeechAnalysisCoordinator.shared.cancelAll(
            reason: "immersiveShutdown.\(reason)"
        )
        presentation.setLifecycleAllowsPresentation(false, reason: "immersiveShutdown.\(reason)")
        let report = await presentation.shutdown(reason: reason)
        await assetMemory.forceEvictAll(reason: "immersiveShutdown.\(reason)")
        await authoredFrameStore.forceEvictAll(reason: "immersiveShutdown.\(reason)")
        clearRegistriesAfterTeardown(reason: "immersiveShutdown.\(reason)")
        await physicalPresenceHub.forceRelease(
            sourcePrefix: "chapter03.mikeBattle.",
            reason: "immersiveShutdown.\(reason)"
        )
        TuringMemoryBudgetProbe.log(label: "mindEye.immersiveShutdown.after")
        return report
    }

    private func handleMemoryPressure(_ level: MindEyeMemoryPressureLevel) async {
        guard !shutdownComplete, memoryPressure != level else { return }
        memoryPressure = level
        lifecycleGeneration &+= 1
        switch level {
        case .normal:
            presentation.setResponsePortraitLoadDecision(
                applicationState == .active ? .allowLoad : .deny,
                reason: "memoryPressure.normal"
            )
            if applicationState == .active {
                presentation.setLifecycleAllowsPresentation(true, reason: "memoryPressure.normal")
            }
        case .warning:
            presentation.setResponsePortraitLoadDecision(
                applicationState == .active ? .reuseExistingOnly : .deny,
                reason: "memoryPressure.warning"
            )
            TuringMemoryBudgetProbe.log(label: "mindEye.memory.warning.before")
            await presentation.releasePreparedAndEvictInactive(reason: "memoryPressure.warning")
            _ = await assetMemory.evictInactive(reason: "memoryPressure.warning")
            await authoredFrameStore.evictInactive(reason: "memoryPressure.warning")
            TuringMemoryBudgetProbe.log(label: "mindEye.memory.warning.after")
        case .critical:
            // Device evidence showed that tearing down the complete Mind's Eye
            // stack reclaimed only ~61 MB while permanently suppressing the
            // remaining response portrait and runtime lip sync. Preserve the
            // visual and analyzer; optimization work belongs in Turing/MLX.
            TuringMemoryBudgetProbe.log(
                label: "mindEye.memory.critical.observed.noTeardown"
            )
            presentation.setLifecycleAllowsPresentation(
                applicationState == .active,
                reason: "memoryPressure.critical.noTeardown"
            )
            presentation.setResponsePortraitLoadDecision(
                applicationState == .active ? .allowLoad : .deny,
                reason: "memoryPressure.critical.noTeardown"
            )
            print(
                "[MindEyeLifecycle] critical memory pressure observed " +
                    "action=noTeardown target=TuringMLXOptimization"
            )
        }
    }

    private func clearRegistriesAfterTeardown(reason: String) {
        MindEyeMotionFrameRegistry.shared.removeAll(reason: reason)
        MindEyeAuthoredFramePlaybackRegistry.shared.removeAll(reason: reason)
        MindEyeGeneratedFramePlaybackRegistry.shared.removeAll(reason: reason)
        assert(MindEyeMotionFrameRegistry.shared.entryCount == 0)
        assert(MindEyeAuthoredFramePlaybackRegistry.shared.entryCount == 0)
        assert(MindEyeGeneratedFramePlaybackRegistry.shared.entryCount == 0)
    }
}
