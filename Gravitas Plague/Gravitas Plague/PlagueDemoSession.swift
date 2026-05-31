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

    enum Command: Equatable {
        case startDemo
        case resetDemo
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
    @Published var statusMessage: String = "Open the demo to begin."
    @Published private(set) var latestCommand: CommandEnvelope?

    func send(_ command: Command) {
        latestCommand = CommandEnvelope(command)
    }
}
