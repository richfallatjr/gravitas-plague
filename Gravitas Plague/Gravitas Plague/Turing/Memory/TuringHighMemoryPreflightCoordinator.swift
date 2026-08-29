import Foundation

actor TuringHighMemoryPreflightCoordinator:
    TuringHighMemoryScenePreparing
{
    static let shared = TuringHighMemoryPreflightCoordinator()

    private let interactionArbiter: StoryInteractionArbiter
    private weak var storyPreparer:
        (any TuringHighMemoryScenePreparing)?
    private weak var mindEyePreparer:
        (any MindEyeHighMemoryPreparing)?

    init(interactionArbiter: StoryInteractionArbiter = .shared) {
        self.interactionArbiter = interactionArbiter
    }

    func install(
        _ preparer: any TuringHighMemoryScenePreparing
    ) {
        storyPreparer = preparer
        print("[TuringHighMemoryPreflight] Story scene adapter installed")
    }

    func clear() {
        storyPreparer = nil
        print("[TuringHighMemoryPreflight] Story scene adapter cleared")
    }

    func installMindEye(_ preparer: any MindEyeHighMemoryPreparing) {
        mindEyePreparer = preparer
        print("[TuringHighMemoryPreflight] Mind’s Eye adapter installed")
    }

    func clearMindEye() {
        mindEyePreparer = nil
        print("[TuringHighMemoryPreflight] Mind’s Eye adapter cleared")
    }

    func prepareForTuringHighMemoryRun(runID: String) async throws {
        TuringMemoryBudgetProbe.log(
            label: "qwen.preflight.requested",
            runID: runID
        )
        print("""
        [TuringHighMemoryPreflight] requested
          runID: \(runID)
          hasStorySceneAdapter: \(storyPreparer != nil)
          hasMindEyeAdapter: \(mindEyePreparer != nil)
        """)
        let mindEyeReport = await mindEyePreparer?.prepareForTuringHighMemoryRun(
            runID: runID,
            policy: .retainMatchingRunActive
        )
        if let report = mindEyeReport {
            print("""
            [TuringHighMemoryPreflight] Mind’s Eye prepared
              runID: \(runID)
              preparedVisualReleased: \(report.preparedVisualReleased)
              activeRetained: \(report.activePresentationRetained)
              activeReleased: \(report.activePresentationReleased)
              retainedActiveRunID: \(report.retainedActiveRunID ?? "none")
              assetCacheBefore: \(report.assetCacheBefore)
              assetCacheAfter: \(report.assetCacheAfter)
              authoredTrackCacheBefore: \(report.authoredTrackCacheBefore)
              authoredTrackCacheAfter: \(report.authoredTrackCacheAfter)
              forcedEvictionApplied: \(report.forcedEvictionApplied)
            """)
        }
        guard let storyPreparer else {
            TuringMemoryBudgetProbe.log(
                label: "qwen.preflight.completedWithoutStoryScene",
                runID: runID
            )
            print("""
            [TuringHighMemoryPreflight] completed
              runID: \(runID)
              mode: noStoryScene
            """)
            return
        }

        try await storyPreparer.prepareForTuringHighMemoryRun(
            runID: runID
        )
        TuringMemoryBudgetProbe.log(
            label: "qwen.preflight.storySceneReleased",
            runID: runID
        )
        print("""
        [TuringHighMemoryPreflight] completed
          runID: \(runID)
          mode: StorySceneReleased
        """)
    }

    func acquireInteractionLease(
        runID: String,
        source: String,
        mode: TuringInteractionStartMode,
        interactionSurface: StoryInteractionSurfaceID = .walkie
    ) async throws -> StoryInteractionLease {
        switch mode {
        case .manual:
            return try await interactionArbiter.claimManualTuring(
                runID: runID,
                surfaceID: interactionSurface,
                source: source
            )
        case .automatic:
            if interactionSurface == .walkie,
               let storyPreparer {
                return try await storyPreparer
                    .acquireAutomaticTuringInteractionLease(
                        runID: runID,
                        source: source
                    )
            }
            return try await interactionArbiter
                .claimAutomaticTuring(
                    runID: runID,
                    surfaceID: interactionSurface,
                    source: source
                )
        }
    }

    func acquireAutomaticTuringInteractionLease(
        runID: String,
        source: String
    ) async throws -> StoryInteractionLease {
        try await acquireInteractionLease(
            runID: runID,
            source: source,
            mode: .automatic
        )
    }
}
