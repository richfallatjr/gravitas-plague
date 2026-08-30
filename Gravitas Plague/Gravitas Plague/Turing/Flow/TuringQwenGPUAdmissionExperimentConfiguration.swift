import Foundation
import TuringQwenNative

nonisolated struct TuringQwenGPUAdmissionExperimentConfiguration:
    Sendable,
    Equatable
{
    let mode: TuringQwenNativeGPUAdmissionMode

    init(mode: TuringQwenNativeGPUAdmissionMode) {
        self.mode = mode
    }

    static func current(
        processInfo: ProcessInfo = .processInfo
    ) throws -> Self {
        try current(arguments: processInfo.arguments)
    }

    static func current(arguments: [String]) throws -> Self {
        #if GR_TURING_DECODE_EXCLUSIVE
        return Self(mode: .decodeExclusive)
        #elseif GR_TURING_QUALIFICATION
        let prefix = "--turing-gpu-admission="
        if let argument = arguments.first(where: { $0.hasPrefix(prefix) }) {
            let raw = String(argument.dropFirst(prefix.count))
            guard let mode = TuringQwenNativeGPUAdmissionMode(rawValue: raw) else {
                throw TuringRuntimeError.invalidConfig(
                    "Unsupported Turing GPU admission mode \(raw)."
                )
            }
            return Self(mode: mode)
        }
        return Self(mode: .currentOverlap)
        #else
        return Self(mode: .currentOverlap)
        #endif
    }

    func policy() throws -> TuringQwenNativeGPUAdmissionPolicy {
        try .init(
            mode: mode,
            maximumConcurrentGenerationLeases: 2,
            decoderHasPriority: true
        )
    }
}
