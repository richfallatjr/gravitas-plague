import Foundation
import MLX
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeResidencyPhase2IntegrationTests {
    @Test
    func commandBufferContextCarriesResidencyOwnership() {
        let owner = UUID().uuidString
        let weights = UUID().uuidString
        let mutable = UUID().uuidString
        let context = TuringMetalExecutionContext(
            runID: "phase3",
            instanceID: "fresh-0",
            phase: "dynamicTalker",
            residencyOwnerID: owner,
            weightStoreID: weights,
            laneMutableStateID: mutable
        )
        #expect(context.residencyOwnerID == owner)
        #expect(context.weightStoreID == weights)
        #expect(context.laneMutableStateID == mutable)
    }
}
