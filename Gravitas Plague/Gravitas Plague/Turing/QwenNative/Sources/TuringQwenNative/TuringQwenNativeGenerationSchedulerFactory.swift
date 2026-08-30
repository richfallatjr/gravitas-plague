import Foundation

public enum TuringQwenNativeGenerationSchedulerFactory {
    public static let exactFreshInstanceCount = 2

    public static func makeFresh2Pool(
        memoryGate: TuringQwenNativeFreshInstanceMemoryGate = TuringQwenNativeFreshInstanceMemoryGate()
    ) throws -> TuringQwenNativeFreshInstancePool {
        let config = TuringQwenNativeFreshInstanceConfig.exactTwo
        try config.validateExactTwoFreshInstances()

        return TuringQwenNativeFreshInstancePool(
            requestedInstanceCount: exactFreshInstanceCount,
            fallbackAllowed: false,
            memoryGate: memoryGate
        )
    }

    public static func makeFresh2Scheduler(
        instancePool: TuringQwenNativeFreshInstancePool,
        gpuAdmissionPolicy: TuringQwenNativeGPUAdmissionPolicy
    ) -> TuringQwenNativeFreshInstanceScheduler {
        TuringQwenNativeFreshInstanceScheduler(
            instancePool: instancePool,
            admissionPolicy: gpuAdmissionPolicy
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
