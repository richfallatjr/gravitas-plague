import Foundation

public enum TuringQwenNativeReferenceWindowStrategy: String, Sendable {
    case full
    case prefix
    case suffix
}

public struct TuringQwenNativeBaseClonePrompt: Sendable {
    public let text: String
    public let language: String
    public let cloneProfile: TuringQwenNativeCloneProfile
    public let maxNewRows: Int
    public let performanceMode: TuringQwenNativePerformanceMode
    public let referenceRowLimit: Int?
    public let referenceWindowStrategy: TuringQwenNativeReferenceWindowStrategy

    public init(
        text: String,
        language: String,
        cloneProfile: TuringQwenNativeCloneProfile,
        maxNewRows: Int = 38,
        performanceMode: TuringQwenNativePerformanceMode = .performance,
        referenceRowLimit: Int? = nil,
        referenceWindowStrategy: TuringQwenNativeReferenceWindowStrategy = .full
    ) {
        self.text = text
        self.language = language
        self.cloneProfile = cloneProfile
        self.maxNewRows = maxNewRows
        self.performanceMode = performanceMode
        self.referenceRowLimit = referenceRowLimit
        self.referenceWindowStrategy = referenceWindowStrategy
    }
}
