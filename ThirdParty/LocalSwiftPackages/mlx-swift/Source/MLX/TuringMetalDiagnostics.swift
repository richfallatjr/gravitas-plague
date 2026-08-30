import Cmlx
import Foundation

public struct TuringMetalConfiguration: Sendable, Equatable {
    public let deviceInitialized: Bool
    public let architecture: String
    public let architectureGeneration: Int
    public let maximumOperationsPerBuffer: Int
    public let maximumMegabytesPerBuffer: Int
}

public struct TuringMetalExecutionContext: Sendable, Equatable {
    public let runID: String
    public let instanceID: String?
    public let segmentIndex: Int?
    public let laneIndex: Int?
    public let decodeID: Int?
    public let phase: String
    public let stage: String?
    public let residencyOwnerID: String?
    public let weightStoreID: String?
    public let laneMutableStateID: String?
    public let rowRange: Range<Int>?
    public let talkerPositionRange: Range<Int>?
    public let appMetalInFlightCount: Int
    public let mindEyeCompositorInFlightCount: Int

    public init(
        runID: String,
        instanceID: String? = nil,
        segmentIndex: Int? = nil,
        laneIndex: Int? = nil,
        decodeID: Int? = nil,
        phase: String,
        stage: String? = nil,
        residencyOwnerID: String? = nil,
        weightStoreID: String? = nil,
        laneMutableStateID: String? = nil,
        rowRange: Range<Int>? = nil,
        talkerPositionRange: Range<Int>? = nil,
        appMetalInFlightCount: Int = 0,
        mindEyeCompositorInFlightCount: Int = 0
    ) {
        self.runID = runID
        self.instanceID = instanceID
        self.segmentIndex = segmentIndex
        self.laneIndex = laneIndex
        self.decodeID = decodeID
        self.phase = phase
        self.stage = stage
        self.residencyOwnerID = residencyOwnerID
        self.weightStoreID = weightStoreID
        self.laneMutableStateID = laneMutableStateID
        self.rowRange = rowRange
        self.talkerPositionRange = talkerPositionRange
        self.appMetalInFlightCount = appMetalInFlightCount
        self.mindEyeCompositorInFlightCount = mindEyeCompositorInFlightCount
    }
}

public struct TuringMetalCommandBufferContext: Sendable, Equatable, Codable {
    public let runID: String?
    public let instanceID: String?
    public let segmentIndex: Int?
    public let laneIndex: Int?
    public let decodeID: Int?
    public let phase: String?
    public let stage: String?
    public let residencyOwnerID: String?
    public let weightStoreID: String?
    public let laneMutableStateID: String?
    public let rowStartInclusive: Int?
    public let rowEndExclusive: Int?
    public let talkerPositionStart: Int?
    public let talkerPositionEnd: Int?
    public let appMetalInFlightCount: Int
    public let mindEyeCompositorInFlightCount: Int
}

public struct TuringMetalCommandBufferRecord: Sendable, Equatable, Codable {
    public let sequence: UInt64
    public let commandBufferID: UInt64
    public let failureEpoch: UInt64
    public let streamIndex: Int
    public let commandQueueIdentity: UInt64
    public let configuredMaximumOperations: Int
    public let configuredMaximumMegabytes: Int
    public let encodedOperationCount: Int
    public let referencedInputBytesEstimate: UInt64
    public let primitiveCount: Int
    public let primitiveHash: UInt64
    public let firstPrimitive: String
    public let lastPrimitive: String
    public let commandBufferLabel: String
    public let firstContext: TuringMetalCommandBufferContext
    public let lastContext: TuringMetalCommandBufferContext
    public let mixedContext: Bool
    public let submitUptimeNanoseconds: UInt64
    public let completionUptimeNanoseconds: UInt64
    public let GPUStartSeconds: Double
    public let GPUEndSeconds: Double
    public let GPUSeconds: Double
    public let kernelStartSeconds: Double
    public let kernelEndSeconds: Double
    public let kernelSeconds: Double
    public let completionStatus: Int
    public let errorCode: Int
    public let errorDomain: String
    public let metalErrorDescription: String
    public let MLXBuffersInFlightAtSubmit: Int
    public let appMetalInFlightAtSubmit: Int
    public let mindEyeInFlightAtSubmit: Int
    public let processPhysicalFootprintBytesAtSubmit: UInt64
    public let processAvailableMemoryBytesAtSubmit: UInt64
    public let MLXActiveBytesAtSubmit: UInt64
    public let MLXCacheBytesAtSubmit: UInt64
    public let MLXPeakBytesAtSubmit: UInt64
    public let processPhysicalFootprintBytesAtCompletion: UInt64
    public let processAvailableMemoryBytesAtCompletion: UInt64
    public let MLXActiveBytesAtCompletion: UInt64
    public let MLXCacheBytesAtCompletion: UInt64
    public let MLXPeakBytesAtCompletion: UInt64
    public let isFailure: Bool
    public let isSyntheticTestFailure: Bool
}

