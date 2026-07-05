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
        instancePool: TuringQwenNativeFreshInstancePool
    ) -> TuringQwenNativeFreshInstanceScheduler {
        TuringQwenNativeFreshInstanceScheduler(instancePool: instancePool)
    }
}
