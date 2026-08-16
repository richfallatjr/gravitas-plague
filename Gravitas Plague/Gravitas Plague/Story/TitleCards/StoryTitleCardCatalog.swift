import Foundation

enum StoryTitleCardCatalog {
    static let prologue = StoryTitleCardDescriptor(
        id: .prologue,
        title: "Prologue",
        subtitle: "They are not human they are monsters",
        fadeToBlackSeconds: .milliseconds(750),
        holdSeconds: .milliseconds(7_500),
        fadeFromBlackSeconds: .milliseconds(750)
    )

    static let chapter01 = StoryTitleCardDescriptor(
        id: .chapter01,
        title: "Chapter 1",
        subtitle: "Dad?",
        fadeToBlackSeconds: .milliseconds(750),
        holdSeconds: .milliseconds(7_500),
        fadeFromBlackSeconds: .milliseconds(750)
    )

    static let chapter02 = StoryTitleCardDescriptor(
        id: .chapter02,
        title: "Chapter 2",
        subtitle: "The Night the Lights Went Out",
        fadeToBlackSeconds: .milliseconds(750),
        holdSeconds: .milliseconds(7_500),
        fadeFromBlackSeconds: .milliseconds(750)
    )

    static let chapter03LightTunnelTest = StoryTitleCardDescriptor(
        id: .chapter03,
        title: "Chapter 3",
        subtitle: "Light at the End of the Tunnel",
        fadeToBlackSeconds: .milliseconds(750),
        holdSeconds: .milliseconds(5_000),
        fadeFromBlackSeconds: .milliseconds(750)
    )

    static let endOfAvailableContent = StoryTitleCardDescriptor(
        id: .endOfAvailableContent,
        title: "Gravitas Plague",
        subtitle: nil,
        fadeToBlackSeconds: .milliseconds(750),
        holdSeconds: .milliseconds(9_000),
        fadeFromBlackSeconds: .milliseconds(750)
    )

    static func descriptor(
        for episodeID: TuringEpisodeID
    ) -> StoryTitleCardDescriptor {
        switch episodeID {
        case .prologue:
            return prologue
        case .chapter01:
            return chapter01
        case .chapter02:
            return chapter02
        case .chapter03:
            return chapter03LightTunnelTest
        }
    }
}
