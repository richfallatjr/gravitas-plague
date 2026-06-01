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

                Text("Presence Demo")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text("The infected appears in your room, turns toward you, walks forward, stops, turns away, and walks back.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text(session.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    Task {
                        await openAndStartDemo()
                    }
                } label: {
                    Text(startButtonTitle)
                        .frame(minWidth: 120)
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.immersiveSpaceStatus == .opening)

                Button {
                    session.send(.resetDemo)
                    session.statusMessage = "Resetting infected loop."
                } label: {
                    Text("Reset")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.bordered)
                .disabled(session.immersiveSpaceStatus != .open)

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

    private func openAndStartDemo() async {
        switch session.immersiveSpaceStatus {
        case .closed:
            session.immersiveSpaceStatus = .opening
            session.statusMessage = "Opening mixed-reality demo."

            let result = await openImmersiveSpace(id: PlagueDemoSession.immersiveSpaceID)

            switch result {
            case .opened:
                session.immersiveSpaceStatus = .open
                session.statusMessage = "Presence demo running."
                session.send(.startDemo)

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
            session.statusMessage = "Restarting presence demo."
            session.send(.startDemo)
        }
    }

    private func closeDemo() async {
        guard session.immersiveSpaceStatus == .open else { return }

        session.send(.closeDemo)
        await dismissImmersiveSpace()

        session.immersiveSpaceStatus = .closed
        session.statusMessage = "Demo closed."
    }
}
