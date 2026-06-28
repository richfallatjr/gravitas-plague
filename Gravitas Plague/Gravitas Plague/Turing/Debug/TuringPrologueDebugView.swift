import AVFoundation
import SwiftUI

struct TuringPrologueDebugView: View {
    @State private var status = "Idle."
    @State private var renderedURL: URL?
    @State private var isRendering = false
    @State private var audioPlayer: AVAudioPlayer?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Qwen Phase 0 Smoke")
                .font(.title2.weight(.semibold))

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let renderedURL {
                Text(renderedURL.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            Button {
                renderPhase0Line()
            } label: {
                Label(
                    isRendering ? "Generating..." : "Generate + Play Qwen Line",
                    systemImage: "waveform"
                )
            }
            .disabled(isRendering)
        }
        .padding(24)
        .frame(minWidth: 420)
    }

    private func renderPhase0Line() {
        isRendering = true
        status = "Loading Qwen runtime..."
        renderedURL = nil
        audioPlayer?.stop()
        audioPlayer = nil

        Task { @MainActor in
            do {
                let harness = try await TuringRuntimeFactory.makeDebugHarness()
                status = "Generating on Qwen..."
                let rendered = try await harness.generatePhase0Line()
                renderedURL = rendered.fileURL

                let player = try AVAudioPlayer(
                    contentsOf: rendered.fileURL
                )
                player.prepareToPlay()
                player.play()
                audioPlayer = player

                status = "Rendered and playing \(String(format: "%.2f", rendered.durationSeconds))s WAV."

                print(
                    """
                    [TuringTTS] Phase 0 SwiftUI smoke complete
                      file: \(rendered.fileURL.path)
                      durationSeconds: \(rendered.durationSeconds)
                      playbackRoute: swiftui_debug_av_audio_player
                      immersiveRequired: false
                    """
                )
            } catch {
                status = error.localizedDescription

                print(
                    """
                    [TuringTTS] ERROR Phase 0 SwiftUI smoke failed
                      error: \(error.localizedDescription)
                      immersiveRequired: false
                      fallback: false
                    """
                )
            }

            isRendering = false
        }
    }
}