public struct TuringMetalCommandBufferFailure:
    Error,
    LocalizedError,
    Sendable,
    Equatable,
    Codable
{
    public let record: TuringMetalCommandBufferRecord

    public var errorDescription: String? {
        "MLX Metal command buffer \(record.commandBufferID) failed " +
        "status=\(record.completionStatus) domain=\(record.errorDomain) " +
        "code=\(record.errorCode) gpuSeconds=\(record.GPUSeconds) " +
        "run=\(record.lastContext.runID ?? "none") " +
        "segment=\(record.lastContext.segmentIndex.map(String.init) ?? "none") " +
        "phase=\(record.lastContext.phase ?? "none") " +
        "stage=\(record.lastContext.stage ?? "none")"
    }

    #if DEBUG
    public static func testing(
        commandBufferID: UInt64 = 1,
        failureEpoch: UInt64 = 1,
        runID: String = "test-run",
        phase: String = "speechDecoder",
        stage: String = "test-stage"
    ) -> Self {
        let context = TuringMetalCommandBufferContext(
            runID: runID,
            instanceID: "fresh-0",
            segmentIndex: 0,
            laneIndex: 0,
            decodeID: 0,
            phase: phase,
            stage: stage,
            residencyOwnerID: nil,
            weightStoreID: nil,
            laneMutableStateID: nil,
            rowStartInclusive: nil,
            rowEndExclusive: nil,
            talkerPositionStart: nil,
            talkerPositionEnd: nil,
            appMetalInFlightCount: 0,
            mindEyeCompositorInFlightCount: 0
        )
        return Self(record: TuringMetalCommandBufferRecord(
            sequence: 1,
            commandBufferID: commandBufferID,
            failureEpoch: failureEpoch,
            streamIndex: 0,
            commandQueueIdentity: 0,
            configuredMaximumOperations: 0,
            configuredMaximumMegabytes: 0,
            encodedOperationCount: 1,
            referencedInputBytesEstimate: 0,
            primitiveCount: 1,
            primitiveHash: 1,
            firstPrimitive: "test",
            lastPrimitive: "test",
            commandBufferLabel: "test",
            firstContext: context,
            lastContext: context,
            mixedContext: false,
            submitUptimeNanoseconds: 1,
            completionUptimeNanoseconds: 2,
            GPUStartSeconds: 1,
            GPUEndSeconds: 1.1,
            GPUSeconds: 0.1,
            kernelStartSeconds: 1,
            kernelEndSeconds: 1.1,
            kernelSeconds: 0.1,
            completionStatus: 5,
            errorCode: 1,
            errorDomain: "TuringSyntheticMetalFailure",
            metalErrorDescription: "Synthetic test completion failure",
            MLXBuffersInFlightAtSubmit: 1,
            appMetalInFlightAtSubmit: 0,
            mindEyeInFlightAtSubmit: 0,
            processPhysicalFootprintBytesAtSubmit: 0,
            processAvailableMemoryBytesAtSubmit: 0,
            MLXActiveBytesAtSubmit: 0,
            MLXCacheBytesAtSubmit: 0,
            MLXPeakBytesAtSubmit: 0,
            processPhysicalFootprintBytesAtCompletion: 0,
            processAvailableMemoryBytesAtCompletion: 0,
            MLXActiveBytesAtCompletion: 0,
            MLXCacheBytesAtCompletion: 0,
            MLXPeakBytesAtCompletion: 0,
            isFailure: true,
            isSyntheticTestFailure: true
        ))
    }
    #endif
}

