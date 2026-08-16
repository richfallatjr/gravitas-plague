import Foundation

nonisolated enum TuringEpisodeID: String, Codable, CaseIterable, Identifiable, Sendable {
    case prologue
    case chapter01
    case chapter02
    case chapter03

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
        ),
        TuringEpisodeDescriptor(
            id: .chapter01,
            title: "Chapter 1 — Dad?",
            subtitle: "The beacon. The window. The drone.",
            scriptResourcePath: nil,
            availability: .unlocked,
            stripArtwork: .chapter01Strip,
            contentRevision: "chapter01.v1"
        ),
        TuringEpisodeDescriptor(
            id: .chapter02,
            title: "Chapter 2",
            subtitle: "The Night the Lights Went Out",
            scriptResourcePath: nil,
            availability: .unlocked,
            stripArtwork: .chapter02Strip,
            contentRevision: "chapter02.v1"
        ),
        TuringEpisodeDescriptor(
            id: .chapter03,
            title: "Chapter 3",
            subtitle: "Light at the End of the Tunnel",
            scriptResourcePath: nil,
            availability: .unlocked,
            stripArtwork: .chapter03Strip,
            contentRevision: "chapter03.v1"
        )
    ]

    nonisolated static let productionPickerEpisodes = productionEpisodes

    nonisolated static let developmentEpisodes = productionPickerEpisodes

    nonisolated static func descriptor(
        for id: TuringEpisodeID
    ) -> TuringEpisodeDescriptor? {
        return productionPickerEpisodes.first { $0.id == id }
    }

    nonisolated static func nextUnlockedEpisode(
        after episodeID: TuringEpisodeID
    ) -> TuringEpisodeID? {
        guard let index = productionEpisodes.firstIndex(
            where: { $0.id == episodeID }
        ) else {
            return nil
        }
        return productionEpisodes
            .dropFirst(index + 1)
            .first(where: { $0.isUnlocked })?
            .id
    }
}
