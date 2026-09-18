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
    /// Nil for historical reports. Consumers must require this and no
    /// captureError for complete-run qualification; legacy zero fields alone
    /// cannot certify a capture that failed to allocate a bounded slot.
    public let fullRunAccounting: TuringMetalCommandBufferCaptureSummary?
    public let captureError: String?

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
                "mixedContextCount": String(mixedContextCount),
                "pendingCount": fullRunAccounting.map { String($0.pendingCount) } ?? "unavailable",
                "totalRecordedGPUSeconds": fullRunAccounting.map {
                    String(format: "%.9f", $0.totalRecordedGPUSeconds)
                } ?? "unavailable",
                "captureError": captureError ?? "none"
            ]
        )
    }
}

public struct TuringQwenNativeCommandBufferRunCapture: Sendable {
    private let capture: TuringMetalCommandBufferCapture?
    private let captureError: String?

    public init() {
        do {
            capture = try TuringMetalCommandBufferCapture()
            captureError = nil
        } catch {
            capture = nil
            captureError = String(describing: error)
        }
    }

    public func finish(
        profile: TuringQwenNativeCommandBufferProfile,
        admissionMode: TuringQwenNativeGPUAdmissionMode
    ) -> TuringQwenNativeCommandBufferRunMetrics {
        let accounting: TuringMetalCommandBufferCaptureSummary?
        let errorDescription: String?
        do {
            accounting = try capture?.finish()
            errorDescription = captureError
        } catch {
            accounting = nil
            errorDescription = String(describing: error)
        }
        let aggregate = accounting?.aggregate

        return TuringQwenNativeCommandBufferRunMetrics(
            profile: profile,
            admissionMode: admissionMode,
            submittedCount: Int(clamping: aggregate?.submittedCount ?? 0),
            completedCount: Int(clamping: aggregate?.completedCount ?? 0),
            failureCount: Int(clamping: aggregate?.failureCount ?? 0),
            maximumGPUSeconds: aggregate?.maximumGPUSeconds ?? 0,
            maximumKernelSeconds: aggregate?.maximumKernelSeconds ?? 0,
            durationHistogram: aggregate?.durationHistogram.mapValues { Int(clamping: $0) } ?? [:],
            slowestRecords: accounting?.slowestRecords ?? [],
            mixedContextCount: Int(clamping: accounting?.mixedContextCount ?? 0),
            singlePrimitiveOver50msCount: Int(clamping: accounting?.singlePrimitiveOver50msCount ?? 0),
            fullRunAccounting: accounting,
            captureError: errorDescription
        )
    }
}
