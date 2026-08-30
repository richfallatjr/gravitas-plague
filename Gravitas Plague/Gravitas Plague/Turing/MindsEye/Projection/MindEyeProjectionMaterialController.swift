import Foundation
import RealityKit

@MainActor
final class MindEyeProjectionMaterialController {
    private(set) var appliedMaterialCount = 0

    func release() {
        appliedMaterialCount = 0
    }
}
