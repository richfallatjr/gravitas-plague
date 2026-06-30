import Foundation

public struct TuringQwenNativeBaseClonePrompt: Sendable {
    public let text: String
    public let language: String
    public let cloneProfile: TuringQwenNativeCloneProfile

    public init(
        text: String,
        language: String,
        cloneProfile: TuringQwenNativeCloneProfile
    ) {
        self.text = text
        self.language = language
        self.cloneProfile = cloneProfile
    }
}
