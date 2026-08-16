import Foundation

struct StoryTitleCardDescriptor: Sendable, Hashable {
    enum CardID: String, Sendable, Hashable {
        case prologue
        case chapter01
        case chapter02
        case chapter03
        case endOfAvailableContent
    }

    let id: CardID
    let title: String
    let subtitle: String?
    let fadeToBlackSeconds: Duration
    let holdSeconds: Duration
    let fadeFromBlackSeconds: Duration
}
