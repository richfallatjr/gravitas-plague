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
        case bakedUSDZDemo
        case jockRetargetTest
    }

    enum Command: Equatable {
        case startBakedUSDZDemo
        case startJockRetargetTest
        case playJockDummy
        case stopJockDummy
        case resetJockPose
        case setJockLoop(Bool)
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
    @Published var statusMessage: String = "Start the demo or open Retarget."
    @Published var jockLoopEnabled: Bool = true
    @Published private(set) var latestCommand: CommandEnvelope?

    func send(_ command: Command) {
        latestCommand = CommandEnvelope(command)
    }
}
