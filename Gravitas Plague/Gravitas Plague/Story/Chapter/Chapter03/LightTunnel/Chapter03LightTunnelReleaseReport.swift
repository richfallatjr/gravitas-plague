nonisolated struct Chapter03LightTunnelReleaseReport: Sendable, Equatable {
    let rootEntityCount: Int
    let modelEntityCount: Int
    let activeMusicPlayerCount: Int
    let activeMusicTimeObserverCount: Int
    let activeAngelPlaybackControllerCount: Int
    let activeAngelResourceCount: Int
    let activeTaskCount: Int
    let cinematicOwnerReleased: Bool

    var isReleased: Bool {
        rootEntityCount == 0 &&
            modelEntityCount == 0 &&
            activeMusicPlayerCount == 0 &&
            activeMusicTimeObserverCount == 0 &&
            activeAngelPlaybackControllerCount == 0 &&
            activeAngelResourceCount == 0 &&
            activeTaskCount == 0 &&
            cinematicOwnerReleased
    }
}