public struct TuringMetalCommandBufferAggregate: Sendable, Equatable, Codable {
    public let submittedCount: UInt64
    public let completedCount: UInt64
    public let failureCount: UInt64
    public let maximumEncodedOperationCount: UInt64
    public let maximumReferencedInputBytesEstimate: UInt64
    public let maximumGPUSeconds: Double
    public let maximumKernelSeconds: Double
    public let durationHistogram: [String: UInt64]
}

public enum TuringMetalDiagnostics {
    public struct ExternalInFlightCounts: Sendable, Equatable {
        public let appMetal: Int
        public let mindEyeCompositor: Int
    }

    public static var deviceIsInitialized: Bool {
        mlx_turing_metal_device_is_initialized() != 0
    }

    public static func configuration() throws -> TuringMetalConfiguration {
        var value = mlx_turing_metal_configuration()
        guard mlx_turing_metal_copy_configuration(&value) == 0 else {
            throw MLXError.caught("MLX Metal device configuration is unavailable.")
        }
        return .init(
            deviceInitialized: value.device_initialized != 0,
            architecture: string(from: value.architecture),
            architectureGeneration: Int(value.architecture_generation),
            maximumOperationsPerBuffer: Int(value.resolved_max_ops_per_buffer),
            maximumMegabytesPerBuffer: Int(value.resolved_max_mb_per_buffer)
        )
    }

    public static var failureEpoch: UInt64 {
        mlx_turing_metal_failure_epoch()
    }

    public static var isPoisoned: Bool {
        mlx_turing_metal_is_poisoned() != 0
    }

    public static func lastFailure() -> TuringMetalCommandBufferFailure? {
        var value = mlx_turing_command_buffer_record()
        guard mlx_turing_metal_copy_last_failure(&value) == 0 else {
            return nil
        }
        return .init(record: record(from: value))
    }

    public static func recentRecords() -> [TuringMetalCommandBufferRecord] {
        var values = Array(
            repeating: mlx_turing_command_buffer_record(),
            count: 64
        )
        let count = values.withUnsafeMutableBufferPointer { buffer in
            mlx_turing_metal_copy_recent_records(buffer.baseAddress, buffer.count)
        }
        return values.prefix(Int(count)).map(record(from:))
    }

    public static func aggregate() -> TuringMetalCommandBufferAggregate {
        var value = mlx_turing_command_buffer_aggregate()
        _ = mlx_turing_metal_copy_aggregate(&value)
        return .init(
            submittedCount: value.submitted_count,
            completedCount: value.completed_count,
            failureCount: value.failed_count,
            maximumEncodedOperationCount: value.maximum_encoded_operation_count,
            maximumReferencedInputBytesEstimate:
                value.maximum_referenced_input_bytes_estimate,
            maximumGPUSeconds: value.maximum_gpu_duration_seconds,
            maximumKernelSeconds: value.maximum_kernel_duration_seconds,
            durationHistogram: [
                "lt5ms": value.duration_bucket_lt_5ms,
                "5to10ms": value.duration_bucket_5_10ms,
                "10to20ms": value.duration_bucket_10_20ms,
                "20to30ms": value.duration_bucket_20_30ms,
                "30to40ms": value.duration_bucket_30_40ms,
                "40to50ms": value.duration_bucket_40_50ms,
                "50to75ms": value.duration_bucket_50_75ms,
                "75to100ms": value.duration_bucket_75_100ms,
                "100to150ms": value.duration_bucket_100_150ms,
                "gte150ms": value.duration_bucket_gte_150ms,
            ]
        )
    }

    public static func setFailureFileURL(_ URL: URL) throws {
        let result = URL.path.withCString {
            mlx_turing_metal_set_failure_file_path($0)
        }
        guard result == 0 else {
            throw MLXError.caught("Invalid MLX Metal failure-file path.")
        }
    }

