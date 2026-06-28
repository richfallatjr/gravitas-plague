import Foundation

enum TuringEpisodeID: String, Codable, CaseIterable, Identifiable, Sendable {
    case prologue

    nonisolated var id: String { rawValue }
}

struct TuringEpisodeDescriptor: Identifiable, Sendable, Equatable {
    let id: TuringEpisodeID
    let title: String
    let subtitle: String
    let scriptResourcePath: String
    let isUnlocked: Bool
}

enum TuringEpisodeCatalog {
    nonisolated static let developmentEpisodes: [TuringEpisodeDescriptor] = [
        TuringEpisodeDescriptor(
            id: .prologue,
            title: "Prologue",
            subtitle: "Turing system test bed",
            scriptResourcePath: "Turing/Scripts/Prologue/prologue.json",
            isUnlocked: true
        )
    ]

    nonisolated static func descriptor(
        for id: TuringEpisodeID
    ) -> TuringEpisodeDescriptor? {
        developmentEpisodes.first { $0.id == id }
    }
}
