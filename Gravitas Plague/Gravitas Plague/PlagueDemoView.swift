import Foundation
import SwiftUI

struct PlagueDemoView: View {
    @ObservedObject var session: PlagueDemoSession

    var body: some View {
        PlagueOperationModePosterRoot(session: session)
            .onAppear {
                PlagueMenuAssetValidator.validate()
                loadJockManifestForUI()
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
        } catch {
            session.availableJockClips = []
            session.selectedJockClipID = nil

            print("[PlagueUI] ERROR failed to load JockAnim manifest: \(error.localizedDescription)")
        }
    }
}
