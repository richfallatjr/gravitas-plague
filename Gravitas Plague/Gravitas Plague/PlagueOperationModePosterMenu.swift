import SwiftUI

#if os(macOS)
import AppKit

typealias PlagueMenuPlatformImage = NSImage
#else
import UIKit

typealias PlagueMenuPlatformImage = UIImage
#endif

struct PixelRect: Equatable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    var cgRect: CGRect {
        CGRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }
}

enum PlagueMenuHitZones {
    static let sourceSize = CGSize(
        width: 1086,
        height: 1448
    )

    static let horde = PixelRect(
        x: 52,
        y: 1101,
        width: 490,
        height: 141
    )

    static let walkLoop = PixelRect(
        x: 557,
        y: 1100,
        width: 478,
        height: 143
    )
}

enum PlagueMenuAssetValidator {
    static func validate() {
        let names = [
            "plague_menu_ui_clean",
            "plague_menu_ui_mockup",
            "plague_menu_horde_button",
            "plague_menu_walk_button"
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

extension CGRect {
    static func aspectFitRect(
        sourceSize: CGSize,
        in containerSize: CGSize
    ) -> CGRect {
        guard sourceSize.width > 0,
              sourceSize.height > 0,
              containerSize.width > 0,
              containerSize.height > 0 else {
            return .zero
        }

        let scale = min(
            containerSize.width / sourceSize.width,
            containerSize.height / sourceSize.height
        )

        let displaySize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )

        return CGRect(
            x: (containerSize.width - displaySize.width) * 0.5,
            y: (containerSize.height - displaySize.height) * 0.5,
            width: displaySize.width,
            height: displaySize.height
        )
    }
}

func mappedPixelRect(
    _ pixelRect: PixelRect,
    sourceSize: CGSize,
    displayedImageRect: CGRect
) -> CGRect {
    let scaleX = displayedImageRect.width / sourceSize.width
    let scaleY = displayedImageRect.height / sourceSize.height

    return CGRect(
        x: displayedImageRect.minX + pixelRect.x * scaleX,
        y: displayedImageRect.minY + pixelRect.y * scaleY,
        width: pixelRect.width * scaleX,
        height: pixelRect.height * scaleY
    )
}

struct PlagueOperationModePosterMenu: View {
    @ObservedObject var session: PlagueDemoSession

    @Environment(\.openImmersiveSpace) private var openImmersiveSpace

    var body: some View {
        GeometryReader { proxy in
            let containerSize = proxy.size

            let imageRect = CGRect.aspectFitRect(
                sourceSize: PlagueMenuHitZones.sourceSize,
                in: containerSize
            )

            let hordeRect = mappedPixelRect(
                PlagueMenuHitZones.horde,
                sourceSize: PlagueMenuHitZones.sourceSize,
                displayedImageRect: imageRect
            )

            let walkRect = mappedPixelRect(
                PlagueMenuHitZones.walkLoop,
                sourceSize: PlagueMenuHitZones.sourceSize,
                displayedImageRect: imageRect
            )

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()

                PlagueMenuPosterImage(
                    name: "plague_menu_ui_mockup",
                    containerSize: containerSize
                )
                .allowsHitTesting(false)

                PlaguePixelHitButton(
                    label: "Horde Mode",
                    rect: hordeRect,
                    debugColor: .red,
                    action: {
                        Task {
                            await selectOperationMode(.horde)
                        }
                    }
                )

                PlaguePixelHitButton(
                    label: "Walk Loop",
                    rect: walkRect,
                    debugColor: .black,
                    action: {
                        Task {
                            await selectOperationMode(.walkLoop)
                        }
                    }
                )
            }
            .onAppear {
                print(
                    """
                    [PlagueMenu] poster menu appeared
                      container: \(containerSize)
                      source: \(PlagueMenuHitZones.sourceSize)
                      imageRect: \(imageRect)
                      hordeRect: \(hordeRect)
                      walkRect: \(walkRect)
                    """
                )
            }
        }
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
            session.statusMessage = "Opening mixed-reality space."

            let result = await openImmersiveSpace(
                id: PlagueDemoSession.immersiveSpaceID
            )

            switch result {
            case .opened:
                session.immersiveSpaceStatus = .open

            case .userCancelled:
                session.immersiveSpaceStatus = .closed
                session.statusMessage = "Immersive space was not opened."
                return

            case .error:
                session.immersiveSpaceStatus = .closed
                session.statusMessage = "Could not open immersive space."
                return

            @unknown default:
                session.immersiveSpaceStatus = .closed
                session.statusMessage = "Unknown immersive-space result."
                return
            }
        }

        print("[PlagueMenu] selected operation mode: \(mode.rawValue)")
        session.selectOperationMode(mode)
    }
}

private struct PlagueMenuPosterImage: View {
    let name: String
    let containerSize: CGSize

    var body: some View {
        Group {
            #if os(macOS)
            if let image = PlagueMenuImageLoader.image(named: name) {
                configured(Image(nsImage: image))
            } else {
                missingImageView
            }
            #else
            if let image = PlagueMenuImageLoader.image(named: name) {
                configured(Image(uiImage: image))
            } else {
                missingImageView
            }
            #endif
        }
    }

    private func configured(
        _ image: Image
    ) -> some View {
        image
            .resizable()
            .interpolation(.high)
            .aspectRatio(
                PlagueMenuHitZones.sourceSize,
                contentMode: .fit
            )
            .frame(
                width: containerSize.width,
                height: containerSize.height,
                alignment: .center
            )
    }

    private var missingImageView: some View {
        ZStack {
            Color.black

            Text("Missing \(name).png")
                .font(.caption)
                .foregroundStyle(.red)
                .monospaced()
        }
        .frame(
            width: containerSize.width,
            height: containerSize.height,
            alignment: .center
        )
    }
}

struct PlaguePixelHitButton: View {
    let label: String
    let rect: CGRect
    let debugColor: Color
    let action: () -> Void

    private let showDebugHitRects = false

    var body: some View {
        Button {
            print("[PlagueMenu] tapped \(label)")
            action()
        } label: {
            Rectangle()
                .fill(
                    showDebugHitRects
                        ? debugColor.opacity(0.25)
                        : Color.clear
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(
                            showDebugHitRects ? debugColor : Color.clear,
                            lineWidth: showDebugHitRects ? 2 : 0
                        )
                )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .frame(
            width: rect.width,
            height: rect.height
        )
        .position(
            x: rect.midX,
            y: rect.midY
        )
        .accessibilityLabel(label)
    }
}
