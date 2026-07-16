import Foundation

enum TuringEpisodeID: String, Codable, CaseIterable, Identifiable, Sendable {
    case prologue

    nonisolated var id: String { rawValue }
}

struct TuringEpisodeDescriptor: Identifiable, Sendable, Equatable {
    enum Availability: Sendable, Equatable {
        case unlocked
        case locked(reason: String)
        case comingSoon
    }

    let id: TuringEpisodeID
    let title: String
    let subtitle: String
    let scriptResourcePath: String?
    let availability: Availability
    let stripArtwork: TuringEpisodeStripArtwork
    let contentRevision: String

    var isUnlocked: Bool {
        availability == .unlocked
    }
}

enum TuringEpisodeCatalog {
    nonisolated static let productionEpisodes: [TuringEpisodeDescriptor] = [
        TuringEpisodeDescriptor(
            id: .prologue,
            title: "Prologue",
            subtitle: "They are not human—they are monsters",
            scriptResourcePath: "Turing/Scripts/Prologue/prologue.json",
            availability: .unlocked,
            stripArtwork: .prologueStrip,
            contentRevision: "prologue.v1"
        )
    ]

    nonisolated static let developmentEpisodes = productionEpisodes

    nonisolated static func descriptor(
        for id: TuringEpisodeID
    ) -> TuringEpisodeDescriptor? {
        productionEpisodes.first { $0.id == id }
    }
}
