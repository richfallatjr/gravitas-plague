import Darwin
import SwiftUI

#if os(macOS)
import AppKit

typealias PlagueMenuPlatformImage = NSImage
#else
import UIKit

typealias PlagueMenuPlatformImage = UIImage
#endif

enum PlagueMenuAssetValidator {
    static func validate() {
        let names = [
            OperationModePosterLayout.assetName,
            "kill_switch_x",
            "trophy_sticker"
        ]

        for name in names {
            if let source = PlagueMenuImageLoader.sourceDescription(
                named: name
            ) {
                print("[PlagueMenu] found asset \(name) source: \(source)")
            } else {
                print("[PlagueMenu] ERROR missing asset \(name)")
            }
        }
    }
}

enum PlagueMenuImageLoader {
    static func bundlePNGURL(
        named name: String
    ) -> URL? {
        Bundle.main.url(
            forResource: name,
            withExtension: "png"
        )
    }

    static func image(
        named name: String
    ) -> PlagueMenuPlatformImage? {
        if let url = bundlePNGURL(named: name) {
            #if os(macOS)
            if let image = NSImage(contentsOf: url) {
                return image
            }
            #else
            if let image = UIImage(contentsOfFile: url.path) {
                return image
            }
            #endif
        }

        #if os(macOS)
        return NSImage(named: name)
        #else
        return UIImage(named: name)
        #endif
    }

    static func sourceDescription(
        named name: String
    ) -> String? {
        if let url = bundlePNGURL(named: name) {
            return "bundle:\(url.lastPathComponent)"
        }

        if image(named: name) != nil {
            return "assetCatalog"
        }

        return nil
    }
}

struct PlagueOperationModePosterRoot: View {
    @ObservedObject var session: PlagueDemoSession

    @Environment(\.scenePhase) private var scenePhase

    #if os(visionOS)
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    #endif

    var body: some View {
        content
            .background {
                PlagueWindowAttachmentObserver(
                    onAttach: { window in
                        #if canImport(UIKit)
                        PlagueControlWindowKillSwitch.shared.registerControlWindow(
                            window: window,
                            onQuitRequested: { reason in
                                guard !session.isQuitting else {
                                    return
                                }

                                performImmediateQuit(
                                    reason: reason
                                )
                            },
                            shouldIgnoreQuitRequested: { reason in
                                guard session.shouldIgnoreControlWindowLifecycleBecauseWallUIIsActive else {
                                    return false
                                }

                                session.noteControlWindowLifecycleIgnoredForWallUI(
                                    reason: "\(reason)_after_wall_ui_activation"
                                )

                                return true
                            }
                        )
                        #else
                        print(
                            """
                            [PlagueQuit] registered control window
                              window: \(String(describing: window))
                            """
                        )
                        #endif
                    },
                    onDetach: {
                        guard !session.isQuitting else {
                            return
                        }

                        guard !session.shouldIgnoreControlWindowLifecycleBecauseWallUIIsActive else {
                            session.noteControlWindowLifecycleIgnoredForWallUI(
                                reason: "control_window_detached_after_wall_ui_activation"
                            )
                            return
                        }

                        performImmediateQuit(
                            reason: "control_window_detached"
                        )
                    },
                    onMidXChange: { _ in
                        // Reserved for future menu alignment if needed.
                    }
                )
            }
            .onDisappear {
                guard !session.isQuitting else {
                    return
                }

                guard !session.shouldIgnoreControlWindowLifecycleBecauseWallUIIsActive else {
                    session.noteControlWindowLifecycleIgnoredForWallUI(
                        reason: "control_window_closed_after_wall_ui_activation"
                    )
                    return
                }

                performImmediateQuit(
                    reason: "control_window_closed"
                )
            }
            .onChange(of: scenePhase) { _, newPhase in
                guard !session.isQuitting else {
                    return
                }

                guard newPhase == .background else {
                    return
                }

                guard !session.shouldIgnoreControlWindowLifecycleBecauseWallUIIsActive else {
                    session.noteControlWindowLifecycleIgnoredForWallUI(
                        reason: "control_window_backgrounded_after_wall_ui_activation"
                    )
                    return
                }

                guard session.handleControlWindowSceneBackgrounded() else {
                    return
                }

                performImmediateQuit(
                    reason: "control_window_scene_backgrounded"
                )
            }
            .onAppear {
                session.notePosterUIMounted()

                print(
                    """
                    [PlagueQuit] poster root mounted
                      scenePhase: \(String(describing: scenePhase))
                    """
                )
            }
    }

