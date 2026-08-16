import Foundation

extension Chapter03LightTunnelMusicController {
    enum Event: Sendable, Equatable {
        case prepared(durationSeconds: Double)
        case started
        case mediaTime(seconds: Double, durationSeconds: Double)
        case completed
        case failed(String)
    }
}
