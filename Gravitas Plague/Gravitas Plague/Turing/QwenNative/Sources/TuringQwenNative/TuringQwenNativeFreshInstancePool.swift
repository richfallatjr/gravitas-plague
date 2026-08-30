import Foundation

public actor TuringQwenNativeFreshInstancePool {
    public static let defaultInstanceCount = 2

    public private(set) var requestedInstanceCount: Int
    public private(set) var actualInstanceCount: Int = 0
    public let fallbackAllowed: Bool
    public let memoryGate: TuringQwenNativeFreshInstanceMemoryGate

    private var instances: [TuringQwenNativeFreshInstance] = []
    private var availableInstanceIDs: [TuringQwenNativeFreshInstanceID] = []

    public init(
        requestedInstanceCount: Int = TuringQwenNativeFreshInstancePool.defaultInstanceCount,
        fallbackAllowed: Bool = false,
        memoryGate: TuringQwenNativeFreshInstanceMemoryGate = TuringQwenNativeFreshInstanceMemoryGate()
    ) {
        self.requestedInstanceCount = max(1, requestedInstanceCount)
        self.fallbackAllowed = fallbackAllowed
        self.memoryGate = memoryGate
    }

    public func warmLoadExactlyRequestedInstances(
        modelRoot: URL,
        cloneProfile: TuringQwenNativeCloneProfile,
        variantID: String,
        performanceMode: TuringQwenNativePerformanceMode
    ) async throws {
        try await TuringQwenNativeMetalCircuitBreaker.shared.requireHealthy()
        print("""
        [TuringQwenFresh2] pool warm load started
          requestedInstanceCount: \(requestedInstanceCount)
          sharedWeights: false
          fallbackAllowed: \(fallbackAllowed)
        """)

        var loaded: [TuringQwenNativeFreshInstance] = []
        do {
            for index in 0..<requestedInstanceCount {
                let id = TuringQwenNativeFreshInstanceID(index: index)
                let memoryDecision = memoryGate.evaluateBeforeWarmLoad(instanceID: id)
                guard memoryDecision.allowed else {
                    print("""
                    [TuringQwenFresh2] failed
                      reason: insufficientMemoryForFreshInstances
                      requestedInstanceCount: \(requestedInstanceCount)
                      createdInstanceCount: \(loaded.count)
                      failedInstanceID: \(id.rawValue)
                      activeMB: \(String(format: "%.1f", memoryDecision.activeMB))
                      cacheMB: \(String(format: "%.1f", memoryDecision.cacheMB))
                      fallbackUsed: false
                    """)
                    throw TuringQwenNativeError.nativeGenerationNotImplemented(
                        "Insufficient memory for \(requestedInstanceCount) fresh Qwen instances."
                    )
                }

                let instance = TuringQwenNativeFreshInstance(id: id)
                try await instance.warmLoad(
                    modelRoot: modelRoot,
                    cloneProfile: cloneProfile,
                    variantID: variantID,
                    performanceMode: performanceMode
                )
                loaded.append(instance)
            }
        } catch {
            if let metalFailure = error as? TuringQwenNativeMetalFailure {
                await TuringQwenNativeMetalCircuitBreaker.shared.trip(metalFailure)
            }
            for instance in loaded {
                await instance.unload()
            }
            actualInstanceCount = 0
            instances.removeAll(keepingCapacity: false)
            availableInstanceIDs.removeAll(keepingCapacity: false)
            print("""
            [TuringQwenFresh2] failed
              reason: couldNotCreateExactlyTwoFreshInstances
              requestedInstanceCount: \(requestedInstanceCount)
              createdInstanceCount: \(loaded.count)
              fallbackUsed: false
            """)
            throw error
        }

        instances = loaded
        actualInstanceCount = loaded.count
        availableInstanceIDs = loaded.map(\.id)

        print("""
        [TuringQwenFresh2] pool ready
          requestedInstanceCount: \(requestedInstanceCount)
          actualInstanceCount: \(actualInstanceCount)
          uniqueResidentResources: \(actualInstanceCount)
          uniqueWeightStores: \(actualInstanceCount)
          sharedWeights: false
          fallbackUsed: false
        """)
    }

    public func warmedInstancesExactlyRequestedCount() throws -> [TuringQwenNativeFreshInstance] {
        guard instances.count == requestedInstanceCount else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "Fresh Qwen requires \(requestedInstanceCount) warm instances; found \(instances.count)."
            )
        }
        return instances
    }

    public func checkout() throws -> TuringQwenNativeFreshInstance {
        guard let id = availableInstanceIDs.first,
              let instance = instances.first(where: { $0.id == id }) else {
            throw TuringQwenNativeError.nativeGenerationNotImplemented(
                "No fresh Qwen instance is available for checkout."
            )
        }
        availableInstanceIDs.removeFirst()
        return instance
    }

    public func checkin(_ instance: TuringQwenNativeFreshInstance) {
        let id = instance.id
        guard availableInstanceIDs.contains(id) == false else { return }
        availableInstanceIDs.append(id)
    }

    public func unloadAll(reason: String) async {
        for instance in instances {
            await instance.unload()
        }
        instances.removeAll(keepingCapacity: false)
        availableInstanceIDs.removeAll(keepingCapacity: false)
        actualInstanceCount = 0
        print("""
        [TuringQwenFresh2] pool unloaded
          reason: \(reason)
          fallbackUsed: false
        """)
    }
}
