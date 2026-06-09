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
        case prepareForUserQuitOrClose
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
    @Published var isPosterUIVisible = true
    @Published var isQuitting = false
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
        selectedOperationMode = mode
        isPosterUIVisible = true

        print(
            """
            [PlagueMenu] selected operation mode
              mode: \(mode.rawValue)
              posterRemainsVisible: true
              legacyUIShown: false
            """
        )

        switch mode {
        case .horde:
            startHordeBenchmarkFromPoster()

        case .walkLoop:
            startWalkLoopFromPoster()
        }
    }

    func startHordeBenchmarkFromPoster() {
        selectedOperationMode = .horde
        isPosterUIVisible = true
        activeMode = .jockRetargetTest
        statusMessage = "Running Horde Mode."
        resetPlayerDeathState()
        send(.playJockFollowDemo)

        print("[PlagueMenu] Horde Mode started from poster UI; poster remains mounted.")
    }

    func startWalkLoopFromPoster() {
        selectedOperationMode = .walkLoop
        isPosterUIVisible = true
        activeMode = .jockRetargetTest
        statusMessage = "Running walk loop."
        resetPlayerDeathState()
        startWalkLoopMode()
        send(.playJockPacingLoop)

        print("[PlagueMenu] Walk Loop started from poster UI; poster remains mounted.")
    }

    func startWalkLoopMode() {
        print("[PlagueMenu] Walk Loop selected. Starting existing JockAsset pacing loop.")
    }

    func returnToOperationMenu() {
        stopWalkLoopMode()
        send(.closeDemo)

        selectedOperationMode = nil
        isPosterUIVisible = true
        activeMode = .none
        statusMessage = "Select operation mode."

        print("[PlagueMenu] returned to operation menu")
    }

    func notePosterUIMounted() {
        isPosterUIVisible = true

        print(
            """
            [PlagueMenu] poster UI mounted
              selectedOperationMode: \(selectedOperationMode?.rawValue ?? "none")
              posterRemainsVisible: true
            """
        )
    }

    func prepareForUserQuitOrClose() {
        shutdownForQuit(
            reason: "explicit_prepare_for_user_quit_or_close"
        )
    }

    func shutdownForQuit(
        reason: String
    ) {
        if isQuitting {
            return
        }

        isQuitting = true

        print(
            """
            [PlagueQuit] shutdown requested
              reason: \(reason)
              selectedOperationMode: \(selectedOperationMode?.rawValue ?? "none")
            """
        )

        stopHordeBenchmarkForQuit()
        stopWalkLoopForQuit()
        statusMessage = "Closing."
        activeMode = .none
        send(.prepareForUserQuitOrClose)
        cancelRuntimeTasksForQuit()
        stopAudioForQuit()

        UserDefaults.standard.set(
            Date(),
            forKey: "lastExitDate"
        )

        print("[PlagueQuit] shutdown complete")
    }

    func resetPlayerDeathState() {
        damageTintIntensity = 0.0
        damageTintEventID = UUID()
    }

    func stopHordeBenchmarkForQuit() {
        send(.stopJockFollowDemo)

        print("[PlagueQuit] Horde stopped")
    }

    func stopWalkLoopForQuit() {
        print("[PlagueQuit] Walk Loop stopped")
    }

    func cancelRuntimeTasksForQuit() {
        print("[PlagueQuit] runtime tasks cancelled")
    }

    func stopAudioForQuit() {
        print("[PlagueQuit] audio stopped")
    }

    func stopWalkLoopMode() {
        print("[PlagueMenu] Walk Loop stopped.")
    }

    func triggerDamageTint(intensity: Double) {
        damageTintIntensity = max(0.0, min(intensity, 1.0))
        damageTintEventID = UUID()
    }
}
