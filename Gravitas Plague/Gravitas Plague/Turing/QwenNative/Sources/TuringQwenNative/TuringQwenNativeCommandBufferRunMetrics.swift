import Foundation
import MLX

public struct TuringQwenNativeCommandBufferRunMetrics:
    Sendable,
    Equatable,
    Codable
{
    public let profile: TuringQwenNativeCommandBufferProfile
    public let admissionMode: TuringQwenNativeGPUAdmissionMode
    public let submittedCount: Int
    public let completedCount: Int
    public let failureCount: Int
    public let maximumGPUSeconds: Double
    public let maximumKernelSeconds: Double
    public let durationHistogram: [String: Int]
    public let slowestRecords: [TuringMetalCommandBufferRecord]
    public let mixedContextCount: Int
    public let singlePrimitiveOver50msCount: Int

    func recordBoundedDiagnostics(runID: String) {
        for record in slowestRecords where record.GPUSeconds >= 0.050 || record.isFailure {
            TuringQwenNativeDiagnostics.recordBreadcrumb(
                record.isFailure ? "mlx.commandBuffer.failed" : "mlx.commandBuffer.slow",
                runID: record.lastContext.runID ?? runID,
                instanceID: record.lastContext.instanceID,
                segmentIndex: record.lastContext.segmentIndex,
                details: [
                    "commandBufferID": String(record.commandBufferID),
                    "gpuSeconds": String(format: "%.9f", record.GPUSeconds),
                    "kernelSeconds": String(format: "%.9f", record.kernelSeconds),
                    "operationCount": String(record.encodedOperationCount),
                    "referencedInputBytesEstimate": String(record.referencedInputBytesEstimate),
                    "primitiveCount": String(record.primitiveCount),
                    "primitiveHash": String(record.primitiveHash),
                    "phase": record.lastContext.phase ?? "none",
                    "stage": record.lastContext.stage ?? "none",
                    "mindEyeInFlight": String(record.mindEyeInFlightAtSubmit)
                ]
            )
        }
        TuringQwenNativeDiagnostics.recordBreadcrumb(
            "mlx.commandBuffer.run.end",
            runID: runID,
            details: [
                "profile": profile.rawValue,
                "admissionMode": admissionMode.rawValue,
                "submittedCount": String(submittedCount),
                "completedCount": String(completedCount),
                "failureCount": String(failureCount),
                "maximumGPUSeconds": String(format: "%.9f", maximumGPUSeconds),
                "maximumKernelSeconds": String(format: "%.9f", maximumKernelSeconds),
                "mixedContextCount": String(mixedContextCount)
            ]
        )
    }
}

public struct TuringQwenNativeCommandBufferRunCapture: Sendable {
    private let aggregateAtBegin: TuringMetalCommandBufferAggregate
    private let lastSequenceAtBegin: UInt64

    public init() {
        aggregateAtBegin = TuringMetalDiagnostics.aggregate()
        lastSequenceAtBegin = TuringMetalDiagnostics.recentRecords()
            .map(\.sequence)
            .max() ?? 0
    }

    public func finish(
        profile: TuringQwenNativeCommandBufferProfile,
        admissionMode: TuringQwenNativeGPUAdmissionMode
    ) -> TuringQwenNativeCommandBufferRunMetrics {
        let end = TuringMetalDiagnostics.aggregate()
        let records = TuringMetalDiagnostics.recentRecords()
            .filter { $0.sequence > lastSequenceAtBegin }
        let slowest = records
            .sorted { $0.GPUSeconds > $1.GPUSeconds }
            .prefix(16)

        return TuringQwenNativeCommandBufferRunMetrics(
            profile: profile,
            admissionMode: admissionMode,
            submittedCount: delta(end.submittedCount, aggregateAtBegin.submittedCount),
            completedCount: delta(end.completedCount, aggregateAtBegin.completedCount),
            failureCount: delta(end.failureCount, aggregateAtBegin.failureCount),
            maximumGPUSeconds: records.map(\.GPUSeconds).max() ?? 0,
            maximumKernelSeconds: records.map(\.kernelSeconds).max() ?? 0,
            durationHistogram: histogramDelta(end, aggregateAtBegin),
            slowestRecords: Array(slowest),
            mixedContextCount: records.lazy.filter(\.mixedContext).count,
            singlePrimitiveOver50msCount: records.lazy.filter {
                $0.primitiveCount <= 2 &&
                $0.encodedOperationCount <= 2 &&
                $0.GPUSeconds >= 0.050
            }.count
        )
    }

    private func delta(_ end: UInt64, _ begin: UInt64) -> Int {
        Int(end >= begin ? end - begin : 0)
    }

    private func histogramDelta(
        _ end: TuringMetalCommandBufferAggregate,
        _ begin: TuringMetalCommandBufferAggregate
    ) -> [String: Int] {
        var result: [String: Int] = [:]
        for (key, endValue) in end.durationHistogram {
            result[key] = delta(endValue, begin.durationHistogram[key] ?? 0)
        }
        return result
    }
}
