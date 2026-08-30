import Foundation

nonisolated struct Chapter03AngelBlendShapeResponse: Sendable, Equatable {
    let openingHalfLifeSeconds: Float
    let closingHalfLifeSeconds: Float
    let crossingHalfLifeSeconds: Float
    let maximumDeltaTimeSeconds: Float
    let assignmentEpsilon: Float

    func step(current: Float, target: Float, deltaTime: Float) -> Float {
        let boundedDelta = min(maximumDeltaTimeSeconds, max(0, deltaTime))
        guard boundedDelta > 0 else { return current }

        let halfLife: Float
        if target == 0, current > target {
            halfLife = closingHalfLifeSeconds
        } else if target > current {
            halfLife = openingHalfLifeSeconds
        } else {
            halfLife = crossingHalfLifeSeconds
        }

        let alpha = 1 - exp2(-boundedDelta / halfLife)
        let result = current + (target - current) * alpha
        if abs(result - target) <= assignmentEpsilon {
            return target
        }
        return min(1, max(0, result))
    }
}
