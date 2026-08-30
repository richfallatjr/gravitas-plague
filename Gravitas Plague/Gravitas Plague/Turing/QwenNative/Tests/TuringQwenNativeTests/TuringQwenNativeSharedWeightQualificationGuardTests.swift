#if GR_TURING_QUALIFICATION
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeSharedWeightQualificationGuardTests {
    @Test
    func deterministicIndicesCoverBoundariesAndSeededInterior() throws {
        let first = try TuringQwenNativeSharedWeightQualificationSnapshot
            .deterministicScalarIndices(count: 1_024, key: "representative.weight")
        let second = try TuringQwenNativeSharedWeightQualificationSnapshot
            .deterministicScalarIndices(count: 1_024, key: "representative.weight")

        #expect(first == second)
        #expect(first[0] == 0)
        #expect(first[1] == 512)
        #expect(first[2] == 1_023)
        #expect((1..<1_023).contains(first[3]))
    }

    @Test
    func singleLaneControlConstructsOnlyItsQualificationTopology() async throws {
        let pool = try TuringQwenNativeSingleLaneResidencyControl
            .makeQualificationPool()

        #expect(await pool.requestedInstanceCount == 1)
        #expect(await pool.residencyMode == .singleLaneSharedControl)
        #expect(await pool.fallbackAllowed == false)
    }
}
#endif
