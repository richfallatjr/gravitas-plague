import Foundation

@MainActor
final class Chapter02SurfaceSequenceCoordinator {
    private let walkie: TuringStoryWalkieInteractionController
    private let dadFrame: TuringStoryDadFrameInteractionController
    private let crankRadio: TuringStoryCrankRadioInteractionController
    private let hamReceiver: TuringStoryHamReceiverInteractionController

    init(
        walkie: TuringStoryWalkieInteractionController,
        dadFrame: TuringStoryDadFrameInteractionController,
        crankRadio: TuringStoryCrankRadioInteractionController,
        hamReceiver: TuringStoryHamReceiverInteractionController
    ) {
        self.walkie = walkie
        self.dadFrame = dadFrame
        self.crankRadio = crankRadio
        self.hamReceiver = hamReceiver
    }

    func armMissingPersons(reason: String) {
        arm(.chapter02CrankMissingPersons, reason: reason)
    }

    func armDadHam(reason: String) {
        arm(.chapter02DadHam, reason: reason)
    }

    func armBigMikeWalkie(reason: String) {
        arm(.chapter02BigMikeWalkie, reason: reason)
    }

    func armDadPhoto(reason: String) {
        arm(.chapter02DadPhoto, reason: reason)
    }

    func armGridFailure(reason: String) {
        arm(.chapter02CrankGridFailure, reason: reason)
    }

    func armPostBattleHam(reason: String) {
        arm(.chapter02PostBattleHam, reason: reason)
    }

    func armGravitasPSA(reason: String) {
        arm(.chapter02CrankGravitasPSA, reason: reason)
    }

    func closeAll(reason: String) {
        walkie.bind(
            .chapter02BigMikeWalkie,
            initialState: .closed,
            reason: reason
        )
        dadFrame.bind(
            .chapter02DadPhoto,
            initialState: .closed,
            reason: reason
        )
        crankRadio.bind(
            .chapter02CrankMissingPersons,
            initialState: .closed,
            reason: reason
        )
        hamReceiver.bind(
            .chapter02DadHam,
            initialState: .closed,
            reason: reason
        )
    }

    func restore(
        checkpoint: Chapter02Checkpoint,
        reason: String
    ) {
        switch checkpoint {
        case .root:
            armMissingPersons(reason: reason)
        case .missingPersonsCompleted:
            armDadHam(reason: reason)
        case .dadHamCompleted:
            armBigMikeWalkie(reason: reason)
        case .bigMikeWalkieCompleted:
            armDadPhoto(reason: reason)
        case .dadPhotoCompleted:
            armGridFailure(reason: reason)
        case .womanBattleCompleted:
            armPostBattleHam(reason: reason)
        case .postBattleHamCompleted:
            armGravitasPSA(reason: reason)
        case .blackoutBroadcastCompleted,
             .womanExitPending,
             .womanBattlePending,
             .gravitasPSACompleted,
             .complete:
            closeAll(reason: reason)
        }
    }

    private func arm(
        _ binding: TuringStorySurfaceFlowBinding,
        reason: String
    ) {
        closeAll(reason: "\(reason).closePrior")
        switch binding.interactionSurface {
        case .walkie:
            walkie.bind(binding, initialState: .play, reason: reason)
        case .dadFrame:
            dadFrame.bind(binding, initialState: .play, reason: reason)
        case .crankRadio:
            crankRadio.bind(binding, initialState: .play, reason: reason)
        case .hamReceiver:
            hamReceiver.bind(binding, initialState: .play, reason: reason)
        default:
            preconditionFailure(
                "Unsupported Chapter 2 interaction surface \(binding.interactionSurface.rawValue)"
            )
        }
        print(
            "[Chapter02] surface armed surface=\(binding.interactionSurface.rawValue) " +
                "root=\(binding.rootScriptPointID) reason=\(reason)"
        )
    }
}
