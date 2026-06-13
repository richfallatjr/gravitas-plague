import Foundation
import Combine
import Darwin
import SwiftUI

enum PlagueForestImmersiveState: String, Codable {
    case closed
    case opening
    case open
    case closing
    case failed
}

@MainActor
final class PlagueDemoSession: ObservableObject {
    static let immersiveSpaceID = PlagueImmersiveSpaceID.forest

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
    @Published var forestImmersiveState: PlagueForestImmersiveState = .closed
    @Published var forestAtmosphere: PlagueForestAtmosphere = .overcast
    @Published var forestAtmosphereRevision: Int = 0
    @Published var forestImmersiveStatus = "Forest immersive closed."
    @Published var damageTintEventID = UUID()
    @Published var damageTintIntensity: Double = 0.0
    @Published private(set) var latestCommand: CommandEnvelope?

    private var controlWindowBackgroundIgnoreUntil: Date?

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

    func toggleForestAtmosphere() {
        forestAtmosphere = forestAtmosphere.next
        forestAtmosphereRevision &+= 1
        forestImmersiveStatus = "Atmosphere changed to \(forestAtmosphere.displayName)."

        print(
            """
            [PlagueForest] atmosphere toggled
              atmosphere: \(forestAtmosphere.rawValue)
              ply: \(forestAtmosphere.gaussianSplatResourceName).\(forestAtmosphere.gaussianSplatFileExtension)
              hdri: \(forestAtmosphere.hdriResourceName).\(forestAtmosphere.hdriFileExtension)
              revision: \(forestAtmosphereRevision)
            """
        )
    }

    func toggleForestImmersive(
        openImmersiveSpace: OpenImmersiveSpaceAction,
        dismissImmersiveSpace: DismissImmersiveSpaceAction
    ) async {
        switch forestImmersiveState {
        case .closed, .failed:
            forestImmersiveState = .opening
            immersiveSpaceStatus = .opening
            forestImmersiveStatus = "Opening forest immersive..."
            markControlWindowBackgroundAsImmersiveTransition(
                reason: "forest_open_requested"
            )

            print(
                """
                [PlagueForest] opening immersive space
                  id: \(PlagueImmersiveSpaceID.forest)
                  atmosphere: \(forestAtmosphere.rawValue)
                """
            )

            let result = await openImmersiveSpace(
                id: PlagueImmersiveSpaceID.forest
            )

            switch result {
            case .opened:
                forestImmersiveState = .open
                immersiveSpaceStatus = .open
                forestImmersiveStatus = "Forest immersive open."
                markControlWindowBackgroundAsImmersiveTransition(
                    reason: "forest_opened"
                )

                print("[PlagueForest] immersive opened")

            case .userCancelled:
                forestImmersiveState = .closed
                immersiveSpaceStatus = .closed
                forestImmersiveStatus = "Forest immersive cancelled."

                print("[PlagueForest] immersive open cancelled")

            case .error:
                forestImmersiveState = .failed
                immersiveSpaceStatus = .closed
                forestImmersiveStatus = "Forest immersive failed."

                print("[PlagueForest] immersive open failed")

            @unknown default:
                forestImmersiveState = .failed
                immersiveSpaceStatus = .closed
                forestImmersiveStatus = "Forest immersive failed: \(String(describing: result))"

                print("[PlagueForest] immersive open unknown result \(String(describing: result))")
            }

        case .open:
            forestImmersiveState = .closing
            forestImmersiveStatus = "Closing forest immersive..."
            markControlWindowBackgroundAsImmersiveTransition(
                reason: "forest_close_requested"
            )

            print("[PlagueForest] dismissing immersive space")

            await dismissImmersiveSpace()

            forestImmersiveState = .closed
            immersiveSpaceStatus = .closed
            forestImmersiveStatus = "Forest immersive closed."

            print("[PlagueForest] immersive dismissed")

        case .opening, .closing:
            print(
                """
                [PlagueForest] immersive toggle ignored
                  state: \(forestImmersiveState.rawValue)
                """
            )
        }
    }

    func forestImmersiveDidOpen() {
        forestImmersiveState = .open
        immersiveSpaceStatus = .open
        forestImmersiveStatus = "Forest immersive open."
        markControlWindowBackgroundAsImmersiveTransition(
            reason: "forest_view_appeared"
        )
    }

    func forestImmersiveDidClose() {
        if forestImmersiveState == .failed {
            immersiveSpaceStatus = .closed

            print("[PlagueForest] immersive did close after strict splat failure")
            return
        }

        forestImmersiveState = .closed
        immersiveSpaceStatus = .closed
        forestImmersiveStatus = "Forest immersive closed."

        print("[PlagueForest] immersive did close")
    }

    private func markControlWindowBackgroundAsImmersiveTransition(
        reason: String
    ) {
        controlWindowBackgroundIgnoreUntil = Date().addingTimeInterval(2.0)

        print(
            """
            [PlagueQuit] armed transient background ignore
              reason: \(reason)
              seconds: 2.0
            """
        )
    }

    func closeForestImmersiveBecauseSplatFailed(
        error: Error
    ) {
        forestImmersiveState = .failed
        immersiveSpaceStatus = .closed
        forestImmersiveStatus = "Forest immersive failed: \(error.localizedDescription)"

        print(
            """
            [PlagueForest] closing immersive because strict splat atmosphere failed
              error: \(error.localizedDescription)
              noFallback: true
            """
        )
    }

    @discardableResult
    func handleControlWindowSceneBackgrounded() -> Bool {
        if forestImmersiveState == .opening ||
           forestImmersiveState == .closing {
            print(
                """
                [PlagueQuit] ignored control window background during forest immersive transition
                  forestImmersiveState: \(forestImmersiveState.rawValue)
                  reason: immersive_transition
                """
            )

            return false
        }

        if let ignoreUntil = controlWindowBackgroundIgnoreUntil,
           Date() < ignoreUntil {
            print(
                """
                [PlagueQuit] ignored transient control window background
                  forestImmersiveState: \(forestImmersiveState.rawValue)
                  reason: recent_immersive_transition
                """
            )

            return false
        }

        controlWindowBackgroundIgnoreUntil = nil

        return true
    }

    func requestImmediateQuitFromControlWindow(
        reason: String
    ) {
        if isQuitting {
            print(
                """
                [PlagueQuit] immediate quit requested while already quitting
                  reason: \(reason)
                  forcingExit: true
                """
            )

            exit(0)
        }

        print(
            """
            [PlagueQuit] immediate quit requested
              reason: \(reason)
            """
        )

        shutdownForQuit(
            reason: reason
        )
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
        forestImmersiveState = .closing
        forestImmersiveStatus = "Closing forest immersive..."
        activeMode = .none
        send(.prepareForUserQuitOrClose)
        cancelRuntimeTasksForQuit()
        stopAudioForQuit()

        UserDefaults.standard.set(
            Date(),
            forKey: "lastExitDate"
        )

        forestImmersiveState = .closed
        immersiveSpaceStatus = .closed
        forestImmersiveStatus = "Forest immersive closed."

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
