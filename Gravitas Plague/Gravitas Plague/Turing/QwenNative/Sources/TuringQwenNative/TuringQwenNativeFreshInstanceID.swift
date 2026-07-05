import Foundation

public struct TuringQwenNativeFreshInstanceID: Sendable, Hashable, CustomStringConvertible {
    public let index: Int

    public init(index: Int) {
        self.index = index
    }

    public var rawValue: String {
        "fresh-\(index)"
    }

    public var description: String {
        rawValue
    }
}
