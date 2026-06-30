import AVFoundation
import SwiftUI

struct TuringPrologueDebugView: View {
    @State private var status = "Idle."
    @State private var renderedURL: URL?
    @State private var isRendering = false
    @State private var isRunningCanary = false
    @State private var isRunningSoak = false
    @State private var canaryPassed = false
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
                runNativeCanary()
            } label: {
                Label(
                    isRunningCanary ? "Running Canary..." : "Run Qwen Native Canary",
                    systemImage: "checkmark.shield"
                )
            }
            .disabled(isRendering || isRunningCanary)

            Button {
                renderPhase0Line()
            } label: {
                Label(
                    isRendering ? "Generating..." : "Generate + Play Qwen Line",
                    systemImage: "waveform"
                )
            }
            .disabled(isRendering || isRunningCanary || !canaryPassed)

            Button {
                runNoCacheMemorySoak()
            } label: {
                Label(
                    isRunningSoak ? "Running Soak..." : "Run Qwen No-Cache Memory Soak",
                    systemImage: "memorychip"
                )
            }
            .disabled(isRendering || isRunningCanary || isRunningSoak)
        }
        .padding(24)
        .frame(minWidth: 420)
        .task {
            await refreshCanaryStatus()
        }
    }

    @MainActor
    private func refreshCanaryStatus() async {
        do {
            let harness = try await TuringRuntimeFactory.makeDebugHarness()
            canaryPassed = try await harness.canaryPassedForActiveTuple()
            if canaryPassed {
                status = "Qwen native canary passed. Generate + Play is enabled."
                return
            }

            if let report = try await harness.loadCanaryReport(),
               report.likelyPreviousProcessAssert {
                status = """
                Previous Qwen canary likely process-asserted at \(report.lastStartedStage?.rawValue ?? "unknown"). Run Canary is the next diagnostic step.
                """
            } else {
                status = "Run Qwen Native Canary before Generate + Play."
            }
        } catch {
            status = error.localizedDescription
            canaryPassed = false
        }
    }

    private func runNativeCanary() {
        isRunningCanary = true
        status = "Running Qwen native canary..."
        renderedURL = nil
        audioPlayer?.stop()
        audioPlayer = nil

        Task { @MainActor in
            do {
                let harness = try await TuringRuntimeFactory.makeDebugHarness()
                let rendered = try await harness.runPhase0NativeCanary()
                renderedURL = rendered.fileURL
                try play(rendered: rendered)
                scheduleTransientCleanup(
                    rendered: rendered,
                    harness: harness,
                    reason: "playbackCompleted"
                )
                canaryPassed = try await harness.canaryPassedForActiveTuple()
                status = "Qwen native canary passed and played \(String(format: "%.2f", rendered.durationSeconds))s WAV."
            } catch {
                canaryPassed = false
                status = error.localizedDescription

                print(
                    """
                    [TuringTTS] ERROR Phase 0 native canary failed
                      error: \(error.localizedDescription)
                      fallback: false
                    """
                )
            }

            isRunningCanary = false
        }
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
                try play(rendered: rendered)
                scheduleTransientCleanup(
                    rendered: rendered,
                    harness: harness,
                    reason: "playbackCompleted"
                )

                status = "Rendered and playing \(String(format: "%.2f", rendered.durationSeconds))s WAV. voiceArgument=nil refAudio=nil refText=nil."

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

    private func runNoCacheMemorySoak() {
        isRunningSoak = true
        status = "Running Qwen no-cache memory soak..."
        renderedURL = nil
        audioPlayer?.stop()
        audioPlayer = nil

        Task { @MainActor in
            do {
                let harness = try await TuringRuntimeFactory.makeDebugHarness()
                let result = try await harness.runNoCacheMemorySoak(
                    iterations: 20
                )
                renderedURL = result.reportURL
                status = "Qwen no-cache memory soak finished. rendered=\(result.renderedCount) failed=\(result.failedCount)"
            } catch {
                status = error.localizedDescription

                print(
                    """
                    [TuringSoak] ERROR Qwen no-cache memory soak failed
                      error: \(error.localizedDescription)
                    """
                )
            }

            isRunningSoak = false
        }
    }

    private func play(
        rendered: TuringRenderedSegment
    ) throws {
        let player = try AVAudioPlayer(
            contentsOf: rendered.fileURL
        )
        player.prepareToPlay()
        player.play()
        audioPlayer = player

        print(
            """
            [TuringAudio] Turing transient playback started
              renderID: \(rendered.renderID)
              file: \(rendered.fileURL.lastPathComponent)
              durationSeconds: \(rendered.durationSeconds)
            """
        )
    }

    private func scheduleTransientCleanup(
        rendered: TuringRenderedSegment,
        harness: TuringDebugHarness,
        reason: String
    ) {
        guard rendered.isTransient else {
            return
        }

        Task {
            let delaySeconds = rendered.durationSeconds + 2.0
            try? await Task.sleep(
                nanoseconds: UInt64(delaySeconds * 1_000_000_000)
            )
            await harness.cleanupRenderedSegment(
                rendered,
                reason: reason
            )

            print(
                """
                [TuringAudio] Turing transient playback finished
                  renderID: \(rendered.renderID)
                  cleanupReason: \(reason)
                """
            )
        }
    }
}
