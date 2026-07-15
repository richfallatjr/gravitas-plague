import Combine
import Darwin
import Foundation
import RealityKit
import SwiftUI
import UIKit
import simd

struct PlagueImmersiveView: View {
    @ObservedObject var session: PlagueDemoSession
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @StateObject private var coordinator = PlagueImmersiveCoordinator()
    @StateObject private var damageTintController = DamageSurroundingsTintController()
    @StateObject private var deathPresentationController = DeathPresentationController()
    @State private var youDiedWorldAnchor: AnchorEntity?
    @State private var youDiedWorldCardPresenter = YouDiedWorldCardPresenter()
    @State private var placementAdjustmentDragActive = false

    private let frameTimer = Timer.publish(
        every: 1.0 / 60.0,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        RealityView { content in
            let sceneRoot = await coordinator.makeSceneRoot(
                initialAtmosphere: session.forestAtmosphere,
                atmosphereRevision: session.forestAtmosphereRevision
            )
            content.add(sceneRoot)
            content.add(coordinator.makeHeadAnchor())

            let youDiedWorldAnchor = AnchorEntity(
                world: SIMD3<Float>(0, 0, 0)
            )
            youDiedWorldAnchor.name = "YouDiedWorldAnchor"
            content.add(youDiedWorldAnchor)
            self.youDiedWorldAnchor = youDiedWorldAnchor

            youDiedWorldCardPresenter.bind(
                worldAnchor: youDiedWorldAnchor
            )

            let presenter = youDiedWorldCardPresenter

            coordinator.onYouDiedWorldCardRequested = { originFromDevice in
                Task { @MainActor in
                    await presenter.show(
                        originFromDevice: originFromDevice,
                        textureName: "you_died",
                        width: 1.0,
                        distanceMeters: 1.5
                    )
                }
            }

            coordinator.onYouDiedWorldCardCleanupRequested = {
                Task { @MainActor in
                    presenter.remove()
                }
            }
        } update: { _ in }
        .gesture(
            DragGesture(minimumDistance: 0)
                .targetedToEntity(where: .has(PortalDoorHandleComponent.self))
                .onChanged { value in
                    let scenePoint = value.convert(
                        value.location3D,
                        from: .local,
                        to: .scene
                    )

                    let worldPoint = SIMD3<Float>(
                        Float(scenePoint.x),
                        Float(scenePoint.y),
                        Float(scenePoint.z)
                    )

                    if coordinator.isDoorHandleDragActive {
                        coordinator.updateDoorHandleDrag(
                            worldPoint: worldPoint
                        )
                    } else {
                        coordinator.beginDoorHandleDrag(
                            worldPoint: worldPoint
                        )
                    }
                }
                .onEnded { _ in
                    coordinator.endDoorHandleDrag(
                        shouldConfirm: true
                    )
                }
        )
        .simultaneousGesture(
            TapGesture()
                .targetedToEntity(where: .has(WallPosterUIButtonComponent.self))
                .onEnded { value in
                    guard let component = value.entity.components[WallPosterUIButtonComponent.self],
                          let action = component.action else {
                        return
                    }

                    session.handleWallPosterAction(action)

                    if action == .story,
                       PlagueFeatureFlags.showStoryEpisodePicker {
                        openWindow(id: PlagueWindowID.storyDebug)
                        print("""
                        [TuringStory] Story debug window opened from wall poster
                          windowID: \(PlagueWindowID.storyDebug)
                        """)
                    }
                }
        )
        .simultaneousGesture(
            TapGesture()
                .targetedToEntity(where: .has(WallPosterKillSwitchComponent.self))
                .onEnded { _ in
                    Task { @MainActor in
                        session.requestImmediateQuitFromRealityKitKillSwitch(
                            reason: "wall_poster_x_decorator"
                        )
                        await dismissImmersiveSpace()
                        Darwin.exit(0)
                    }
                }
        )
        .simultaneousGesture(
            TapGesture()
                .targetedToEntity(where: .has(WallPosterLeaderboardButtonComponent.self))
                .onEnded { _ in
                    Task { @MainActor in
                        session.showGameCenterLeaderboards()
                    }
                }
        )
        .simultaneousGesture(
            TapGesture()
                .targetedToEntity(where: .has(TuringStoryDayNightPosterButtonComponent.self))
                .onEnded { _ in
                    Task { @MainActor in
                        session.togglePortalHDRIAtmosphere()
                    }
                }
        )
        .simultaneousGesture(
            TapGesture()
                .targetedToEntity(where: .has(TuringStoryDoorTriggerComponent.self))
                .onEnded { _ in
                    Task { @MainActor in
                        coordinator.toggleTuringStoryDoor(
                            reason: "doorIconTapped"
                        )
                    }
                }
        )
        .simultaneousGesture(
            TapGesture()
                .targetedToEntity(
                    where: .has(TuringRollingBenchDeviceActionComponent.self)
                )
                .onEnded { value in
                    guard let component = value.entity.components[
                        TuringRollingBenchDeviceActionComponent.self
                    ] else {
                        return
                    }
                    Task { @MainActor in
                        coordinator.handleTuringRollingBenchAction(
                            component,
                            source: "realityKit"
                        )
                    }
                }
        )
        .simultaneousGesture(
            TapGesture()
                .targetedToEntity(
                    where: .has(
                        TuringStoryWalkiePlayComponent.self
                    )
                )
                .onEnded { _ in
                    Task { @MainActor in
                        coordinator.turingWalkiePlayTapped(
                            source: "realityKit"
                        )
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .targetedToEntity(
                    where: .has(
                        TuringStoryWalkieMicrophoneComponent.self
                    )
                )
                .onChanged { _ in
                    Task { @MainActor in
                        coordinator
                            .turingWalkieMicrophoneHoldBegan(
                                source: "realityKit"
                            )
                    }
                }
                .onEnded { _ in
                    Task { @MainActor in
                        coordinator
                            .turingWalkieMicrophoneHoldEnded(
                                source: "realityKit"
                            )
                    }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .targetedToEntity(
                    where: .has(
                        TuringStoryPlacementAdjustmentBarComponent.self
                    )
                )
                .onChanged { value in
                    guard let component = value.entity.components[
                        TuringStoryPlacementAdjustmentBarComponent.self
                    ] else {
                        return
                    }

                    let point = value.convert(
                        value.location3D,
                        from: .local,
                        to: .scene
                    )
                    let worldPoint = SIMD3<Float>(
                        Float(point.x),
                        Float(point.y),
                        Float(point.z)
                    )

                    if placementAdjustmentDragActive {
                        coordinator.updateTuringPlacementAdjustment(
                            worldPoint: worldPoint
                        )
                    } else {
                        placementAdjustmentDragActive = true
                        coordinator.beginTuringPlacementAdjustment(
                            propID: component.propID,
                            worldPoint: worldPoint
                        )
                    }
                }
                .onEnded { _ in
                    guard placementAdjustmentDragActive else {
                        return
                    }
                    placementAdjustmentDragActive = false
                    coordinator.endTuringPlacementAdjustment(
                        commit: true
                    )
                }
        )
        .preferredSurroundingsEffect(
            deathPresentationController.surroundingsEffect
                ?? damageTintController.surroundingsEffect
        )
        .task(id: session.latestCommand?.id) {
            guard let commandEnvelope = session.latestCommand else { return }
            coordinator.handle(commandEnvelope)
        }
        .task(id: session.latestTuringDictationEvent?.id) {
            guard let envelope = session.latestTuringDictationEvent else { return }
            coordinator.applyTuringDictationEventToExistingHUD(envelope.event)
        }
        .onReceive(frameTimer) { date in
            coordinator.tick(at: date)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .plagueDismissSwiftUIControlWindowForCurrentRun
            )
        ) { _ in
            Task { @MainActor in
                dismissWindow(
                    id: PlagueWindowID.control
                )

                print(
                    """
                    [PlagueUI] SwiftUI control window dismissed for current run
                      windowID: \(PlagueWindowID.control)
                      reason: wall_ui_active
                      blankKeepaliveView: false
                    """
                )
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .plagueShowGameCenterLeaderboards
            )
        ) { _ in
            Task { @MainActor in
                openWindow(
                    id: PlagueWindowID.leaderboards
                )

                print("[GameCenter] leaderboards window opened")
            }
        }
        .onAppear {
            coordinator.configureTuringWalkieInteractionEventSink(
                session
            )
            coordinator.deathPresentationController = deathPresentationController
            coordinator.onPlayerDamaged = { amount in
                let intensity = min(max(Double(amount) / 50.0, 0.35), 1.0)
                session.triggerDamageTint(intensity: intensity)
            }
            coordinator.onPlayerDeathStarted = {
                damageTintController.reset()

                session.handlePlayerDeathUI(
                    openWindow: openWindow
                )
            }
            coordinator.onForestAtmosphereFatalFailure = { error in
                Task { @MainActor in
                    session.closeForestImmersiveBecauseSplatFailed(error: error)
                    await dismissImmersiveSpace()
                }
            }
            coordinator.onForestSplatLoadStatusChanged = { status in
                session.forestSplatLoadStatus = status
            }
            coordinator.onForestGeometryLoadStatusChanged = { status in
                session.forestGeometryLoadStatus = status
                session.forestSplatLoadStatus = status
            }
            coordinator.onForestAppearanceStatusChanged = { status in
                session.forestAppearanceStatus = status
            }
            coordinator.onWallPosterUIActiveChanged = { active in
                if active {
                    session.markRoomSkinningCommittedForHorde()
                } else {
                    session.setWallPosterUIInactiveIfAllowed()
                }
            }
            coordinator.onRoomSkinningStatusChanged = { status in
                session.roomSkinningStatus = status
            }
            coordinator.onHordeWaveReached = { wave in
                session.recordHordeWaveReached(
                    wave: wave
                )
            }
            coordinator.onHordeWaveCleared = { wave in
                session.recordHordeWaveCleared(
                    wave: wave
                )
            }
            coordinator.onHordeSessionEnded = {
                session.submitHordeScoresOnSessionEnd()
            }
        }
        .onChange(of: session.damageTintEventID) { _, _ in
            damageTintController.trigger(
                intensity: session.damageTintIntensity
            )
        }
        .onDisappear {
            placementAdjustmentDragActive = false
            coordinator.onYouDiedWorldCardCleanupRequested?()
            coordinator.onYouDiedWorldCardRequested = nil
            coordinator.onYouDiedWorldCardCleanupRequested = nil

            damageTintController.reset()
            deathPresentationController.reset()
            coordinator.shutdown()
            session.setWallPosterUIInactiveIfAllowed()
            session.forestImmersiveDidClose()
            Task {
                await TuringEpisodeFlowController.shared.resetEpisode(
                    reason: "immersiveViewDisappeared"
                )
            }
        }
    }
}
