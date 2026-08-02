import Foundation

struct TuringStorySurfaceFlowBinding: Sendable, Equatable {
    let rootScriptPointID: String
    let terminalScriptPointID: String
    let conversationKey: String
    let conversationCharacterID: String
    let conversationOutputRoute: TuringVoiceOutputContext
    let interactionSurface: StoryInteractionSurfaceID
}

extension TuringStorySurfaceFlowBinding {
    static let prologueDadPhoto = Self(
        rootScriptPointID: "prologue.dadPhotoMemory.001",
        terminalScriptPointID: "prologue.dadPhotoMemory.001",
        conversationKey: "object.dad_frame",
        conversationCharacterID: "rich",
        conversationOutputRoute: .roomGlobal,
        interactionSurface: .dadFrame
    )

    static let prologueWalkie = Self(
        rootScriptPointID: "prologue.scriptPoint01",
        terminalScriptPointID: "prologue.scriptPoint05",
        conversationKey: TuringDialogueThreadIdentity.bigMikeRich,
        conversationCharacterID: TuringBigMikeVoiceIdentity.characterID,
        conversationOutputRoute: .walkieSpatial,
        interactionSurface: .walkie
    )

    static let chapter01OpeningWalkie = Self(
        rootScriptPointID: "chapter01.walkie.rich.script06",
        terminalScriptPointID: "chapter01.walkie.bigMike.script07",
        conversationKey: TuringDialogueThreadIdentity.bigMikeRich,
        conversationCharacterID: TuringBigMikeVoiceIdentity.characterID,
        conversationOutputRoute: .walkieSpatial,
        interactionSurface: .walkie
    )

    static let prologueHamReceiver = Self(
        rootScriptPointID: "prologue.hamReceiver.cateye81.001",
        terminalScriptPointID: "prologue.hamReceiver.cateye81.003",
        conversationKey: "object.ham_receiver",
        conversationCharacterID: TuringCatEye81VoiceIdentity.characterID,
        conversationOutputRoute: .hamReceiverSpatial,
        interactionSurface: .hamReceiver
    )

    static let chapter01FourChancesDad = Self(
        rootScriptPointID: "chapter01.dadFrame.rich.fourChances.001",
        terminalScriptPointID: "chapter01.dadFrame.rich.fourChances.001",
        conversationKey: "chapter01.object.dad_frame.four_chances",
        conversationCharacterID: "rich",
        conversationOutputRoute: .roomGlobal,
        interactionSurface: .dadFrame
    )

    static let chapter01DadEulogyScript03 = Self(
        rootScriptPointID: "chapter01.dadFrame.rich.script03",
        terminalScriptPointID: "chapter01.dadFrame.rich.script03",
        conversationKey: "chapter01.object.dad_frame.eulogy",
        conversationCharacterID: "rich",
        conversationOutputRoute: .roomGlobal,
        interactionSurface: .dadFrame
    )

    static let chapter01FourChancesWalkie = Self(
        rootScriptPointID: "chapter01.walkie.rich.script08",
        terminalScriptPointID: "chapter01.walkie.bigMike.script09",
        conversationKey: "chapter01.dialogue.big_mike.rich.four_chances",
        conversationCharacterID: TuringBigMikeVoiceIdentity.characterID,
        conversationOutputRoute: .walkieSpatial,
        interactionSurface: .walkie
    )

    static let chapter01FourChancesHam = Self(
        rootScriptPointID: "chapter01.hamReceiver.rich.script04",
        terminalScriptPointID: "chapter01.hamReceiver.cateye81.script05",
        conversationKey: "chapter01.object.ham_receiver.four_chances",
        conversationCharacterID: TuringCatEye81VoiceIdentity.characterID,
        conversationOutputRoute: .hamReceiverSpatial,
        interactionSurface: .hamReceiver
    )
}
