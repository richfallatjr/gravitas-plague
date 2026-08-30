import Testing

@testable import TuringQwenNative

struct TuringQwenNativeResidencyPhase1IntegrationTests {
    @Test
    func residencyModesDoNotChangeTwoLeaseAdmissionPolicy() throws {
        for mode in [
            TuringQwenNativeResidencyMode.independentFresh2,
            .sharedImmutableFresh2,
        ] {
            let policy = try TuringQwenNativeGPUAdmissionPolicy(
                mode: .currentOverlap,
                maximumConcurrentGenerationLeases: mode.laneCount,
                decoderHasPriority: true
            )
            #expect(policy.maximumConcurrentGenerationLeases == 2)
        }
    }
}
