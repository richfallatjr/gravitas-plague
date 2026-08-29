import Foundation
import simd

nonisolated struct MindEyeLayerTransform: Sendable, Equatable {
    var translationPixels: SIMD2<Float>
    var rollRadians: Float
    var scale: Float

    static let identity = MindEyeLayerTransform(
        translationPixels: .zero,
        rollRadians: 0,
        scale: 1
    )

    var isFiniteAndPositive: Bool {
        translationPixels.x.isFinite &&
            translationPixels.y.isFinite &&
            rollRadians.isFinite &&
            scale.isFinite &&
            scale > 0
    }
}

nonisolated enum MindEyeEyeSelection: Sendable, Equatable {
    case open(variantIndex: Int)
    case closed(variantIndex: Int)
}

nonisolated struct MindEyeMouthSelection: Sendable, Equatable {
    let pose: MindEyeMouthPose
    let variantIndex: Int
}

nonisolated enum MindEyeCompositeMaskMode: UInt32, Sendable, Equatable {
    case artistRGB = 0
    case hardRectangleDebug = 1
    case maskPreviewDebug = 2
    case finalAlphaPreviewDebug = 3
}

nonisolated struct MindEyeCompositeFrameState: Sendable, Equatable {
    let sequence: UInt64
    let backgroundTransform: MindEyeLayerTransform
    let characterTransform: MindEyeLayerTransform
    let eyeSelection: MindEyeEyeSelection
    let mouthSelection: MindEyeMouthSelection
    let maskMode: MindEyeCompositeMaskMode

    static func phaseFourResting(
        sequence: UInt64 = 0
    ) -> MindEyeCompositeFrameState {
        MindEyeCompositeFrameState(
            sequence: sequence,
            backgroundTransform: .identity,
            characterTransform: .identity,
            eyeSelection: .open(variantIndex: 0),
            mouthSelection: MindEyeMouthSelection(
                pose: .rest,
                variantIndex: 0
            ),
            maskMode: .artistRGB
        )
    }
}

nonisolated enum MindEyeCompositeFrameStateValidator {
    static func validateBasic(
        _ state: MindEyeCompositeFrameState
    ) -> MindEyeFailure? {
        guard state.backgroundTransform.isFiniteAndPositive,
              state.characterTransform.isFiniteAndPositive else {
            return failure("Composite transforms must be finite with positive scale.")
        }

        let eyeIndex: Int
        switch state.eyeSelection {
        case .open(let variantIndex), .closed(let variantIndex):
            eyeIndex = variantIndex
        }
        guard eyeIndex >= 0, state.mouthSelection.variantIndex >= 0 else {
            return failure("Composite variant indices cannot be negative.")
        }

#if !DEBUG
        guard state.maskMode == .artistRGB else {
            return failure("Debug mask modes are unavailable in production.")
        }
#endif
        return nil
    }

    private static func failure(_ message: String) -> MindEyeFailure {
        MindEyeFailure(
            code: .invalidCompositeFrameState,
            characterID: nil,
            vignetteID: nil,
            resourcePath: nil,
            message: message
        )
    }
}
