import SwiftUI

struct TuringEpisodePickerView: View {
    @ObservedObject var session: PlagueDemoSession
    @Environment(\.dismiss) private var dismiss

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
            session.startStoryEpisode(episode.id)
            dismiss()
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

                if !episode.isUnlocked {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!episode.isUnlocked)
    }
}