    public static func setExternalInFlightCounts(
        appMetal: Int,
        mindEyeCompositor: Int
    ) {
        mlx_turing_metal_set_external_in_flight_counts(
            UInt32(clamping: appMetal),
            UInt32(clamping: mindEyeCompositor)
        )
    }

    public static func externalInFlightCounts() -> ExternalInFlightCounts {
        var appMetal: UInt32 = 0
        var mindEye: UInt32 = 0
        mlx_turing_metal_copy_external_in_flight_counts(&appMetal, &mindEye)
        return .init(
            appMetal: Int(appMetal),
            mindEyeCompositor: Int(mindEye)
        )
    }

    #if DEBUG
    public static func resetForTesting() {
        mlx_turing_metal_test_reset()
    }

    public static func injectFailureOnNextCompletionForTesting(
        errorCode: Int32
    ) {
        mlx_turing_metal_test_inject_failure_on_next_completion(errorCode)
    }

    public static func recordSyntheticCompletionForTesting() {
        mlx_turing_metal_test_record_synthetic_completion()
    }
    #endif

    public static func withContext<R>(
        _ context: TuringMetalExecutionContext,
        _ body: () throws -> R
    ) rethrows -> R {
        var value = context.cValue
        _ = mlx_turing_metal_set_context(&value)
        defer { mlx_turing_metal_clear_context() }
        return try body()
    }

    /// Low-level balanced scope used when a caller must return MLX-backed state
    /// without sending that state through a generic cross-module closure.
    public static func pushContext(_ context: TuringMetalExecutionContext) {
        var value = context.cValue
        _ = mlx_turing_metal_set_context(&value)
    }

    public static func popContext() {
        mlx_turing_metal_clear_context()
    }

    private static func record(
        from value: mlx_turing_command_buffer_record
    ) -> TuringMetalCommandBufferRecord {
        .init(
            sequence: value.sequence,
            commandBufferID: value.command_buffer_id,
            failureEpoch: value.failure_epoch,
            streamIndex: Int(value.stream_index),
            commandQueueIdentity: UInt64(value.command_queue_identity),
            configuredMaximumOperations: Int(value.configured_max_ops),
            configuredMaximumMegabytes: Int(value.configured_max_mb),
            encodedOperationCount: Int(value.encoded_operation_count),
            referencedInputBytesEstimate: value.referenced_input_bytes_estimate,
            primitiveCount: Int(value.primitive_count),
            primitiveHash: value.primitive_name_hash,
            firstPrimitive: string(from: value.first_primitive),
            lastPrimitive: string(from: value.last_primitive),
            commandBufferLabel: string(from: value.command_buffer_label),
            firstContext: context(from: value.first_context),
            lastContext: context(from: value.last_context),
            mixedContext: value.mixed_context != 0,
            submitUptimeNanoseconds: value.submit_uptime_nanoseconds,
            completionUptimeNanoseconds: value.completion_uptime_nanoseconds,
            GPUStartSeconds: value.gpu_start_seconds,
            GPUEndSeconds: value.gpu_end_seconds,
            GPUSeconds: value.gpu_duration_seconds,
            kernelStartSeconds: value.kernel_start_seconds,
            kernelEndSeconds: value.kernel_end_seconds,
            kernelSeconds: value.kernel_duration_seconds,
            completionStatus: Int(value.completion_status),
            errorCode: Int(value.error_code),
            errorDomain: string(from: value.error_domain),
            metalErrorDescription: string(from: value.error_description),
            MLXBuffersInFlightAtSubmit:
                Int(value.mlx_buffers_in_flight_at_submit),
            appMetalInFlightAtSubmit:
                Int(value.app_metal_in_flight_at_submit),
            mindEyeInFlightAtSubmit:
                Int(value.mind_eye_in_flight_at_submit),
            processPhysicalFootprintBytesAtSubmit:
                value.process_phys_footprint_bytes_at_submit,
            processAvailableMemoryBytesAtSubmit:
                value.process_available_memory_bytes_at_submit,
            MLXActiveBytesAtSubmit: value.mlx_active_bytes_at_submit,
            MLXCacheBytesAtSubmit: value.mlx_cache_bytes_at_submit,
            MLXPeakBytesAtSubmit: value.mlx_peak_bytes_at_submit,
            processPhysicalFootprintBytesAtCompletion:
                value.process_phys_footprint_bytes_at_completion,
            processAvailableMemoryBytesAtCompletion:
                value.process_available_memory_bytes_at_completion,
            MLXActiveBytesAtCompletion: value.mlx_active_bytes_at_completion,
            MLXCacheBytesAtCompletion: value.mlx_cache_bytes_at_completion,
            MLXPeakBytesAtCompletion: value.mlx_peak_bytes_at_completion,
            isFailure: value.is_failure != 0,
            isSyntheticTestFailure: value.is_synthetic_test_failure != 0
        )
    }

