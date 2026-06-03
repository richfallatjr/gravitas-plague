import Combine
import SwiftUI

@MainActor
final class DamageSurroundingsTintController: ObservableObject {
    @Published private(set) var tintAmount: Double = 0.0

    private var flashTask: Task<Void, Never>?

    private let fadeInSeconds: Double = 0.045
    private let holdSeconds: Double = 0.10
    private let fadeOutSeconds: Double = 0.55

    var surroundingsEffect: SurroundingsEffect? {
        guard tintAmount > 0.001 else {
            return nil
        }

        let clamped = max(0.0, min(tintAmount, 1.0))
        let red = 1.0
        let green = 1.0 - (0.78 * clamped)
        let blue = 1.0 - (0.78 * clamped)

        return .colorMultiply(
            Color(
                red: red,
                green: max(0.0, green),
                blue: max(0.0, blue)
            )
        )
    }

    func trigger(intensity: Double) {
        let clampedIntensity = max(0.0, min(intensity, 1.0))

        flashTask?.cancel()

        flashTask = Task { @MainActor in
            tintAmount = 0.0

            withAnimation(.linear(duration: fadeInSeconds)) {
                tintAmount = clampedIntensity
            }

            try? await Task.sleep(
                nanoseconds: UInt64((fadeInSeconds + holdSeconds) * 1_000_000_000)
            )

            guard !Task.isCancelled else { return }

            withAnimation(.easeOut(duration: fadeOutSeconds)) {
                tintAmount = 0.0
            }
        }
    }

    func reset() {
        flashTask?.cancel()
        flashTask = nil

        withAnimation(.easeOut(duration: 0.12)) {
            tintAmount = 0.0
        }
    }
}
