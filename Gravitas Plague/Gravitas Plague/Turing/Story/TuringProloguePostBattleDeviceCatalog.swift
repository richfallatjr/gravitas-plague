import Foundation

nonisolated enum ProloguePostBattleDeviceID:
    String,
    Codable,
    CaseIterable,
    Sendable,
    Hashable
{
    case walkie
    case dadPhoto
    case crankRadio
    case hamReceiver
}

nonisolated enum ProloguePostBattleTerminalTriggerRequirement: Sendable, Equatable {
    case userPlay
    case priorScriptPointCompleted(parentScriptPointID: String)

    func matches(_ actual: TuringFlowTriggerSource) -> Bool {
        switch (self, actual) {
        case (.userPlay, .userPlay):
            return true
        case (
            .priorScriptPointCompleted(let expectedParent),
            .priorScriptPointCompleted(let actualParent)
        ):
            return expectedParent == actualParent
        default:
            return false
        }
    }
}

nonisolated struct ProloguePostBattleDeviceContract: Sendable, Equatable {
    let deviceID: ProloguePostBattleDeviceID
    let interactionSurface: StoryInteractionSurfaceID
    let rootScriptPointID: String
    let terminalScriptPointID: String
    let terminalTrigger: ProloguePostBattleTerminalTriggerRequirement
    let flowBinding: TuringStorySurfaceFlowBinding

    var playCapability: StoryInteractionCapability {
        switch interactionSurface {
        case .walkie:
            return .walkiePlay
        case .dadFrame:
            return .dadFramePlay
        case .crankRadio:
            return .crankRadioPlay
        case .hamReceiver:
            return .hamReceiverPlay
        }
    }
}

nonisolated enum TuringProloguePostBattleDeviceCatalog {
    static let walkie = ProloguePostBattleDeviceContract(
        deviceID: .walkie,
        interactionSurface: .walkie,
        rootScriptPointID: "prologue.scriptPoint04",
        terminalScriptPointID: "prologue.scriptPoint05",
        terminalTrigger: .priorScriptPointCompleted(
            parentScriptPointID: "prologue.scriptPoint04"
        ),
        flowBinding: .prologuePostBattleWalkie
    )

    static let dadPhoto = ProloguePostBattleDeviceContract(
        deviceID: .dadPhoto,
        interactionSurface: .dadFrame,
        rootScriptPointID: "prologue.dadPhotoMemory.001",
        terminalScriptPointID: "prologue.dadPhotoMemory.001",
        terminalTrigger: .userPlay,
        flowBinding: .prologueDadPhoto
    )

    static let crankRadio = ProloguePostBattleDeviceContract(
        deviceID: .crankRadio,
        interactionSurface: .crankRadio,
        rootScriptPointID: "prologue.crankRadioBroadcast.001",
        terminalScriptPointID: "prologue.crankRadioBroadcast.001",
        terminalTrigger: .userPlay,
        flowBinding: .prologueCrankRadio
    )

    static let hamReceiver = ProloguePostBattleDeviceContract(
        deviceID: .hamReceiver,
        interactionSurface: .hamReceiver,
        rootScriptPointID: "prologue.hamReceiver.cateye81.001",
        terminalScriptPointID: "prologue.hamReceiver.cateye81.003",
        terminalTrigger: .priorScriptPointCompleted(
            parentScriptPointID: "prologue.hamReceiver.rich.002"
        ),
        flowBinding: .prologueHamReceiver
    )

    static let ordered: [ProloguePostBattleDeviceContract] = [
        walkie,
        dadPhoto,
        crankRadio,
        hamReceiver
    ]

    static let byID = Dictionary(
        uniqueKeysWithValues: ordered.map { ($0.deviceID, $0) }
    )

    static let byRootScriptPointID = Dictionary(
        uniqueKeysWithValues: ordered.map { ($0.rootScriptPointID, $0) }
    )

    static let byTerminalScriptPointID = Dictionary(
        uniqueKeysWithValues: ordered.map { ($0.terminalScriptPointID, $0) }
    )
}
