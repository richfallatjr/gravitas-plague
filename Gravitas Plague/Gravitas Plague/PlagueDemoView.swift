import SwiftUI

struct PlagueDemoView: View {
    @ObservedObject var session: PlagueDemoSession

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Gravitas Plague")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Presence Demo / Jock Retarget Test")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Text(session.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    Task {
                        await openIfNeededAndSend(.startBakedUSDZDemo)
                    }
                } label: {
                    Text(startButtonTitle)
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.immersiveSpaceStatus == .opening)

                Button {
                    Task {
                        await openIfNeededAndSend(.startJockRetargetTest)
                    }
                } label: {
                    Text("Retarget")
                        .frame(minWidth: 100)
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
                    Text("Jock Test Controls")
                        .font(.headline)

                    Toggle("Loop Dummy", isOn: Binding(
                        get: { session.jockLoopEnabled },
                        set: { newValue in
                            session.jockLoopEnabled = newValue
                            session.send(.setJockLoop(newValue))
                        }
                    ))

                    HStack(spacing: 12) {
                        Button("Play Dummy") {
                            session.send(.playJockDummy)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Stop Dummy") {
                            session.send(.stopJockDummy)
                        }
                        .buttonStyle(.bordered)

                        Button("Reset Pose") {
                            session.send(.resetJockPose)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(28)
    }

    private var startButtonTitle: String {
        switch session.immersiveSpaceStatus {
        case .closed:
            return "Start Demo"
        case .opening:
            return "Opening..."
        case .open:
            return "Restart Demo"
        }
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
        case .startBakedUSDZDemo:
            session.activeMode = .bakedUSDZDemo
            session.statusMessage = "Running baked USDZ switching demo."
            session.send(.startBakedUSDZDemo)

        case .startJockRetargetTest:
            session.activeMode = .jockRetargetTest
            session.statusMessage = "Running Jock Retarget skeletal-driver test."
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
        session.statusMessage = "Demo closed."
    }
}
