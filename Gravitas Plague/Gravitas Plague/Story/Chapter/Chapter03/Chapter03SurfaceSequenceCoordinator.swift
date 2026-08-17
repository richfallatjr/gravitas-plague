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
        activate(.chapter03WalkieScavenger, reason: reason)
    }

    func armHam(reason: String) {
        activate(.chapter03HamRevelation, reason: reason)
    }

    func armCrank(reason: String) {
        activate(.chapter03CrankContinuity, reason: reason)
    }

    private func activate(
        _ binding: TuringStorySurfaceFlowBinding,
        reason: String
    ) {
        closeAll(reason: "\(reason).closePrior")
        let mode = StoryExperienceModeController.shared.modeForNewStoryAction()
        StoryModeActionCoordinator.shared.activate(
            .init(
                episodeID: .chapter03,
                rootScriptPointID: binding.rootScriptPointID,
                durableBoundaryID: "chapter03.\(reason).\(binding.rootScriptPointID)",
                sourceEventID: UUID()
            ),
            mode: mode,
            interactiveArm: { [weak self] in
                guard let self else { return }
                switch binding.interactionSurface {
                case .walkie:
                    self.walkie.bind(binding, initialState: .play, reason: reason)
                case .hamReceiver:
                    self.hamReceiver.bind(binding, initialState: .play, reason: reason)
                case .crankRadio:
                    self.crankRadio.bind(binding, initialState: .play, reason: reason)
                case .dadFrame:
                    break
                }
            }
        )
    }
}
