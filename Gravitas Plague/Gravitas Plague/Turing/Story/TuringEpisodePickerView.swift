import SwiftUI

struct TuringEpisodePickerView: View {
    @ObservedObject var session: PlagueDemoSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var openingEpisodeID: TuringEpisodeID?
    @State private var selectedEpisodeID: TuringEpisodeID? = .prologue
#if DEBUG || GR_TURING_DIAGNOSTICS
    @State private var qwenNativeRunningPreset: TuringNativeQwenVoiceDesignCanaryPreset?
    @State private var qwenDebugStatus = "Idle"
    @State private var memorySnapshot = TuringMemoryBudgetProbe.currentSnapshot(
        label: "storyPickerInitial"
    )
#endif

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

#if DEBUG || GR_TURING_DIAGNOSTICS
            if PlagueFeatureFlags.showQwenHelloWorldInEpisodePicker {
                Divider()
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Qwen Model Check")
                        .font(.headline)

                    memoryBudgetReadout
                    Text(qwenDebugStatus)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Text("Runs the in-repo TuringQwenNative Base clone runtime directly from the episode picker.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Requires the Big Mike Base clone profile. No runtime reference-audio encoding and no design-prompt fallback.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    knownQwenButton(
                        title: "Run Native Qwen - Big Mike Base Clone Short",
                        runningTitle: "Running Base Clone Short...",
                        preset: .bigMikeShortDynamic,
                        prominence: .prominent
                    )

                    knownQwenButton(
                        title: "Run Native Qwen - Big Mike Base Clone Longform 2 Segments",
                        runningTitle: "Running Base Clone Longform 2 Segments...",
                        preset: .bigMikeBroadcastTwoSegmentDynamic,
                        prominence: .standard
                    )

                    knownQwenButton(
                        title: "Run Native Qwen - Big Mike Base Clone Longform",
                        runningTitle: "Running Base Clone Longform...",
                        preset: .bigMikeBroadcastLongformDynamic,
                        prominence: .prominent
                    )
                }
            }
#endif

        }
        .padding(24)
        .frame(minWidth: 520)
        .onAppear {
            memorySnapshot = TuringMemoryBudgetProbe.log(
                label: "storyPickerOpened"
            )
        }
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
                } else if selectedEpisodeID == episode.id {
                    Text("Selected")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
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

#if DEBUG || GR_TURING_DIAGNOSTICS
    @ViewBuilder
    private func knownQwenButton(
        title: String,
        runningTitle: String,
        preset: TuringNativeQwenVoiceDesignCanaryPreset,
        prominence: KnownQwenButtonProminence,
        isEnabled: Bool = true
    ) -> some View {
        let isRunning = qwenNativeRunningPreset == preset

        let button = Button {
            guard qwenNativeRunningPreset == nil else {
                print("""
                [TuringQwenNativeBaseClone] episode picker generation tap ignored
                  preset: \(preset.rawValue)
                  reason: generationAlreadyRunning
                  runningPreset: \(qwenNativeRunningPreset?.rawValue ?? "none")
                """)
                return
            }

            print("""
            [TuringQwenNativeBaseClone] episode picker generation button tapped
              preset: \(preset.rawValue)
              isEnabled: \(isEnabled)
              runningPreset: none
            """)

            qwenNativeRunningPreset = preset
            qwenDebugStatus = "Running \(preset.rawValue)"
            memorySnapshot = TuringMemoryBudgetProbe.log(
                label: "beforeQwenGenerate",
                activeQwenModelID: "qwen3-tts-12hz-1.7b-base-4bit",
                quantization: "4bit"
            )

            Task.detached(priority: .userInitiated) {
                let result = await TuringNativeQwenHelloWorldCanary.run(
                    preset: preset
                )

                await MainActor.run {
                    qwenNativeRunningPreset = nil
                    qwenDebugStatus = result.pickerStatus
                    memorySnapshot = TuringMemoryBudgetProbe.log(
                        label: "afterTransientCleanup"
                    )
                }
            }
        } label: {
            HStack(spacing: 8) {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(
                    isRunning
                        ? runningTitle
                        : title
                )
            }
        }

        switch prominence {
        case .standard:
            button
                .buttonStyle(.bordered)
                .disabled(qwenNativeRunningPreset != nil || !isEnabled)

        case .prominent:
            button
                .buttonStyle(.borderedProminent)
                .disabled(qwenNativeRunningPreset != nil || !isEnabled)
        }
    }

    private enum KnownQwenButtonProminence {
        case standard
        case prominent
    }

    private var memoryBudgetReadout: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Footprint \(memorySnapshot.physicalFootprintMB) MB")
            Text("Available \(memorySnapshot.availableProcessMemoryMB) MB")
            Text("Increased memory \(memorySnapshot.increasedMemoryEntitlementStatus)")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
#endif

    @MainActor
    private func openImmersiveIfNeededAndStart(
        _ episode: TuringEpisodeDescriptor
    ) async {
        guard episode.isUnlocked else {
            return
        }

        if PlagueFeatureFlags.phase0PrologueRunsInSwiftUIPickerOnly,
           episode.id == .prologue {
            selectedEpisodeID = episode.id
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
