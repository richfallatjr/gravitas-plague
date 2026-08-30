import Foundation

public actor TuringQwenRenderReleaseLedger {
    private var released = Set<TuringQwenRenderReleaseToken>()

    public init() {}

    public func record(_ token: TuringQwenRenderReleaseToken) {
        released.insert(token)
    }

    public func requireReleased(_ token: TuringQwenRenderReleaseToken) throws {
        guard released.contains(token) else {
            throw TuringQwenNativeError.invalidConfig(
                "Decode attempted before render release for segment \(token.segmentIndex)."
            )
        }
    }

    public func clearRun(_ runID: String) {
        released = released.filter { $0.runID != runID }
    }

    public func isRunClear(_ runID: String) -> Bool {
        released.contains { $0.runID == runID } == false
    }
}
