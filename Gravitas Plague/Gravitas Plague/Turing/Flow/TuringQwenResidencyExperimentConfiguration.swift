import Foundation
import TuringQwenNative

nonisolated struct TuringQwenResidencyExperimentConfiguration:
    Sendable,
    Equatable
{
    let mode: TuringQwenNativeResidencyMode

    init(mode: TuringQwenNativeResidencyMode) {
        self.mode = mode
    }

    static func current(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) throws -> Self {
        #if GR_TURING_SHARED_RESIDENCY
        return Self(mode: .sharedImmutableFresh2)
        #elseif GR_TURING_QUALIFICATION
        let prefix = "--turing-qwen-residency="
        if let argument = arguments.first(where: { $0.hasPrefix(prefix) }) {
            let raw = String(argument.dropFirst(prefix.count))
            guard let mode = TuringQwenNativeResidencyMode(rawValue: raw) else {
                throw TuringRuntimeError.invalidConfig(
                    "Unsupported Turing Qwen residency mode \(raw)."
                )
            }
            return Self(mode: mode)
        }
        return Self(mode: .independentFresh2)
        #else
        return Self(mode: .independentFresh2)
        #endif
    }
}
