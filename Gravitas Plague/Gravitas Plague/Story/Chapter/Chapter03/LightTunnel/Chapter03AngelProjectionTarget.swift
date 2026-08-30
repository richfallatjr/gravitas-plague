import Foundation
import RealityKit

@MainActor
struct Chapter03AngelProjectionTarget {
    let subjectRoot: Entity
    let visualRoot: Entity

    init(angel: Chapter03AngelPortalEntity) {
        subjectRoot = angel.root
        visualRoot = angel.visualRoot
    }
}
