import Foundation

public enum TuringQwenNativeLaneStreamMode: String, Sendable {
    case defaultOnly
}

public struct TuringQwenNativeLaneStream: Sendable {
    public let laneID: Int
    public let mode: TuringQwenNativeLaneStreamMode

    public init(
        laneID: Int,
        mode: TuringQwenNativeLaneStreamMode = .defaultOnly
    ) {
        self.laneID = laneID
        self.mode = mode
    }
}
