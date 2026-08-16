import Foundation

@MainActor
final class Chapter03SurfaceSequenceCoordinator {
    private let walkie: TuringStoryWalkieInteractionController
    private let hamReceiver: TuringStoryHamReceiverInteractionController
    private let crankRadio: TuringStoryCrankRadioInteractionController

    init(
        walkie: TuringStoryWalkieInteractionController,
        hamReceiver: TuringStoryHamReceiverInteractionController,
        crankRadio: TuringStoryCrankRadioInteractionController
    ) {
        self.walkie = walkie
        self.hamReceiver = hamReceiver
        self.crankRadio = crankRadio
    }

    func closeAll(reason: String) {
        walkie.bind(.chapter03WalkieScavenger, initialState: .closed, reason: reason)
        hamReceiver.bind(.chapter03HamRevelation, initialState: .closed, reason: reason)
        crankRadio.bind(.chapter03CrankContinuity, initialState: .closed, reason: reason)
    }

    func armWalkie(reason: String) {
        closeAll(reason: "\(reason).closePrior")
        walkie.bind(.chapter03WalkieScavenger, initialState: .play, reason: reason)
    }

    func armHam(reason: String) {
        closeAll(reason: "\(reason).closePrior")
        hamReceiver.bind(.chapter03HamRevelation, initialState: .play, reason: reason)
    }

    func armCrank(reason: String) {
        closeAll(reason: "\(reason).closePrior")
        crankRadio.bind(.chapter03CrankContinuity, initialState: .play, reason: reason)
    }
}
