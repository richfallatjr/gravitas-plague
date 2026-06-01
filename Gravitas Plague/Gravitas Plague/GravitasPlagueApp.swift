import SwiftUI

@main
struct GravitasPlagueApp: App {
    @StateObject private var demoSession = PlagueDemoSession()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup {
            PlagueDemoView(session: demoSession)
                .frame(minWidth: 805, minHeight: 630)
        }
        .defaultSize(width: 805, height: 630)

        ImmersiveSpace(id: PlagueDemoSession.immersiveSpaceID) {
            PlagueImmersiveView(session: demoSession)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}
