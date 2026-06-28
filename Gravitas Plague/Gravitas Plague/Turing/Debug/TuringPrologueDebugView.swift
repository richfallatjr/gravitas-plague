import SwiftUI

struct TuringPrologueDebugView: View {
    @State private var status = "Idle."
    @State private var renderedURL: URL?
    @State private var isRendering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Prologue Turing Debug")
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
                    isRendering ? "Generating..." : "Generate Phase 0 Line",
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

        Task { @MainActor in
            do {
                let harness = try await TuringRuntimeFactory.makeDebugHarness()
                status = "Generating on Qwen..."
                let rendered = try await harness.generatePhase0Line()
                renderedURL = rendered.fileURL
                status = "Rendered \(String(format: "%.2f", rendered.durationSeconds))s WAV."
            } catch {
                status = error.localizedDescription
            }

            isRendering = false
        }
    }
}
