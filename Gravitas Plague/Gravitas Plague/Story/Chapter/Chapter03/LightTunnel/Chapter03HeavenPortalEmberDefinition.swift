import Foundation

nonisolated struct Chapter03HeavenPortalEmberDefinition: Codable, Sendable, Equatable {
    let enabled: Bool
    let visemeResourcePath: String
    let sourceCinematicID: String
    let paletteID: String

    func validate() throws {
        guard enabled,
              sourceCinematicID == "chapter03.cinematic.angel.lightTunnel.001",
              paletteID == "heavenPurpleMagentaCyan.v1",
              visemeResourcePath ==
                "Turing/Cinematics/Chapter03/Cues/" +
                "chapter03.cinematic.angel.lightTunnel.001.visemes.json" else {
            throw Chapter03Error.definitionInvalid(
                "Heaven portal ember definition is invalid."
            )
        }
    }
}
