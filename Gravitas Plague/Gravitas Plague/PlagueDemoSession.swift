import Foundation
import Combine
import SwiftUI

@MainActor
final class PlagueDemoSession: ObservableObject {
    static let immersiveSpaceID = "GravitasPlaguePresenceDemoSpace"

    enum PlagueOperationMode: String, Codable, CaseIterable, Identifiable {
        case horde
        case walkLoop

        nonisolated var id: String { rawValue }

        nonisolated var displayName: String {
            switch self {
            case .horde:
                return "Horde Mode"

            case .walkLoop:
                return "Walk Loop"
            }
        }
    }

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
    @Published var selectedOperationMode: PlagueOperationMode?
    @Published var isShowingOperationModeMenu = true
    @Published var statusMessage: String = "Start the demo."
    @Published var selectedJockClipID: String?
    @Published var jockPickerLoopEnabled = false
    @Published var availableJockClips: [JockAnimationManifest.ClipSummary] = []
    @Published var damageTintEventID = UUID()
    @Published var damageTintIntensity: Double = 0.0
    @Published private(set) var latestCommand: CommandEnvelope?

    func send(_ command: Command) {
        latestCommand = CommandEnvelope(command)
    }

    func selectOperationMode(_ mode: PlagueOperationMode) {
        switch mode {
        case .horde:
            startHordeBenchmarkFromMenu()

        case .walkLoop:
            startWalkLoopFromMenu()
        }
    }

    func startHordeBenchmarkFromMenu() {
        selectedOperationMode = .horde
        isShowingOperationModeMenu = false
        activeMode = .jockRetargetTest
        statusMessage = "Running Horde Mode."
        send(.playJockFollowDemo)

        print("[PlagueMenu] selected operation mode: horde")
        print("[PlagueMenu] Horde Mode started from poster menu")
    }

    func startWalkLoopFromMenu() {
        selectedOperationMode = .walkLoop
        isShowingOperationModeMenu = false
        activeMode = .jockRetargetTest
        statusMessage = "Running walk loop."
        startWalkLoopMode()
        send(.playJockPacingLoop)

        print("[PlagueMenu] selected operation mode: walkLoop")
        print("[PlagueMenu] Walk Loop started from poster menu")
    }

    func startWalkLoopMode() {
        print("[PlagueMenu] Walk Loop selected. Starting existing JockAsset pacing loop.")
    }

    func returnToOperationMenu() {
        stopWalkLoopMode()
        send(.closeDemo)

        selectedOperationMode = nil
        isShowingOperationModeMenu = true
        activeMode = .none
        statusMessage = "Select operation mode."

        print("[PlagueMenu] returned to operation menu")
    }

    func stopWalkLoopMode() {
        print("[PlagueMenu] Walk Loop stopped.")
    }

    func triggerDamageTint(intensity: Double) {
        damageTintIntensity = max(0.0, min(intensity, 1.0))
        damageTintEventID = UUID()
    }
}
