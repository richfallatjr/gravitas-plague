import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit

@MainActor
final class PlagueControlWindowKillSwitch {
    static let shared = PlagueControlWindowKillSwitch()

    private weak var controlWindow: UIWindow?

    private init() {}

    func registerControlWindow(
        window: UIWindow
    ) {
        if controlWindow !== window {
            controlWindow = window

            print(
                """
                [PlagueQuit] registered control window
                  window: \(String(describing: window))
                  scene: \(String(describing: window.windowScene))
                """
            )
        }
    }
}

struct PlagueWindowAttachmentObserver: UIViewRepresentable {
    let onAttach: (UIWindow) -> Void
    let onDetach: () -> Void
    let onMidXChange: (CGFloat) -> Void

    func makeUIView(
        context: Context
    ) -> AttachmentReportingView {
        let view = AttachmentReportingView()
        view.onAttach = onAttach
        view.onDetach = onDetach
        view.onMidXChange = onMidXChange
        return view
    }

    func updateUIView(
        _ uiView: AttachmentReportingView,
        context: Context
    ) {
        uiView.onAttach = onAttach
        uiView.onDetach = onDetach
        uiView.onMidXChange = onMidXChange
    }

    final class AttachmentReportingView: UIView {
        var onAttach: ((UIWindow) -> Void)?
        var onDetach: (() -> Void)?
        var onMidXChange: ((CGFloat) -> Void)?

        private weak var lastWindow: UIWindow?
        private var lastMidX: CGFloat?

        override func didMoveToWindow() {
            super.didMoveToWindow()

            if let window {
                if lastWindow !== window {
                    lastWindow = window
                    onAttach?(window)
                }
            } else if lastWindow != nil {
                lastWindow = nil
                onDetach?()
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()

            guard let window else {
                return
            }

            let rect = convert(bounds, to: window)
            let midX = rect.midX

            if lastMidX == nil || abs((lastMidX ?? 0) - midX) > 0.5 {
                lastMidX = midX
                onMidXChange?(midX)
            }
        }
    }
}

#elseif canImport(AppKit)
import AppKit

struct PlagueWindowAttachmentObserver: NSViewRepresentable {
    let onAttach: (NSWindow) -> Void
    let onDetach: () -> Void
    let onMidXChange: (CGFloat) -> Void

    func makeNSView(
        context: Context
    ) -> AttachmentReportingView {
        let view = AttachmentReportingView()
        view.onAttach = onAttach
        view.onDetach = onDetach
        view.onMidXChange = onMidXChange
        return view
    }

    func updateNSView(
        _ nsView: AttachmentReportingView,
        context: Context
    ) {
        nsView.onAttach = onAttach
        nsView.onDetach = onDetach
        nsView.onMidXChange = onMidXChange
    }

    final class AttachmentReportingView: NSView {
        var onAttach: ((NSWindow) -> Void)?
        var onDetach: (() -> Void)?
        var onMidXChange: ((CGFloat) -> Void)?

        private weak var lastWindow: NSWindow?
        private var lastMidX: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if let window {
                if lastWindow !== window {
                    lastWindow = window
                    onAttach?(window)
                }
            } else if lastWindow != nil {
                lastWindow = nil
                onDetach?()
            }
        }

        override func layout() {
            super.layout()

            guard window != nil else {
                return
            }

            let rect = convert(bounds, to: nil)
            let midX = rect.midX

            if lastMidX == nil || abs((lastMidX ?? 0) - midX) > 0.5 {
                lastMidX = midX
                onMidXChange?(midX)
            }
        }
    }
}
#endif