    @ViewBuilder
    private var content: some View {
        if session.swiftUIControlWindowSuppressedForCurrentRun {
            SuppressedControlWindowAutoDismiss(
                session: session
            )
        } else {
            PlagueOperationModePosterMenu(session: session)
                .ornament(
                    visibility: .visible,
                    attachmentAnchor: .scene(.top),
                    contentAlignment: .center
                ) {
                    PlagueRoomSkinningTopOrnament(session: session)
                }
        }
    }

    @MainActor
    private func performImmediateQuit(
        reason: String
    ) {
        if session.isQuitting {
            print(
                """
                [PlagueQuit] immediate quit requested while already quitting; forcing exit
                  reason: \(reason)
                """
            )

            exit(0)
        }

        session.requestImmediateQuitFromControlWindow(
            reason: reason
        )

        dismissSecondaryWindowsForQuit()

        print(
            """
            [PlagueQuit] kill switch forcing process exit
              reason: \(reason)
            """
        )

        exit(0)
    }

    @MainActor
    private func dismissSecondaryWindowsForQuit() {
        print("[PlagueQuit] no secondary SwiftUI windows registered for dismissal.")
    }

    @MainActor
    private func dismissImmersiveSpaceForQuit(
        timeoutNanoseconds: UInt64
    ) async -> String {
        #if os(visionOS)
        return await withTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                await dismissImmersiveSpace()
                return "completed"
            }

            group.addTask {
                try? await Task.sleep(
                    nanoseconds: timeoutNanoseconds
                )

                return "timeout"
            }

            let first = await group.next() ?? "unknown"
            group.cancelAll()
            return first
        }
        #else
        return "not_visionOS"
        #endif
    }
}

struct PlagueOperationModePosterMenu: View {
    @ObservedObject var session: PlagueDemoSession
    @ObservedObject private var resources = OperationModePosterResources.shared
    @ObservedObject private var accessController = OperationModeAccessController.shared

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    private let showDebugHitRects = false

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size

            let sourceSize = CGSize(
                width: resources.analysis.map {
                    CGFloat($0.pixelWidth)
                } ?? OperationModePosterLayout.referencePixelSize.width,
                height: resources.analysis.map {
                    CGFloat($0.pixelHeight)
                } ?? OperationModePosterLayout.referencePixelSize.height
            )

            let imageRect = CGRect(
                origin: .zero,
                size: containerSize
            )

