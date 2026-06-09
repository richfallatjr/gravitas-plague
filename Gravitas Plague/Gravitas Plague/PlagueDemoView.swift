import Foundation
import SwiftUI

struct PlagueDemoView: View {
    @ObservedObject var session: PlagueDemoSession
    @State private var manifestLoadError: String?

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        Group {
            if session.isShowingOperationModeMenu {
                PlagueOperationModePosterMenu(session: session)
            } else {
                gameplayControlPanel
            }
        }
        .onAppear {
            PlagueMenuAssetValidator.validate()
            loadJockManifestForUI()
        }
    }

    private var gameplayControlPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gravitas Plague")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Character assets are not final. Only placeholders to simulate game mechanics.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(session.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("Operation Menu") {
                    Task {
                        await returnToOperationMenu()
                    }
                }
                .buttonStyle(.bordered)
                .disabled(session.immersiveSpaceStatus == .opening)

                Button {
                    Task {
                        await closeDemo()
                    }
                } label: {
                    Text("Close Demo")
                        .frame(minWidth: 110)
                }
                .buttonStyle(.bordered)
                .disabled(session.immersiveSpaceStatus != .open)
            }

            if session.activeMode == .jockRetargetTest {
                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text(session.selectedOperationMode?.displayName ?? "Operation Mode")
                        .font(.headline)

                    Text("JockAsset Animation Library")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let manifestLoadError {
                        Text(manifestLoadError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if session.availableJockClips.isEmpty {
                        Text("No runtime-approved JockAsset clips found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Preview Clip", selection: Binding(
                            get: {
                                session.selectedJockClipID
                                    ?? session.availableJockClips.first?.clipID
                                    ?? ""
                            },
                            set: { newValue in
                                session.selectedJockClipID = newValue
                            }
                        )) {
                            ForEach(session.availableJockClips) { clip in
                                Text(clip.displayName)
                                    .tag(clip.clipID)
                            }
                        }

                        if let selected = session.availableJockClips.first(
                            where: { $0.clipID == session.selectedJockClipID }
                        ) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(selected.clipID)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(
                                    selected.clipType == "sub_animation_override"
                                        ? "Type: Sub Override"
                                        : "Type: Full Body"
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)

                                Text("Category: \(selected.category.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                Text("Duration: \(String(format: "%.2f", selected.durationSeconds))s")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)

                                if selected.locomotionEnabled == true {
                                    Text("Locomotion")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    Toggle("Loop Selected Clip", isOn: $session.jockPickerLoopEnabled)

                    HStack(spacing: 12) {
                        Button("Play") {
                            if let clipID = session.selectedJockClipID {
                                session.statusMessage = session.jockPickerLoopEnabled
                                    ? "Looping selected JockAsset clip."
                                    : "Playing selected JockAsset clip."
                                session.send(
                                    .playJockClip(
                                        clipID,
                                        loop: session.jockPickerLoopEnabled
                                    )
                                )
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(session.selectedJockClipID == nil)

                        Button("Stop") {
                            session.statusMessage = "JockAsset playback stopped."
                            session.send(.stopJockClip)
                        }
                        .buttonStyle(.bordered)

                        Button("Reset Pose") {
                            session.statusMessage = "Resetting JockAsset pose."
                            session.send(.resetJockPose)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(28)
    }

    private func openIfNeededAndSend(_ command: PlagueDemoSession.Command) async {
        switch session.immersiveSpaceStatus {
        case .closed:
            session.immersiveSpaceStatus = .opening
            session.statusMessage = "Opening mixed-reality space."

            let result = await openImmersiveSpace(id: PlagueDemoSession.immersiveSpaceID)

            switch result {
            case .opened:
                session.immersiveSpaceStatus = .open
                sendAndUpdateStatus(command)

            case .userCancelled:
                session.immersiveSpaceStatus = .closed
                session.statusMessage = "Immersive space was not opened."

            case .error:
                session.immersiveSpaceStatus = .closed
                session.statusMessage = "Could not open immersive space."

            @unknown default:
                session.immersiveSpaceStatus = .closed
                session.statusMessage = "Unknown immersive-space result."
            }

        case .opening:
            return

        case .open:
            sendAndUpdateStatus(command)
        }
    }

    private func sendAndUpdateStatus(_ command: PlagueDemoSession.Command) {
        switch command {
        case .startJockRetargetTest:
            loadJockManifestForUI()
            session.activeMode = .jockRetargetTest
            session.statusMessage = "JockAsset demo ready."
            session.send(.startJockRetargetTest)

        default:
            session.send(command)
        }
    }

    private func closeDemo() async {
        guard session.immersiveSpaceStatus == .open else { return }

        session.send(.closeDemo)
        await dismissImmersiveSpace()

        session.immersiveSpaceStatus = .closed
        session.activeMode = .none
        session.selectedOperationMode = nil
        session.isShowingOperationModeMenu = true
        session.statusMessage = "Demo closed."
    }

    private func returnToOperationMenu() async {
        session.returnToOperationMenu()

        if session.immersiveSpaceStatus == .open {
            await dismissImmersiveSpace()
            session.immersiveSpaceStatus = .closed
        }
    }

    private func loadJockManifestForUI() {
        do {
            let manifest = try JockAnimationLibraryLoader.loadManifest()
            let clips = manifest.clips.filter { $0.approvedForRuntime }

            session.availableJockClips = clips

            if session.selectedJockClipID == nil
                || !clips.contains(where: { $0.clipID == session.selectedJockClipID }) {
                session.selectedJockClipID = clips.first?.clipID
            }

            manifestLoadError = nil
        } catch {
            session.availableJockClips = []
            session.selectedJockClipID = nil
            manifestLoadError = error.localizedDescription
        }
    }
}
