import Combine
import Foundation
import QuartzCore
import SwiftUI

@MainActor
final class DeathPresentationController: ObservableObject {
    @Published private(set) var blackoutOpacity: Double = 0.0
    @Published private(set) var isActive = false

    private var blackoutTask: Task<Void, Never>?
    private var activeTitleRequestID: UUID?

    var surroundingsEffect: SurroundingsEffect? {
        guard isActive || blackoutOpacity > 0.0001 else {
            return nil
        }

        let clamped = max(0.0, min(blackoutOpacity, 1.0))
        let multiplier = max(0.0, min(1.0, 1.0 - clamped))

        return .colorMultiply(
            Color(
                red: multiplier,
                green: multiplier,
                blue: multiplier
            )
        )
    }

    func playDeathBlackoutSequence(
        onFinalDarkReached: @escaping @MainActor () -> Void
    ) {
        blackoutTask?.cancel()
        activeTitleRequestID = nil

        blackoutTask = Task { @MainActor in
            isActive = true
            blackoutOpacity = 0.0

            await animateOpacity(to: 0.80, duration: 0.18)
            await animateOpacity(to: 0.20, duration: 0.22)
            await animateOpacity(to: 0.90, duration: 0.35)

            guard !Task.isCancelled else { return }

            blackoutOpacity = 0.90
            onFinalDarkReached()

            print("[PlayerDeath] blackout sequence complete at 90%")
        }
    }

    func fadeBackUp(
        duration: TimeInterval = 1.25,
        onCompleted: @escaping @MainActor () -> Void = {}
    ) {
        blackoutTask?.cancel()

        blackoutTask = Task { @MainActor in
            await animateOpacity(to: 0.0, duration: duration)

            guard !Task.isCancelled else { return }

            blackoutOpacity = 0.0
            isActive = false
            onCompleted()
        }
    }

    func fadeToFullBlack(
        duration: Duration,
        requestID: UUID
    ) async throws {
        blackoutTask?.cancel()
        blackoutTask = nil
        activeTitleRequestID = requestID
        isActive = true
        try await animateOpacityThrowing(
            to: 1.0,
            duration: duration.timeInterval
        )
        try requireCurrentTitleRequest(requestID)
        blackoutOpacity = 1.0
    }

    func fadeBackUp(
        duration: Duration,
        requestID: UUID
    ) async throws {
        try requireCurrentTitleRequest(requestID)
        try await animateOpacityThrowing(
            to: 0.0,
            duration: duration.timeInterval
        )
        try requireCurrentTitleRequest(requestID)
        blackoutOpacity = 0.0
        isActive = false
        activeTitleRequestID = nil
    }

    func cancelTitleTransition(
        requestID: UUID,
        restoreImmediately: Bool
    ) {
        guard activeTitleRequestID == requestID else { return }
        activeTitleRequestID = nil
        if restoreImmediately {
            blackoutOpacity = 0.0
            isActive = false
        }
    }

    func reset() {
        blackoutTask?.cancel()
        blackoutTask = nil
        activeTitleRequestID = nil
        blackoutOpacity = 0.0
        isActive = false
    }

    private func animateOpacity(
        to target: Double,
        duration: TimeInterval
    ) async {
        let start = blackoutOpacity
        let startTime = CACurrentMediaTime()

        while !Task.isCancelled {
            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(1.0, elapsed / max(duration, 0.001))
            let eased = progress * progress * (3.0 - 2.0 * progress)

            blackoutOpacity = start + (target - start) * eased

            if progress >= 1.0 {
                break
            }

            try? await Task.sleep(nanoseconds: 16_000_000)
        }
    }

    private func animateOpacityThrowing(
        to target: Double,
        duration: TimeInterval
    ) async throws {
        let start = blackoutOpacity
        let startTime = CACurrentMediaTime()

        while true {
            try Task.checkCancellation()
            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(1.0, elapsed / max(duration, 0.001))
            let eased = progress * progress * (3.0 - 2.0 * progress)
            blackoutOpacity = start + (target - start) * eased

            if progress >= 1.0 {
                return
            }
            try await Task.sleep(for: .milliseconds(16))
        }
    }

    private func requireCurrentTitleRequest(
        _ requestID: UUID
    ) throws {
        guard activeTitleRequestID == requestID else {
            throw StoryTitleCardError.staleRequest
        }
    }
}

typealias ImmersiveBlackoutController = DeathPresentationController

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return TimeInterval(components.seconds) +
            TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
