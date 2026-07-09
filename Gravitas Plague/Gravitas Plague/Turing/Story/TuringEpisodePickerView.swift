import SwiftUI

struct TuringEpisodePickerView: View {
    @ObservedObject var session: PlagueDemoSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var openingEpisodeID: TuringEpisodeID?
    @State private var selectedEpisodeID: TuringEpisodeID? = .prologue
#if DEBUG || GR_TURING_DIAGNOSTICS
    @StateObject private var dictationCoordinator = TuringDictationCoordinator()
    @StateObject private var radioStaticLeadIn = TuringRadioStaticLeadInController()
    @State private var qwenNativeRunningPreset: TuringNativeQwenVoiceDesignCanaryPreset?
    @State private var turingDialogueBusy = false
    @State private var dictationPressActive = false
    @State private var dictationStartTask: Task<Void, Never>?
    @State private var qwenDebugStatus = "Idle"
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
                    knownQwenButton(
                        title: "ATNV-15 Cases Spread Across City",
                        runningTitle: "Reading ATNV-15 Headline...",
                        preset: .bigMikeBroadcastLongformDynamic,
                        prominence: .standard
                    )

                    Button {
                        runGravitasPlagueBackstory()
                    } label: {
                        HStack(spacing: 8) {
                            if turingDialogueBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Gravitas Plague Backstory")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(qwenNativeRunningPreset != nil || turingDialogueBusy)

                    Button {
                        runBigMikeRichContactPrerecordingSeedTest()
                    } label: {
                        HStack(spacing: 8) {
                            if turingDialogueBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Run Big Mike Rich Contact PR Seed")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(qwenNativeRunningPreset != nil || turingDialogueBusy)

                    Divider()
                        .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        TuringDictateButton(
                            isRecording: dictationCoordinator.isRecording,
                            isBusy: qwenNativeRunningPreset != nil || turingDialogueBusy,
                            onPressStarted: {
                                startBigMikeDictation()
                            },
                            onPressEnded: {
                                finishBigMikeDictationAndSend()
                            }
                        )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Hold Mic: Ask Big Mike")
                                .font(.subheadline.weight(.semibold))
                            Text(dictationStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
#endif

        }
        .padding(24)
        .frame(minWidth: 520)
        .onAppear {
            dictationCoordinator.onEvent = { event in
                session.publishTuringDictationEvent(event)
            }
        }
#if DEBUG || GR_TURING_DIAGNOSTICS
        .onReceive(
            NotificationCenter.default.publisher(
                for: .turingStoryWalkieMicHoldBegan
            )
        ) { _ in
            startBigMikeDictation()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .turingStoryWalkieMicHoldEnded
            )
        ) { _ in
            finishBigMikeDictationAndSend()
        }
#endif
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
            guard qwenNativeRunningPreset == nil,
                  turingDialogueBusy == false else {
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
            radioStaticLeadIn.start(reason: "qwenTestStarted.\(preset.rawValue)")

            Task.detached(priority: .userInitiated) {
                let result = await TuringNativeQwenHelloWorldCanary.run(
                    preset: preset
                )

                await MainActor.run {
                    qwenNativeRunningPreset = nil
                    radioStaticLeadIn.stop(reason: "qwenTestFinished.\(preset.rawValue)")
                    qwenDebugStatus = result.pickerStatus
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
                .disabled(qwenNativeRunningPreset != nil || turingDialogueBusy || !isEnabled)

        case .prominent:
            button
                .buttonStyle(.borderedProminent)
                .disabled(qwenNativeRunningPreset != nil || turingDialogueBusy || !isEnabled)
        }
    }

    private var dictationStatusText: String {
        if dictationCoordinator.isRecording {
            return dictationCoordinator.partialTranscript.isEmpty
                ? "Listening..."
                : dictationCoordinator.partialTranscript
        }

        if turingDialogueBusy {
            return "Processing..."
        }

        return "Pinch and hold to speak. Release to send."
    }

    private func runGravitasPlagueBackstory() {
        guard qwenNativeRunningPreset == nil,
              turingDialogueBusy == false else {
            return
        }

        turingDialogueBusy = true
        qwenDebugStatus = "Running Gravitas Plague Backstory"
        radioStaticLeadIn.start(reason: "backstoryTestStarted")

        Task.detached(priority: .userInitiated) {
            let result = await TuringNativeQwenHelloWorldCanary
                .runLongformVoiceScriptResource(
                    resourcePath: "Turing/Scripts/Phase1/gravitas_plague_backstory.txt",
                    requestID: "phase1.gravitasPlagueBackstory.001",
                    debugLabel: "Gravitas Plague Backstory"
                )

            await MainActor.run {
                turingDialogueBusy = false
                radioStaticLeadIn.stop(reason: "backstoryTestFinished")
                qwenDebugStatus = result.pickerStatus
            }
        }
    }

    private func runBigMikeRichContactPrerecordingSeedTest() {
        guard qwenNativeRunningPreset == nil,
              turingDialogueBusy == false else {
            return
        }

        turingDialogueBusy = true
        qwenDebugStatus = "Running Big Mike Rich Contact PR seed test"
        radioStaticLeadIn.start(reason: "bigMikeRichContactPrerecordingSeedStarted")

        Task.detached(priority: .userInitiated) {
            let result = await TuringPrerecordingSeededPromptRunner
                .runBigMikeRichContact(
                    seedStore: TuringConversationSeedStore.shared
                )

            await MainActor.run {
                radioStaticLeadIn.stop(
                    reason: "bigMikeRichContactPrerecordingSeedFinished"
                )
                turingDialogueBusy = false
                qwenDebugStatus = result.pickerStatus
            }
        }
    }

    private func startBigMikeDictation() {
        guard qwenNativeRunningPreset == nil,
              turingDialogueBusy == false else {
            return
        }

        dictationPressActive = true
        dictationStartTask?.cancel()
        qwenDebugStatus = "Opening Story HUD for dictation"

        dictationStartTask = Task { @MainActor in
            guard await ensureImmersiveSpaceForTuringHUD(
                reason: "holdMicDictation"
            ) else {
                dictationPressActive = false
                session.publishTuringDictationEvent(
                    .failed("HUD unavailable.")
                )
                qwenDebugStatus = "Failed: HUD unavailable."
                return
            }

            guard dictationPressActive else {
                await dictationCoordinator.cancel(
                    reason: "press ended before recording started"
                )
                return
            }

            await dictationCoordinator.beginHoldToRecord()

            if !dictationPressActive,
               dictationCoordinator.isRecording {
                await dictationCoordinator.cancel(
                    reason: "press ended before recording startup completed"
                )
            }
        }
    }

    @MainActor
    private func ensureImmersiveSpaceForTuringHUD(
        reason: String
    ) async -> Bool {
        if session.immersiveSpaceStatus == .open {
            return true
        }

        guard session.immersiveSpaceStatus != .opening else {
            print("""
            [TuringHUD] existing HUD unavailable
              reason: \(reason)
              immersiveSpaceStatus: opening
            """)
            return false
        }

        session.immersiveSpaceStatus = .opening
        session.forestImmersiveState = .opening
        session.forestImmersiveStatus = "Opening mixed room scene for Turing HUD..."
        session.statusMessage = "Opening Story HUD."

        let result = await openImmersiveSpace(
            id: PlagueDemoSession.immersiveSpaceID
        )

        switch result {
        case .opened:
            session.immersiveSpaceStatus = .open
            session.forestImmersiveDidOpen()
            print("""
            [TuringHUD] existing HUD immersive space opened
              reason: \(reason)
            """)
            return true

        case .userCancelled:
            session.immersiveSpaceStatus = .closed
            session.forestImmersiveState = .closed
            session.forestImmersiveStatus = "Mixed room scene cancelled."
            session.statusMessage = "Story HUD was not opened."
            return false

        case .error:
            session.immersiveSpaceStatus = .closed
            session.forestImmersiveState = .failed
            session.forestImmersiveStatus = "Mixed room scene failed."
            session.statusMessage = "Could not open Story HUD."
            return false

        @unknown default:
            session.immersiveSpaceStatus = .closed
            session.forestImmersiveState = .failed
            session.forestImmersiveStatus = "Mixed room scene failed: \(String(describing: result))"
            session.statusMessage = "Unknown immersive-space result."
            return false
        }
    }

    private func finishBigMikeDictationAndSend() {
        guard qwenNativeRunningPreset == nil,
              turingDialogueBusy == false else {
            return
        }

        dictationPressActive = false

        guard dictationCoordinator.isRecording else {
            dictationStartTask?.cancel()
            dictationStartTask = nil
            return
        }

        dictationStartTask = nil
        radioStaticLeadIn.start(reason: "askBigMikeMicReleased")

        Task {
            do {
                let transcript = try await dictationCoordinator.endHoldToSend()
                runBigMikeConversationNoBible(playerDictation: transcript)
            } catch {
                radioStaticLeadIn.stop(reason: "dictationFailed")
                session.publishTuringDictationEvent(.failed(error.localizedDescription))
                qwenDebugStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func runBigMikeConversationNoBible(
        playerDictation: String
    ) {
        guard turingDialogueBusy == false else {
            return
        }

        turingDialogueBusy = true
        qwenDebugStatus = "Running Big Mike conversation"
        session.publishTuringDictationEvent(
            .processingStarted(finalTranscript: playerDictation)
        )

        Task.detached(priority: .userInitiated) {
            do {
                let context = await TuringConversationSeedStore.shared.context(
                    for: "big_mike"
                )
                let request = ConversationPromptNoBibleRequest(
                    id: "story.picker.phase3light.conversation.001",
                    speaker: "Big Mike",
                    voiceID: "big_mike_base_clone_v1",
                    voiceVariantID: "broadcast_reading_lazy",
                    characterProfileID: "big_mike",
                    playerDictation: playerDictation,
                    episodeStateForWordsOnly: "Rich is checking in with Big Mike during the early Gravitas Plague emergency. Big Mike is nearby, protective, tired, and trying to keep Rich calm and alive.",
                    emotion: "protective, grounded, tired",
                    prerecordingTranscript: context.prerecordingTranscript,
                    lastVoicePromptSeed: context.lastVoicePromptSeed
                )
                let service = TuringDialogueService()
                let plan = try await service.generateConversationNoBible(
                    request
                )
                let result = await TuringNativeQwenHelloWorldCanary
                    .runDialogueSegments(
                        plan.segments,
                        runID: "bigMikeConversationNoBible",
                        source: "conversationPrompt_playerTurn_noBible",
                        onFirstSegmentReady: {
                            session.publishTuringDictationEvent(
                                .responseSegmentZeroReady(clearAfterSeconds: 2.0)
                            )
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                        }
                    )

                await MainActor.run {
                    session.publishTuringDictationEvent(.responseAudioFinished)
                    radioStaticLeadIn.stop(reason: "responseAudioFinished")
                    turingDialogueBusy = false
                    qwenDebugStatus = result.pickerStatus
                }
            } catch {
                await MainActor.run {
                    turingDialogueBusy = false
                    radioStaticLeadIn.stop(reason: "conversationFailed")
                    session.publishTuringDictationEvent(.failed(error.localizedDescription))
                    qwenDebugStatus = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private enum KnownQwenButtonProminence {
        case standard
        case prominent
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
