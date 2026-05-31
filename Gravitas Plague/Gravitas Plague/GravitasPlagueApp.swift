import SwiftUI

@main
struct GravitasPlagueApp: App {
    @StateObject private var demoSession = PlagueDemoSession()
    @State private var immersionStyle: ImmersionStyle = .mixed

    var body: some Scene {
        WindowGroup {
            PlagueDemoView(session: demoSession)
        }
        .defaultSize(width: 460, height: 360)

        ImmersiveSpace(id: PlagueDemoSession.immersiveSpaceID) {
            PlagueImmersiveView(session: demoSession)
        }
        .immersionStyle(selection: $immersionStyle, in: .mixed)
    }
}
