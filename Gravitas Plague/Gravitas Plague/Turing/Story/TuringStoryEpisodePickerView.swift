import SwiftUI

struct TuringStoryEpisodePickerView: View {
    @ObservedObject var session: PlagueDemoSession
    @ObservedObject private var progress = TuringStoryProgressStore.shared
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var activeRequest = false
    @State private var errorMessage: String?
    @State private var pendingStartOver: TuringEpisodeDescriptor?

#if DEBUG || GR_TURING_DIAGNOSTICS
    private let episodes = TuringEpisodeCatalog.developmentEpisodes
#else
    private let episodes = TuringEpisodeCatalog.productionEpisodes
#endif

    var body: some View {
        GeometryReader { proxy in
            let layout = TuringEpisodePlateGeometry.layout(in: proxy.size)

            ZStack(alignment: .topLeading) {
                Color.clear

                Color.turingEpisodePickerSurface
                    .frame(
                        width: layout.plateFrame.width,
                        height: layout.plateFrame.height
                    )
                    .position(x: layout.plateFrame.midX, y: layout.plateFrame.midY)

                episodeScroll(
                    contentWidth: layout.contentFrame.width,
                    plateScale: layout.scale
                )
                .frame(
                    width: layout.contentFrame.width,
                    height: layout.contentFrame.height
                )
                .position(x: layout.contentFrame.midX, y: layout.contentFrame.midY)
                .clipped()

                Image(TuringEpisodePickerArtwork.plate)
                    .resizable()
                    .interpolation(.high)
                    .frame(
                        width: layout.plateFrame.width,
                        height: layout.plateFrame.height
                    )
                    .position(x: layout.plateFrame.midX, y: layout.plateFrame.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(
            TuringEpisodePlateGeometry.referenceSize.width /
                TuringEpisodePlateGeometry.referenceSize.height,
            contentMode: .fit
        )
        .frame(minWidth: 720, idealWidth: 960, minHeight: 480, idealHeight: 640)
        .onAppear {
            progress.reloadFromDefaults()
        }
        .confirmationDialog(
            "Start the Prologue from the beginning?",
            isPresented: Binding(
                get: { pendingStartOver != nil },
                set: { if !$0 { pendingStartOver = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Start Over", role: .destructive) {
                guard let episode = pendingStartOver else { return }
                pendingStartOver = nil
                startEpisodeFromBeginning(episode)
            }
            Button("Cancel", role: .cancel) {
                pendingStartOver = nil
            }
        } message: {
            Text("Your current Story checkpoint will be replaced.")
        }
        .alert(
            "Story Could Not Start",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "Unknown Story error.")
        }
    }

    @ViewBuilder
    private func episodeScroll(contentWidth: CGFloat, plateScale: CGFloat) -> some View {
        let rowSpacing = max(8, 14 * plateScale)
        ScrollView(.vertical) {
            LazyVStack(spacing: rowSpacing) {
                TuringEpisodeArtworkStrip(
                    artwork: .continueStrip,
                    enabled: progress.canContinue && !activeRequest,
                    accessibilityLabelText: "Continue",
                    accessibilityHintText: progress.canContinue
                        ? progress.accessibilitySummary
                        : "No valid Story progress is available.",
                    action: continueStory
                )

                ForEach(episodes) { episode in
                    TuringEpisodeArtworkStrip(
                        artwork: episode.stripArtwork,
                        enabled: isEnabled(episode),
                        accessibilityLabelText: "\(episode.title). \(episode.subtitle).",
                        accessibilityHintText: accessibilityHint(episode),
                        action: { chooseEpisode(episode) }
                    )
                }
            }
            .frame(width: contentWidth)
            .padding(.vertical, max(5, 8 * plateScale))
        }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.turingEpisodePickerSurface)
    }

    private func isEnabled(_ episode: TuringEpisodeDescriptor) -> Bool {
        guard !activeRequest else { return false }
        return episode.availability == .unlocked
    }

    private func accessibilityHint(_ episode: TuringEpisodeDescriptor) -> String {
        switch episode.availability {
        case .unlocked:
            return "Start this episode from the beginning."
        case .locked(let reason):
            return reason
        case .comingSoon:
            return "Coming soon."
        }
    }

    private func chooseEpisode(_ episode: TuringEpisodeDescriptor) {
        guard isEnabled(episode) else { return }
        if progress.canContinue {
            pendingStartOver = episode
        } else {
            startEpisodeFromBeginning(episode)
        }
    }

    private func continueStory() {
        guard !activeRequest, progress.canContinue else { return }
        activeRequest = true
        Task { @MainActor in
            defer { activeRequest = false }
            do {
                progress.reloadFromDefaults()
                let target = try progress.requireValidContinuationTarget()
                await PlagueMainMenuMusicActor.shared.stop(
                    reason: "storyContinueSelected"
                )
                switch target {
                case .prologue(let snapshot):
                    let destination = try TuringStoryDestinationPlanner
                        .destination(for: snapshot)
                    try await TuringStoryStateTeleportCoordinator.shared.apply(
                        destination,
                        source: "episodePicker.continue.prologue"
                    )
                case .chapter01:
                    session.continueStoryEpisode(.chapter01)
                }
                dismissWindow(id: PlagueWindowID.storyEpisodes)
            } catch {
                await restoreMenuMusicAfterFailedSelection(
                    reason: "storyContinueFailed"
                )
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startEpisodeFromBeginning(_ episode: TuringEpisodeDescriptor) {
        guard !activeRequest else { return }
        activeRequest = true
        Task { @MainActor in
            defer { activeRequest = false }
            do {
                await PlagueMainMenuMusicActor.shared.stop(
                    reason: "storyEpisodeSelected.\(episode.id.rawValue)"
                )
                if episode.id == .chapter01 {
                    progress.clear(
                        reason: "startOver.\(episode.id.rawValue)"
                    )
                    session.startStoryEpisode(episode.id)
                    dismissWindow(id: PlagueWindowID.storyEpisodes)
                    return
                }
                await Chapter01ProgressStore.shared.clear(
                    reason: "startOver.\(episode.id.rawValue)"
                )
                progress.clear(reason: "startOver.\(episode.id.rawValue)")
                let destination = try TuringStoryDestinationPlanner.startOfEpisode(episode.id)
                try await TuringStoryStateTeleportCoordinator.shared.apply(
                    destination,
                    source: "episodePicker.startOver"
                )
                dismissWindow(id: PlagueWindowID.storyEpisodes)
            } catch {
                await restoreMenuMusicAfterFailedSelection(
                    reason: "storyEpisodeStartFailed.\(episode.id.rawValue)"
                )
                errorMessage = error.localizedDescription
            }
        }
    }

    private func restoreMenuMusicAfterFailedSelection(
        reason: String
    ) async {
        do {
            try await PlagueMainMenuMusicActor.shared.startIfNeeded(
                reason: reason
            )
        } catch {
            print(
                "[PlagueMenuMusic] ERROR recovery failed: \(error.localizedDescription)"
            )
        }
    }
}
