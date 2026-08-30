import Foundation

public enum TuringQwenNativeGenerationSchedulerFactory {
    public static let exactFreshInstanceCount = 2

    public static func makeFresh2Pool(
        memoryGate: TuringQwenNativeFreshInstanceMemoryGate = TuringQwenNativeFreshInstanceMemoryGate(),
        recoverySessionID: UUID = UUID(),
        recoveryRunID: String = "unregistered",
        recoveryGeneration: TuringQwenNativeRecoveryGeneration = .initial
    ) throws -> TuringQwenNativeFreshInstancePool {
        try makeFresh2Pool(
            memoryGate: memoryGate,
            residencyMode: .independentFresh2,
            recoverySessionID: recoverySessionID,
            recoveryRunID: recoveryRunID,
            recoveryGeneration: recoveryGeneration
        )
    }

    public static func makeFresh2Pool(
        memoryGate: TuringQwenNativeFreshInstanceMemoryGate = TuringQwenNativeFreshInstanceMemoryGate(),
        residencyMode: TuringQwenNativeResidencyMode,
        recoverySessionID: UUID = UUID(),
        recoveryRunID: String = "unregistered",
        recoveryGeneration: TuringQwenNativeRecoveryGeneration = .initial
    ) throws -> TuringQwenNativeFreshInstancePool {
        let config = TuringQwenNativeFreshInstanceConfig.exactTwo
        try config.validateExactTwoFreshInstances()
        guard residencyMode != .singleLaneSharedControl else {
            throw TuringQwenNativeError.invalidConfig(
                "Single-lane control must use the qualification harness."
            )
        }

        return try TuringQwenNativeFreshInstancePool(
            requestedInstanceCount: exactFreshInstanceCount,
            fallbackAllowed: false,
            memoryGate: memoryGate,
            residencyMode: residencyMode,
            recoverySessionID: recoverySessionID,
            recoveryRunID: recoveryRunID,
            recoveryGeneration: recoveryGeneration
        )
    }

    public static func makeFresh2Scheduler(
        instancePool: TuringQwenNativeFreshInstancePool,
        gpuAdmissionPolicy: TuringQwenNativeGPUAdmissionPolicy,
        commandBufferProfile: TuringQwenNativeCommandBufferProfile = .deviceDefault
    ) -> TuringQwenNativeFreshInstanceScheduler {
        TuringQwenNativeFreshInstanceScheduler(
            instancePool: instancePool,
            admissionPolicy: gpuAdmissionPolicy,
            commandBufferProfile: commandBufferProfile,
            recoveryGeneration: instancePool.recoveryGeneration
        )
    }

    /// Retains source compatibility for diagnostic canaries that intentionally
    /// exercise the current production scheduler without the Phase 1 candidate.
    public static func makeFresh2Scheduler(
        instancePool: TuringQwenNativeFreshInstancePool
    ) -> TuringQwenNativeFreshInstanceScheduler {
        let productionPolicy: TuringQwenNativeGPUAdmissionPolicy
        do {
            productionPolicy = try .currentProduction
        } catch {
            preconditionFailure(
                "The locked Fresh2 production admission policy is invalid: \(error)"
            )
        }
        return makeFresh2Scheduler(
            instancePool: instancePool,
            gpuAdmissionPolicy: productionPolicy
        )
    }
}
