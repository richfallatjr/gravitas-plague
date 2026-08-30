import Foundation
import Testing

@testable import TuringQwenNative

struct TuringQwenNativeSharedWeightReadOnlyTests {
    @Test
    func sharedIdentityKeepsOneWeightStoreIdentity() {
        let weightStoreID = UUID()
        let identity = TuringQwenNativeResidencyIdentity(
            ownerID: UUID(),
            generation: 1,
            modelID: "qwen3-tts-12hz-1.7b-base-4bit",
            quantization: "4bit",
            standardizedModelRootPath: "/model",
            voiceID: "big_mike",
            variantID: "default",
            weightStoreID: weightStoreID,
            cloneConditioningID: UUID()
        )
        #expect(identity.weightStoreID == weightStoreID)
    }
}
