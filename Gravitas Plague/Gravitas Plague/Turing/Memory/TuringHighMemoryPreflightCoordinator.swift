import Foundation

actor TuringHighMemoryPreflightCoordinator:
    TuringHighMemoryScenePreparing
{
    static let shared = TuringHighMemoryPreflightCoordinator()

    private let interactionArbiter: StoryInteractionArbiter
    private weak var storyPreparer:
        (any TuringHighMemoryScenePreparing)?

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

    func prepareForTuringHighMemoryRun(runID: String) async throws {
        print("""
        [TuringHighMemoryPreflight] requested
          runID: \(runID)
          hasStorySceneAdapter: \(storyPreparer != nil)
        """)
        guard let storyPreparer else {
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