    private static func context(
        from value: mlx_turing_metal_context
    ) -> TuringMetalCommandBufferContext {
        let runID = string(from: value.run_id)
        let instanceID = string(from: value.instance_id)
        let phase = string(from: value.phase)
        let stage = string(from: value.stage)
        let residencyOwnerID = string(from: value.residency_owner_id)
        let weightStoreID = string(from: value.weight_store_id)
        let laneMutableStateID = string(from: value.lane_mutable_state_id)
        return .init(
            runID: runID.isEmpty ? nil : runID,
            instanceID: instanceID.isEmpty ? nil : instanceID,
            segmentIndex: optional(value.segment_index),
            laneIndex: optional(value.lane_index),
            decodeID: optional(value.decode_id),
            phase: phase.isEmpty ? nil : phase,
            stage: stage.isEmpty ? nil : stage,
            residencyOwnerID: residencyOwnerID.isEmpty ? nil : residencyOwnerID,
            weightStoreID: weightStoreID.isEmpty ? nil : weightStoreID,
            laneMutableStateID: laneMutableStateID.isEmpty ? nil : laneMutableStateID,
            rowStartInclusive: optional(value.row_start_inclusive),
            rowEndExclusive: optional(value.row_end_exclusive),
            talkerPositionStart: optional(value.talker_position_start),
            talkerPositionEnd: optional(value.talker_position_end),
            appMetalInFlightCount: Int(value.app_metal_in_flight_count),
            mindEyeCompositorInFlightCount:
                Int(value.mind_eye_compositor_in_flight_count)
        )
    }

    private static func optional(_ value: Int32) -> Int? {
        value < 0 ? nil : Int(value)
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            guard let baseAddress = bytes.baseAddress else { return "" }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
    }
}

private extension TuringMetalExecutionContext {
    var cValue: mlx_turing_metal_context {
        var value = mlx_turing_metal_context()
        copy(runID, into: &value.run_id)
        copy(instanceID ?? "", into: &value.instance_id)
        copy(phase, into: &value.phase)
        copy(stage ?? "", into: &value.stage)
        copy(residencyOwnerID ?? "", into: &value.residency_owner_id)
        copy(weightStoreID ?? "", into: &value.weight_store_id)
        copy(laneMutableStateID ?? "", into: &value.lane_mutable_state_id)
        value.segment_index = Int32(segmentIndex ?? -1)
        value.lane_index = Int32(laneIndex ?? -1)
        value.decode_id = Int32(decodeID ?? -1)
        value.row_start_inclusive = Int32(rowRange?.lowerBound ?? -1)
        value.row_end_exclusive = Int32(rowRange?.upperBound ?? -1)
        value.talker_position_start =
            Int32(talkerPositionRange?.lowerBound ?? -1)
        value.talker_position_end =
            Int32(talkerPositionRange?.upperBound ?? -1)
        value.app_metal_in_flight_count =
            UInt32(clamping: appMetalInFlightCount)
        value.mind_eye_compositor_in_flight_count =
            UInt32(clamping: mindEyeCompositorInFlightCount)
        return value
    }

    func copy<T>(_ string: String, into tuple: inout T) {
        withUnsafeMutableBytes(of: &tuple) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            let source = Array(string.utf8.prefix(max(0, destination.count - 1)))
            destination.copyBytes(from: source)
        }
    }
}
