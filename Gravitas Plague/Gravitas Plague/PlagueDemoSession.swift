import Foundation
import Combine
import SwiftUI

@MainActor
final class PlagueDemoSession: ObservableObject {
    static let immersiveSpaceID = "GravitasPlaguePresenceDemoSpace"

    enum ImmersiveSpaceStatus: Equatable {
        case closed
        case opening
        case open
    }

    enum ActiveMode: Equatable {
        case none
        case jockRetargetTest
    }

    enum Command: Equatable {
        case startJockRetargetTest
        case playJockPacingLoop
        case playJockFollowDemo
        case stopJockFollowDemo
        case playJockClip(String, loop: Bool)
        case stopJockClip
        case resetJockPose
        case closeDemo
    }

    struct CommandEnvelope: Identifiable, Equatable {
        let id: UUID
        let command: Command

        init(_ command: Command) {
            self.id = UUID()
            self.command = command
        }
    }

    @Published var immersiveSpaceStatus: ImmersiveSpaceStatus = .closed
    @Published var activeMode: ActiveMode = .none
    @Published var statusMessage: String = "Start the demo."
    @Published var selectedJockClipID: String?
    @Published var jockPickerLoopEnabled = false
    @Published var availableJockClips: [JockAnimationManifest.ClipSummary] = []
    @Published var damageFlashToken = UUID()
    @Published var damageFlashIntensity: Float = 0
    @Published private(set) var latestCommand: CommandEnvelope?

    func send(_ command: Command) {
        latestCommand = CommandEnvelope(command)
    }

    func triggerDamageFlash(intensity: Float) {
        damageFlashIntensity = max(0, min(intensity, 1))
        damageFlashToken = UUID()
    }
}
