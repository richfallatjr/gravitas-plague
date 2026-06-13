import SwiftUI

@main
struct GravitasPlagueApp: App {
    @StateObject private var demoSession = PlagueDemoSession()
    @State private var immersionStyle: ImmersionStyle = .full

    var body: some Scene {
        WindowGroup(id: "plague-control") {
            PlagueDemoView(session: demoSession)
                .frame(minWidth: 543, minHeight: 724)
        }
        .defaultSize(width: 815, height: 1086)

        ImmersiveSpace(id: PlagueDemoSession.immersiveSpaceID) {
            PlagueImmersiveView(session: demoSession)
        }
        .immersionStyle(selection: $immersionStyle, in: .full)
    }
}
