import Foundation

public struct TuringQwenNativeBaseClonePrompt: Sendable {
    public let text: String
    public let language: String
    public let cloneProfile: TuringQwenNativeCloneProfile
    public let maxNewRows: Int
    public let performanceMode: TuringQwenNativePerformanceMode

    public init(
        text: String,
        language: String,
        cloneProfile: TuringQwenNativeCloneProfile,
        maxNewRows: Int = 38,
        performanceMode: TuringQwenNativePerformanceMode = .performance
    ) {
        self.text = text
        self.language = language
        self.cloneProfile = cloneProfile
        self.maxNewRows = maxNewRows
        self.performanceMode = performanceMode
    }
}
