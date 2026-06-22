import RealityKit
import simd

extension TransformValue {
    var realityKitTransform: Transform {
        Transform(
            scale: scale,
            rotation: simd_quatf(
                vector: rotation.xyzw
            ),
            translation: translation
        )
    }
}
