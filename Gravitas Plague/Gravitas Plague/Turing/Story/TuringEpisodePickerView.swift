import SwiftUI

struct TuringEpisodePickerView: View {
    @ObservedObject var session: PlagueDemoSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var openingEpisodeID: TuringEpisodeID?

    private let episodes = TuringEpisodeCatalog.developmentEpisodes

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Story Mode")
                    .font(.title2.weight(.semibold))

                Spacer()

                Button("Close") {
                    session.isStoryEpisodePickerPresented = false
                    dismiss()
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Episodes")
                    .font(.headline)

                ForEach(episodes) { episode in
                    episodeButton(episode)
                }
            }

            Divider()

            TuringPrologueDebugView()
        }
        .padding(24)
        .frame(minWidth: 520)
    }

    private func episodeButton(
        _ episode: TuringEpisodeDescriptor
    ) -> some View {
        Button {
            Task { @MainActor in
                await openImmersiveIfNeededAndStart(
                    episode
                )
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(episode.title)
                        .font(.headline)
                    Text(episode.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if openingEpisodeID == episode.id {
                    ProgressView()
                        .controlSize(.small)
                } else if !episode.isUnlocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!episode.isUnlocked || openingEpisodeID != nil)
    }

    @MainActor
    private func openImmersiveIfNeededAndStart(
        _ episode: TuringEpisodeDescriptor
    ) async {
        guard episode.isUnlocked else {
            return
        }

        guard openingEpisodeID == nil else {
            return
        }

        openingEpisodeID = episode.id
        defer {
            openingEpisodeID = nil
        }

        guard session.immersiveSpaceStatus != .opening else {
            return
        }

        if session.immersiveSpaceStatus == .closed {
            session.immersiveSpaceStatus = .opening
            session.forestImmersiveState = .opening
            session.forestImmersiveStatus = "Opening mixed room scene..."
            session.statusMessage = "Opening Story episode."

            let result = await openImmersiveSpace(
                id: PlagueDemoSession.immersiveSpaceID
            )

            switch result {
            case .opened:
                session.immersiveSpaceStatus = .open
                session.forestImmersiveDidOpen()

            case .userCancelled:
                session.immersiveSpaceStatus = .closed
                session.forestImmersiveState = .closed
                session.forestImmersiveStatus = "Mixed room scene cancelled."
                session.statusMessage = "Story episode was not opened."
                return

            case .error:
                session.immersiveSpaceStatus = .closed
                session.forestImmersiveState = .failed
                session.forestImmersiveStatus = "Mixed room scene failed."
                session.statusMessage = "Could not open Story episode."
                return

            @unknown default:
                session.immersiveSpaceStatus = .closed
                session.forestImmersiveState = .failed
                session.forestImmersiveStatus = "Mixed room scene failed: \(String(describing: result))"
                session.statusMessage = "Unknown immersive-space result."
                return
            }
        }

        session.startStoryEpisode(
            episode.id
        )
        dismiss()
    }
}
