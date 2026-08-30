import Foundation

public actor TuringQwenNativeSingleLaneResidencyControl {
    #if GR_TURING_QUALIFICATION
    private let pool: TuringQwenNativeFreshInstancePool
    private let scheduler: TuringQwenNativeFreshInstanceScheduler

    public init(
        memoryGate: TuringQwenNativeFreshInstanceMemoryGate = .init(),
        admissionPolicy: TuringQwenNativeGPUAdmissionPolicy,
        commandBufferProfile: TuringQwenNativeCommandBufferProfile = .deviceDefault
    ) throws {
        let pool = try Self.makeQualificationPool(memoryGate: memoryGate)
        self.pool = pool
        self.scheduler = TuringQwenNativeFreshInstanceScheduler(
            qualificationSingleLaneInstancePool: pool,
            admissionPolicy: admissionPolicy,
            commandBufferProfile: commandBufferProfile
        )
    }

    public func warmLoad(
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String,
        performanceMode: TuringQwenNativePerformanceMode
    ) async throws {
        try await pool.warmLoadExactlyRequestedInstances(
            modelRoot: modelRoot,
            cloneProfile: cloneProfile,
            variantID: variantID,
            performanceMode: performanceMode
        )
    }

    public func runSegments(
        _ requests: [TuringQwenNativeBaseCloneSegmentRequest],
        runID: String,
        modelRoot: URL,
        skipSegmentFailures: Bool = false,
        onSegmentStarted: @Sendable @escaping (
            TuringQwenNativeFreshInstanceID,
            Int
        ) async -> Void,
        onSegmentDecoded: @Sendable @escaping (
            TuringQwenDecodedSegment
        ) async throws -> Void,
        onSegmentSkipped: @Sendable @escaping (
            TuringQwenNativeFreshSegmentSkip
        ) async -> Void = { _ in }
    ) async throws -> TuringQwenNativeFreshInstanceRunReport {
        try await scheduler.runSegments(
            requests,
            runID: runID,
            modelRoot: modelRoot,
            skipSegmentFailures: skipSegmentFailures,
            onSegmentStarted: onSegmentStarted,
            onSegmentDecoded: onSegmentDecoded,
            onSegmentSkipped: onSegmentSkipped
        )
    }

    public func unload(reason: String) async {
        await pool.unloadAll(reason: reason)
    }
    #endif

    public static func makeQualificationPool(
        memoryGate: TuringQwenNativeFreshInstanceMemoryGate = .init()
    ) throws -> TuringQwenNativeFreshInstancePool {
        #if GR_TURING_QUALIFICATION
        return try TuringQwenNativeFreshInstancePool(
            requestedInstanceCount: 1,
            fallbackAllowed: false,
            memoryGate: memoryGate,
            residencyMode: .singleLaneSharedControl
        )
        #else
        throw TuringQwenNativeError.invalidConfig(
            "Single-lane shared control requires GR_TURING_QUALIFICATION."
        )
        #endif
    }
}