            ZStack(alignment: .topLeading) {
                posterImage(
                    imageRect: imageRect
                )
                .allowsHitTesting(false)

                ForEach(OperationModePosterLayout.regions) { region in
                    modeButton(
                        region: region,
                        imageRect: imageRect
                    )
                }
            }
            .onAppear {
                resources.loadIfNeeded()
                accessController.refresh()

                print(
                    """
                    [PlagueMenu] poster menu appeared
                      container: \(containerSize)
                      source: \(sourceSize)
                      imageRect: \(imageRect)
                      windowAspectMatchesPoster: true
                      storyRect: \(OperationModePosterLayout.storySourceRect)
                      hordeRect: \(OperationModePosterLayout.hordeSourceRect)
                      sourceImage: \(OperationModePosterLayout.assetName).\(OperationModePosterLayout.assetExtension)
                      walkLoopPlayerFacing: false
                    """
                )
            }
        }
    }

    @ViewBuilder
    private func posterImage(
        imageRect: CGRect
    ) -> some View {
        if let image = resources.image {
            #if os(macOS)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(
                    width: imageRect.width,
                    height: imageRect.height
                )
                .position(
                    x: imageRect.midX,
                    y: imageRect.midY
                )
            #else
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .frame(
                    width: imageRect.width,
                    height: imageRect.height
                )
                .position(
                    x: imageRect.midX,
                    y: imageRect.midY
                )
            #endif
        } else {
            ZStack {
                Color.black

                Text("Missing \(OperationModePosterLayout.assetName).png")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .monospaced()
            }
            .frame(
                width: imageRect.width,
                height: imageRect.height
            )
            .position(
                x: imageRect.midX,
                y: imageRect.midY
            )
        }
    }

    @ViewBuilder
    private func modeButton(
        region: PosterModeRegion,
        imageRect: CGRect
    ) -> some View {
        let rect = PosterCoordinateMapper.displayRect(
            normalizedRect: region.normalizedRect,
            imageRect: imageRect
        )
        let availability = accessController.snapshot[region.mode]

        Button {
            print(
                """
                [PlagueMenu] tapped operation mode
                  mode: \(region.mode.rawValue)
                  unlocked: \(availability.isUnlocked)
                """
            )

            Task {
                await selectOperationMode(region.mode)
            }
        } label: {
            ZStack {
                Rectangle()
                    .fill(
                        showDebugHitRects
                            ? Color.red.opacity(0.22)
                            : Color.clear
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(
                                showDebugHitRects
                                    ? Color.red
                                    : Color.clear,
                                lineWidth: showDebugHitRects ? 2 : 0
                            )
                    )

                if !availability.isUnlocked {
                    Image(systemName: "lock.fill")
                        .font(
                            .system(
                                size: max(
                                    14,
                                    min(rect.width, rect.height) * 0.38
                                ),
                                weight: .bold
                            )
                        )
                        .foregroundStyle(resources.lockColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!availability.isUnlocked)
        .contentShape(Rectangle())
        .frame(
            width: rect.width,
            height: rect.height
        )
        .position(
            x: rect.midX,
            y: rect.midY
        )
        .accessibilityLabel(region.mode.displayName)
    }

    @MainActor
    private func selectOperationMode(
        _ mode: PlagueDemoSession.PlagueOperationMode
    ) async {
        guard session.immersiveSpaceStatus != .opening else {
            return
        }

        if session.immersiveSpaceStatus == .closed {
            session.immersiveSpaceStatus = .opening
            session.forestImmersiveState = .opening
            session.forestImmersiveStatus = "Opening mixed room scene..."
            session.statusMessage = "Opening mixed-reality space."

            let result = await openImmersiveSpace(
                id: PlagueDemoSession.immersiveSpaceID
            )

            switch result {
            case .opened:
                session.immersiveSpaceStatus = .open
                session.forestImmersiveDidOpen()

            case .userCancelled:
                session.immersiveSpaceStatus = .closed
                session.forestImmersiveState = .closed
                session.forestImmersiveStatus = "Mixed room scene cancelled."
                session.statusMessage = "Immersive space was not opened."
                return

            case .error:
                session.immersiveSpaceStatus = .closed
                session.forestImmersiveState = .failed
                session.forestImmersiveStatus = "Mixed room scene failed."
                session.statusMessage = "Could not open immersive space."
                return

            @unknown default:
                session.immersiveSpaceStatus = .closed
                session.forestImmersiveState = .failed
                session.forestImmersiveStatus = "Mixed room scene failed: \(String(describing: result))"
                session.statusMessage = "Unknown immersive-space result."
                return
            }
        }

        print("[PlagueMenu] selected operation mode: \(mode.rawValue)")
        session.selectOperationMode(mode)
    }
}

struct SuppressedControlWindowAutoDismiss: View {
    @ObservedObject var session: PlagueDemoSession
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Color.clear
            .frame(
                width: 1,
                height: 1
            )
            .accessibilityHidden(true)
            .task {
                await MainActor.run {
                    dismissWindow(
                        id: PlagueWindowID.control
                    )

                    print(
                        """
                        [PlagueUI] auto-dismissed suppressed control window
                          reason: reopened_during_active_wall_ui_run
                          blankGrayWindowPrevented: true
                        """
                    )
                }
            }
    }
}

struct PlagueRoomSkinningTopOrnament: View {
    @ObservedObject var session: PlagueDemoSession

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        HStack(spacing: 10) {
            if !session.wallPosterUIActive {
                Button {
                    session.showGameCenterLeaderboards()
                } label: {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.25))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .help("Leaderboards")
                .accessibilityLabel("Leaderboards")
            }

            Button {
                Task { @MainActor in
                    await session.toggleForestImmersive(
                        openImmersiveSpace: openImmersiveSpace,
                        dismissImmersiveSpace: dismissImmersiveSpace
                    )
                }
            } label: {
                Image(systemName: mixedSceneIconName)
                    .font(.system(size: 23, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .help(mixedSceneHelpText)
            .accessibilityLabel(mixedSceneHelpText)

            if session.shouldShowForestDayNightToggle {
                Button {
                    session.togglePortalHDRIAtmosphere()
                } label: {
                    Image(systemName: session.portalHDRIAtmosphere == .night ? "moon.stars.fill" : "cloud.sun.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(session.forestImmersiveState != .open)
                .help("Switch portal backdrop")
                .accessibilityLabel("Switch portal backdrop")
            }

            if session.shouldShowStoryRoomSkinningControls {
                Button {
                    session.startRoomSkinningExperiment()
                } label: {
                    Image(systemName: "door.left.hand.open")
                        .font(.system(size: 23, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(session.forestImmersiveState != .open)
                .help("Scan wall and preview portal door")
                .accessibilityLabel("Scan wall and preview portal door")

                Button {
                    session.confirmRoomSkinningPlacement()
                } label: {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 23, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(session.forestImmersiveState != .open)
                .help("Confirm portal door")
                .accessibilityLabel("Confirm portal door")

                Button {
                    session.enterRoomSkinningDoorAdjustment()
                } label: {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(session.forestImmersiveState != .open)
                .help("Adjust portal door")
                .accessibilityLabel("Adjust portal door")

                Button {
                    session.confirmRoomSkinningDoorAdjustment()
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .disabled(session.forestImmersiveState != .open)
                .help("Lock portal door")
                .accessibilityLabel("Lock portal door")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
        .onAppear {
            print("[RoomSkinning] top ornament appeared")
            if !session.shouldShowStoryRoomSkinningControls {
                print("[RoomSkinning] debug test door hidden outside story/debug mode")
            }

            if !session.shouldShowForestDayNightToggle {
                print("[PlagueForest] day/night toggle hidden")
            }
        }
    }

    private var mixedSceneIconName: String {
        switch session.forestImmersiveState {
        case .open:
            return "door.left.hand.open"

        case .opening, .closing:
            return "hourglass"

        case .closed, .failed:
            return "door.left.hand.closed"
        }
    }

    private var mixedSceneHelpText: String {
        switch session.forestImmersiveState {
        case .open:
            return "Exit mixed room scene"

        case .opening:
            return "Opening mixed room scene"

        case .closing:
            return "Closing mixed room scene"

        case .closed, .failed:
            return "Enter mixed room scene"
        }
    }
}

struct PlagueForestTopOrnament: View {
    @ObservedObject var session: PlagueDemoSession

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task { @MainActor in
                    await session.toggleForestImmersive(
                        openImmersiveSpace: openImmersiveSpace,
                        dismissImmersiveSpace: dismissImmersiveSpace
                    )
                }
            } label: {
                Image(systemName: mountainIconName)
                    .font(.system(size: 24, weight: .semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .help(mountainHelpText)
            .accessibilityLabel(mountainHelpText)

            if session.shouldShowForestDayNightToggle {
                Button {
                    session.toggleForestAtmosphere()
                } label: {
                    Image(systemName: session.forestAtmosphere.toggleTargetIconSystemName)
                        .font(.system(size: 24, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .help("Switch to \(session.forestAtmosphere.next.displayName) atmosphere")
                .accessibilityLabel("Switch to \(session.forestAtmosphere.next.displayName) atmosphere")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .glassBackgroundEffect()
        .onAppear {
            print("[PlagueForest] top ornament appeared")
            if !session.shouldShowForestDayNightToggle {
                print("[PlagueForest] day/night toggle hidden")
            }
        }
    }

    private var mountainIconName: String {
        switch session.forestImmersiveState {
        case .open:
            return "mountain.2.fill"

        case .opening, .closing:
            return "hourglass"

        case .closed, .failed:
            return "mountain.2"
        }
    }

    private var mountainHelpText: String {
        switch session.forestImmersiveState {
        case .open:
            return "Exit full immersive forest"

        case .opening:
            return "Opening forest immersive"

        case .closing:
            return "Closing forest immersive"

        case .closed, .failed:
            return "Enter full immersive forest"
        }
    }
}
