import Foundation

nonisolated struct StoryPlayModeTreatment: Sendable, Equatable {
    struct Audit: Sendable, Equatable {
        let skippedPrimaryPrerecordingID: String
        let skippedGeneratedStageIDs: [String]
    }

    enum AuthoredMediaPolicy: Sendable, Equatable {
        case standard
        case replaceWithPrerecordings([String])
    }

    let rootScriptPointID: String
    let authoredMediaPolicy: AuthoredMediaPolicy
    let audit: Audit?
}

nonisolated enum StoryPlayModeTreatmentCatalog {
    static let prologueScriptPoint05 = StoryPlayModeTreatment(
        rootScriptPointID: "prologue.scriptPoint05",
        authoredMediaPolicy: .replaceWithPrerecordings([
            "prologue.walkie.bigMike.scriptPoint05.002"
        ]),
        audit: .init(
            skippedPrimaryPrerecordingID:
                "prologue.walkie.bigMike.scriptPoint05.001",
            skippedGeneratedStageIDs: ["headlineReading", "promptVoice"]
        )
    )

    static func treatment(for scriptPointID: String) -> StoryPlayModeTreatment {
        if scriptPointID == prologueScriptPoint05.rootScriptPointID {
            return prologueScriptPoint05
        }
        return StoryPlayModeTreatment(
            rootScriptPointID: scriptPointID,
            authoredMediaPolicy: .standard,
            audit: nil
        )
    }
}
