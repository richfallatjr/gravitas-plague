import Foundation

nonisolated struct Chapter03AngelProjectionReadiness: Sendable, Equatable {
    let cameraReady: Bool
    let materialReady: Bool
    let textureReady: Bool
    let maskReady: Bool
    let blendShapeReady: Bool

    var isVisualProjectionReady: Bool {
        cameraReady && materialReady && textureReady && maskReady
    }

    var isReady: Bool {
        isVisualProjectionReady && blendShapeReady
    }

    static let unavailable = Chapter03AngelProjectionReadiness(
        cameraReady: false,
        materialReady: false,
        textureReady: false,
        maskReady: false,
        blendShapeReady: false
    )
}
