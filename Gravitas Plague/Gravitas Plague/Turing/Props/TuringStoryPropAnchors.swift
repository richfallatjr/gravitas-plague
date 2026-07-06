import Foundation
import RealityKit

enum TuringStoryPropRole: String, Codable, Sendable {
    case walkieTalkie
    case dadFrame
}

struct TuringStoryPropInteractionAnchor: Sendable {
    let id: String
    let entity: Entity
    let role: TuringStoryPropRole
}

enum TuringScriptTriggerTarget: String, Codable, Sendable {
    case walkieTalkie
    case dadFrame
}

struct TuringScriptTriggerAnchor: Sendable {
    let target: TuringScriptTriggerTarget
    let entityName: String
}
