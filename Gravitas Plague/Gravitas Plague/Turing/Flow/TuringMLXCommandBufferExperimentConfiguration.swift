import Darwin
import Foundation
import MLX
import TuringQwenNative

nonisolated struct TuringMLXCommandBufferExperimentConfiguration:
    Sendable,
    Equatable
{
    let profile: TuringQwenNativeCommandBufferProfile
    let targetedBoundary: TuringQwenNativeTargetedBoundaryPolicy

    static func current(
        processInfo: ProcessInfo = .processInfo
    ) throws -> Self {
        try current(arguments: processInfo.arguments)
    }

    static func current(arguments: [String]) throws -> Self {
        let profile: TuringQwenNativeCommandBufferProfile
        #if GR_TURING_MLX_PROFILE_OPS32_MB40
        profile = .operations32Megabytes40
        #elseif GR_TURING_MLX_PROFILE_OPS40_MB32
        profile = .operations40Megabytes32
        #elseif GR_TURING_MLX_PROFILE_OPS32_MB32
        profile = .operations32Megabytes32
        #elseif GR_TURING_MLX_PROFILE_OPS24_MB24
        profile = .operations24Megabytes24
        #elseif GR_TURING_MLX_PROFILE_OPS16_MB16
        profile = .operations16Megabytes16
        #elseif GR_TURING_QUALIFICATION
        profile = try parseSingle(
            prefix: "--turing-mlx-buffer-profile=",
            arguments: arguments,
            defaultValue: .deviceDefault
        )
        #else
        profile = .deviceDefault
        #endif

        let targetedBoundary: TuringQwenNativeTargetedBoundaryPolicy
        #if GR_TURING_QUALIFICATION
        targetedBoundary = try parseSingle(
            prefix: "--turing-mlx-targeted-boundary=",
            arguments: arguments,
            defaultValue: .none
        )
        #else
        targetedBoundary = .none
        #endif

        return Self(profile: profile, targetedBoundary: targetedBoundary)
    }

    private static func parseSingle<Value>(
        prefix: String,
        arguments: [String],
        defaultValue: Value
    ) throws -> Value where Value: RawRepresentable, Value.RawValue == String {
        let matches = arguments.filter { $0.hasPrefix(prefix) }
        guard matches.count <= 1 else {
            throw TuringRuntimeError.invalidConfig(
                "Duplicate launch argument \(prefix)"
            )
        }
        guard let argument = matches.first else { return defaultValue }
        let rawValue = String(argument.dropFirst(prefix.count))
        guard let value = Value(rawValue: rawValue) else {
            throw TuringRuntimeError.invalidConfig(
                "Unsupported launch argument \(argument)"
            )
        }
        return value
    }

    func verifyResolvedDeviceConfiguration() throws -> TuringMetalConfiguration {
        let resolved = try TuringMetalDiagnostics.configuration()
        guard resolved.deviceInitialized else {
            throw TuringRuntimeError.invalidConfig(
                "MLX Metal device was not initialized after Qwen warm load."
            )
        }
        if let operations = profile.configuredOperations,
           resolved.maximumOperationsPerBuffer != operations {
            throw TuringRuntimeError.invalidConfig(
                "Requested MLX max operations \(operations), resolved \(resolved.maximumOperationsPerBuffer)."
            )
        }
        if let megabytes = profile.configuredMegabytes,
           resolved.maximumMegabytesPerBuffer != megabytes {
            throw TuringRuntimeError.invalidConfig(
                "Requested MLX max MB \(megabytes), resolved \(resolved.maximumMegabytesPerBuffer)."
            )
        }
        print("""
        [TuringMLXCommandBuffer] profile resolved
          requestedProfile: \(profile.rawValue)
          architecture: \(resolved.architecture)
          architectureGeneration: \(resolved.architectureGeneration)
          maximumOperationsPerBuffer: \(resolved.maximumOperationsPerBuffer)
          maximumMegabytesPerBuffer: \(resolved.maximumMegabytesPerBuffer)
        """)
        return resolved
    }
}

@MainActor
enum TuringMLXCommandBufferStartup {
    private static var configured = false
    private(set) static var configuration:
        TuringMLXCommandBufferExperimentConfiguration?

    static func configure() throws {
        guard configured == false else { return }
        guard TuringMetalDiagnostics.deviceIsInitialized == false else {
            throw TuringRuntimeError.invalidConfig(
                "MLX Metal device initialized before Turing command-buffer profile configuration."
            )
        }

        let selected = try TuringMLXCommandBufferExperimentConfiguration.current()
        if let operations = selected.profile.configuredOperations {
            setenv("MLX_MAX_OPS_PER_BUFFER", String(operations), 1)
        }
        if let megabytes = selected.profile.configuredMegabytes {
            setenv("MLX_MAX_MB_PER_BUFFER", String(megabytes), 1)
        }

        let failureURL = try TuringDiagnosticsPaths.MLXMetalLastFailureURL()
        try TuringMetalDiagnostics.setFailureFileURL(failureURL)
        configuration = selected
        configured = true

        print("""
        [TuringMLXCommandBuffer] startup configured
          requestedProfile: \(selected.profile.rawValue)
          targetedBoundary: \(selected.targetedBoundary.rawValue)
          environmentMaxOperations: \(ProcessInfo.processInfo.environment["MLX_MAX_OPS_PER_BUFFER"] ?? "deviceDefault")
          environmentMaxMegabytes: \(ProcessInfo.processInfo.environment["MLX_MAX_MB_PER_BUFFER"] ?? "deviceDefault")
          deviceInitializedAfterConfiguration: \(TuringMetalDiagnostics.deviceIsInitialized)
        """)
    }
}
