import SwiftUI

struct TuringEpisodePickerView: View {
    @ObservedObject var session: PlagueDemoSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @State private var openingEpisodeID: TuringEpisodeID?
    @State private var selectedEpisodeID: TuringEpisodeID? = .prologue
#if DEBUG || GR_TURING_DIAGNOSTICS
    @ObservedObject private var turingFlowGate =
        TuringFlowInteractionGateController.shared
    @StateObject private var dictationCoordinator = TuringDictationCoordinator()
    @StateObject private var radioStaticLeadIn = TuringRadioStaticLeadInController()
    @State private var qwenNativeRunningPreset: TuringNativeQwenVoiceDesignCanaryPreset?
    @State private var turingDialogueBusy = false
    @State private var dictationPressActive = false
    @State private var dictationStartTask: Task<Void, Never>?
    @State private var dictationInteractionLease: StoryInteractionLease?
    @State private var dictationRecordingRunID: UUID?
    @State private var qwenDebugStatus = "Idle"
    @State private var roomScanRequestStarting = false
    @State private var roomScanAttempt = 0
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
            Divider()
                .padding(.vertical, 4)

            Button {
                startChapter03LightTunnelTest()
            } label: {
                Label(
                    "Start Chapter 3 - Light Tunnel Test",
                    systemImage: "light.max"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(openingEpisodeID != nil)

            Button {
                runStoryRoomScanAgain()
            } label: {
                HStack(spacing: 8) {
                    if roomScanRequestStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }

                    Text(
                        roomScanRequestStarting
                            ? "Opening Room Scan..."
                            : "Run Room Scan Again"
                    )
                }
            }
            .buttonStyle(.bordered)
            .disabled(roomScanRequestStarting)

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

                    Button {
                        runScriptPoint02()
                    } label: {
                        HStack(spacing: 8) {
                            if turingDialogueBusy {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text("Run ScriptPoint02")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        qwenNativeRunningPreset != nil ||
                        turingDialogueBusy
                    )

                    Divider()
                        .padding(.vertical, 4)

                    HStack(spacing: 12) {
                        TuringDictateButton(
                            isRecording: dictationCoordinator.isRecording,
                            isBusy: qwenNativeRunningPreset != nil ||
                                turingDialogueBusy ||
                                !turingFlowGate.microphoneEnabled,
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
    private func startChapter03LightTunnelTest() {
        guard openingEpisodeID == nil else { return }
        openingEpisodeID = .chapter03
        Task { @MainActor in
            defer { openingEpisodeID = nil }
            guard await ensureImmersiveSpaceForTuringHUD(
                reason: "chapter03LightTunnelTest"
            ) else {
                qwenDebugStatus = "Failed: immersive space unavailable"
                return
            }
            let request = StoryTitleCardTransitionRequest(
                requestID: UUID(),
                source: .episodePickerStart,
                descriptor: StoryTitleCardCatalog.chapter03LightTunnelTest,
                destination: .start(.chapter03),
                menuMusicPolicy: .playThroughCard
            )
            session.requestStoryTitleCardTransition(request)
            dismiss()
        }
    }

    private func runStoryRoomScanAgain() {
        guard !roomScanRequestStarting else {
            return
        }

        roomScanRequestStarting = true

        Task { @MainActor in
            defer {
                roomScanRequestStarting = false
            }

            guard await ensureImmersiveSpaceForTuringHUD(
                reason: "debugRoomScanAgain"
            ) else {
                qwenDebugStatus = "Failed: immersive space unavailable for room scan"
                return
            }

            roomScanAttempt += 1
            let reason = "storyDebugUI.attempt.\(roomScanAttempt)"
            qwenDebugStatus = "Room scan attempt \(roomScanAttempt) started"

            print("""
            [TuringRoomScanDebug] repeat requested
              uiAttempt: \(roomScanAttempt)
              reason: \(reason)
              immersiveSpaceStatus: open
            """)

            session.send(
                .restartTuringStoryPlacementRoomScan(reason)
            )
        }
    }

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

            session.send(
                .requestTuringStoryPlacementRoomScan(
                    "qwenTestButton.\(preset.rawValue)"
                )
            )
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
        session.send(
            .requestTuringStoryPlacementRoomScan(
                "qwenTestButton.gravitasPlagueBackstory"
            )
        )
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
        session.send(
            .requestTuringStoryPlacementRoomScan(
                "qwenTestButton.bigMikeRichContactPrerecordingSeed"
            )
        )
        Task.detached(priority: .userInitiated) {
            await TuringEpisodeFlowController.shared.resetEpisode(
                reason: "debugScriptPoint01"
            )
            let result = await TuringPrerecordingSeededPromptRunner
                .runBigMikeRichContact(
                    inputStore: TuringConversationInputStore.shared
                )

            await MainActor.run {
                turingDialogueBusy = false
                qwenDebugStatus = result.pickerStatus
            }
        }
    }

    private func runScriptPoint02() {
        guard qwenNativeRunningPreset == nil,
              turingDialogueBusy == false else {
            return
        }

        turingDialogueBusy = true
        qwenDebugStatus = "Running ScriptPoint02"

        session.send(
            .requestTuringStoryPlacementRoomScan(
                "qwenTestButton.scriptPoint02"
            )
        )

        Task.detached(priority: .userInitiated) {
            await TuringEpisodeFlowController.shared.resetEpisode(
                reason: "debugScriptPoint02"
            )
            let result = await TuringEpisodeFlowController.shared.start(
                scriptPointID: "prologue.scriptPoint02",
                trigger: .manualDebug,
                allowExplicitReplay: true
            )

            await MainActor.run {
                turingDialogueBusy = false
                qwenDebugStatus = result.pickerStatus
            }
        }
    }

    private func startBigMikeDictation() {
        guard turingFlowGate.microphoneEnabled else {
            print("""
            [TuringFlowGate] microphone request ignored
              reason: interactionGateClosed
              state: \(turingFlowGate.state.rawValue)
            """)
            return
        }
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

            let recordingRunID = UUID()
            let interactionLease: StoryInteractionLease
            do {
                interactionLease =
                    try await TuringHighMemoryPreflightCoordinator
                        .shared
                        .acquireInteractionLease(
                            runID:
                                "conversation.\(recordingRunID.uuidString)",
                            source:
                                "storyDebugUI.microphoneHold",
                            mode:
                                .manual
                        )
            } catch {
                dictationPressActive = false
                let snapshot =
                    await StoryInteractionArbiter.shared
                        .currentSnapshot()
                print("""
                [TuringConversationFailure] debug microphone lease acquisition failed
                  currentOwner: \(snapshot.exclusiveOwner?.logValue ?? "none")
                  turingGate: \(snapshot.turingGate.rawValue)
                  doorState: \(snapshot.doorState.rawValue)
                  capabilities: \(snapshot.capabilities.map(\.rawValue).sorted())
                  errorType: \(String(reflecting: type(of: error)))
                  error: \(error.localizedDescription)
                """)
                session.publishTuringDictationEvent(
                    .failed(error.localizedDescription)
                )
                qwenDebugStatus =
                    "Failed: \(error.localizedDescription)"
                return
            }

            guard dictationPressActive,
                  Task.isCancelled == false else {
                await StoryInteractionArbiter.shared.release(
                    interactionLease,
                    reason:
                        "debugHoldEndedBeforeLeaseUse"
                )
                return
            }

            dictationInteractionLease =
                interactionLease
            dictationRecordingRunID =
                recordingRunID
            turingFlowGate.beginConversation(
                conversationRunID:
                    recordingRunID
            )

            session.send(
                .requestTuringStoryPlacementRoomScan(
                    "holdMicDictation"
                )
            )

            await TuringWalkieCommsFXController.shared
                .playOpenCommBeforeRecording(reason: "holdToRecordStarted")

            guard dictationPressActive else {
                await dictationCoordinator.cancel(
                    reason: "press ended before open comm finished"
                )
                dictationInteractionLease = nil
                dictationRecordingRunID = nil
                await StoryInteractionArbiter.shared.release(
                    interactionLease,
                    reason:
                        "debugHoldEndedBeforeRecording"
                )
                turingFlowGate
                    .restoreMicrophoneAfterConversation(
                        conversationRunID:
                            recordingRunID
                    )
                return
            }

            await dictationCoordinator.beginHoldToRecord()

            if !dictationPressActive,
               dictationCoordinator.isRecording {
                await dictationCoordinator.cancel(
                    reason: "press ended before recording startup completed"
                )
                dictationInteractionLease = nil
                dictationRecordingRunID = nil
                await StoryInteractionArbiter.shared.release(
                    interactionLease,
                    reason:
                        "debugHoldEndedDuringRecordingStartup"
                )
                turingFlowGate
                    .restoreMicrophoneAfterConversation(
                        conversationRunID:
                            recordingRunID
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
            let interactionLease =
                dictationInteractionLease
            let recordingRunID =
                dictationRecordingRunID
            dictationInteractionLease = nil
            dictationRecordingRunID = nil
            Task {
                if let interactionLease {
                    await StoryInteractionArbiter.shared.release(
                        interactionLease,
                        reason:
                            "debugHoldEndedBeforeRecording"
                    )
                }
                if let recordingRunID {
                    turingFlowGate
                        .restoreMicrophoneAfterConversation(
                            conversationRunID:
                                recordingRunID
                        )
                }
            }
            return
        }

        dictationStartTask = nil
        guard let interactionLease =
                dictationInteractionLease else {
            Task {
                await dictationCoordinator.cancel(
                    reason:
                        "debugConversationLeaseMissing"
                )
            }
            session.publishTuringDictationEvent(
                .failed(
                    "Conversation interaction lease is missing."
                )
            )
            qwenDebugStatus =
                "Failed: Conversation interaction lease is missing."
            return
        }
        dictationInteractionLease = nil
        dictationRecordingRunID = nil

        Task {
            do {
                let transcript = try await dictationCoordinator.endHoldToSend()
                await TuringWalkieCommsFXController.shared
                    .playSendCommAndStartSendingLeadIn(
                        reason: "dictationReleased"
                    )
                runBigMikeConversationNoBible(
                    playerDictation:
                        transcript,
                    interactionLease:
                        interactionLease
                )
            } catch {
                await StoryInteractionArbiter.shared.release(
                    interactionLease,
                    reason:
                        "debugDictationFailedBeforeConversation"
                )
                await TuringWalkieCommsFXController.shared.stopSendingLeadIn(
                    reason: "dictationFailed"
                )
                await TuringWalkieCommsFXController.shared.stopAmbientWalkieStatic(
                    reason: "dictationFailed"
                )
                radioStaticLeadIn.stop(reason: "dictationFailed")
                session.publishTuringDictationEvent(.failed(error.localizedDescription))
                qwenDebugStatus = "Failed: \(error.localizedDescription)"
            }
        }
    }

    private func runBigMikeConversationNoBible(
        playerDictation: String,
        interactionLease: StoryInteractionLease
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
            let result = await TuringBigMikeConversationRunner.run(
                playerDictation: playerDictation,
                interactionLease: interactionLease,
                inputStore: TuringConversationInputStore.shared,
                onSegmentZeroReady: {
                    session.publishTuringDictationEvent(
                        .responseSegmentZeroReady(
                            clearAfterSeconds: 2.0
                        )
                    )
                }
            )

            if result.succeeded {
                await MainActor.run {
                    session.publishTuringDictationEvent(
                        .responseAudioFinished
                    )
                    radioStaticLeadIn.stop(
                        reason: "responseAudioFinished"
                    )
                    turingDialogueBusy = false
                    qwenDebugStatus = result.pickerStatus
                }
            } else {
                await MainActor.run {
                    turingDialogueBusy = false
                    radioStaticLeadIn.stop(
                        reason: "conversationFailed"
                    )
                    qwenDebugStatus = result.pickerStatus
                    session.publishTuringDictationEvent(
                        .responseFailed(
                            result.pickerStatus
                        )
                    )
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

        await TuringEpisodeFlowController.shared.resetEpisode(
            reason: "startStoryEpisode.\(episode.id.rawValue)"
        )
        session.startStoryEpisode(
            episode.id
        )
        dismiss()
    }

}
