import SwiftUI

struct TuringEpisodeArtworkStrip: View {
    let artwork: TuringEpisodeStripArtwork
    let enabled: Bool
    let accessibilityLabelText: String
    let accessibilityHintText: String
    let action: () -> Void

    var body: some View {
        Button {
            guard enabled else { return }
            action()
        } label: {
            Image(artwork.assetName)
                .resizable()
                .interpolation(.high)
                .aspectRatio(
                    artwork.pixelSize.width / artwork.pixelSize.height,
                    contentMode: .fit
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(TuringEpisodeArtworkButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.36)
        .saturation(enabled ? 1 : 0.25)
        .hoverEffect(enabled ? .highlight : .automatic)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(accessibilityHintText)
        .accessibilityAddTraits(.isButton)
    }
}

private struct TuringEpisodeArtworkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.988 : 1)
            .brightness(configuration.isPressed ? -0.08 : 0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}
