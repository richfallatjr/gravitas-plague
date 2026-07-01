import SwiftUI

struct TuringDictateButton: View {
    let isRecording: Bool
    let isBusy: Bool
    let onPressStarted: () -> Void
    let onPressEnded: () -> Void

    @State private var pressStarted = false

    var body: some View {
        Image(systemName: isRecording ? "mic.circle.fill" : "mic.circle")
            .font(.system(size: 44, weight: .semibold))
            .foregroundStyle(isRecording ? .red : .primary)
            .opacity(isBusy ? 0.45 : 1.0)
            .accessibilityLabel(isRecording ? "Recording" : "Hold to ask Big Mike")
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isBusy, !pressStarted else { return }
                        pressStarted = true
                        onPressStarted()
                    }
                    .onEnded { _ in
                        guard pressStarted else { return }
                        pressStarted = false
                        onPressEnded()
                    }
            )
            .allowsHitTesting(!isBusy)
    }
}
