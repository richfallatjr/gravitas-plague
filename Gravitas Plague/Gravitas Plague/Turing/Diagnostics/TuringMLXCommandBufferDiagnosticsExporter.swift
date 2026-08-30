import Foundation
import MLX
import TuringQwenNative

enum TuringMLXCommandBufferDiagnosticsExporter {
    private struct ConfigurationRecord: Codable, Sendable {
        let deviceInitialized: Bool
        let architecture: String
        let architectureGeneration: Int
        let maximumOperationsPerBuffer: Int
        let maximumMegabytesPerBuffer: Int

        init(_ value: TuringMetalConfiguration) {
            deviceInitialized = value.deviceInitialized
            architecture = value.architecture
            architectureGeneration = value.architectureGeneration
            maximumOperationsPerBuffer = value.maximumOperationsPerBuffer
            maximumMegabytesPerBuffer = value.maximumMegabytesPerBuffer
        }
    }

    private struct Export: Codable, Sendable {
        let schemaVersion: Int
        let timestamp: Date
        let runID: String
        let profile: TuringQwenNativeCommandBufferProfile
        let admissionMode: TuringQwenNativeGPUAdmissionMode
        let configuration: ConfigurationRecord?
        let aggregate: TuringMetalCommandBufferAggregate
        let runMetrics: TuringQwenNativeCommandBufferRunMetrics?
        let residencyMode: TuringQwenNativeResidencyMode?
        let residencyOwnership: TuringQwenNativeResidencyOwnershipReport?
        let residencyMemory: TuringQwenNativeResidencyRunMetrics?
        let residencyMemorySamples: [TuringQwenNativeResidencyMemorySample]
        let aggregateRealTimeFactor: Double?
        let recentRecords: [TuringMetalCommandBufferRecord]
        let lastFailure: TuringMetalCommandBufferFailure?
    }

    static func export(
        runID: String,
        profile: TuringQwenNativeCommandBufferProfile,
        admissionMode: TuringQwenNativeGPUAdmissionMode,
        runMetrics: TuringQwenNativeCommandBufferRunMetrics?,
        freshRunReport: TuringQwenNativeFreshInstanceRunReport? = nil
    ) async {
        let configuration = try? TuringMetalDiagnostics.configuration()
        let payload = Export(
            schemaVersion: 1,
            timestamp: Date(),
            runID: runID,
            profile: profile,
            admissionMode: admissionMode,
            configuration: configuration.map(ConfigurationRecord.init),
            aggregate: TuringMetalDiagnostics.aggregate(),
            runMetrics: runMetrics,
            residencyMode: freshRunReport?.residencyOwnership.mode,
            residencyOwnership: freshRunReport?.residencyOwnership,
            residencyMemory: freshRunReport?.residencyMemory,
            residencyMemorySamples: freshRunReport?.residencyMemory.boundedSamples ?? [],
            aggregateRealTimeFactor: freshRunReport?.aggregateRealTimeFactor,
            recentRecords: TuringMetalDiagnostics.recentRecords(),
            lastFailure: TuringMetalDiagnostics.lastFailure()
        )

        do {
            let destination = try TuringDiagnosticsPaths.MLXMetalRunURL(runID: runID)
            try await Task.detached(priority: .utility) {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(payload)
                try data.write(to: destination, options: [.atomic])
            }.value
        } catch {
            print(
                "[TuringMLXCommandBuffer] diagnostics export failed: \(error.localizedDescription)"
            )
        }
    }
}
