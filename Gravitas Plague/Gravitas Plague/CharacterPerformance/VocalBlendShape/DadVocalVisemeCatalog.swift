import Foundation

nonisolated struct CharacterVocalVisemeCatalog: Decodable, Sendable, Equatable {
    struct Entry: Decodable, Sendable, Equatable {
        let role: CharacterVocalRole
        let audioFile: String
        let audioSHA256: String
        let looping: Bool
        let manifestResourcePath: String
    }

    let schemaVersion: Int
    let catalogID: String
    let characterID: String
    let compilerVersion: String
    let entries: [Entry]
}

