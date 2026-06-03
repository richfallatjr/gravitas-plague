import SwiftUI

struct DamageFlashOverlay: View {
    let token: UUID
    let intensity: Float

    @State private var opacity: Double = 0

    var body: some View {
        Rectangle()
            .fill(
                RadialGradient(
                    colors: [
                        Color.red.opacity(0.05),
                        Color.red.opacity(Double(0.55 * intensity))
                    ],
                    center: .center,
                    startRadius: 80,
                    endRadius: 620
                )
            )
            .opacity(opacity)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .onChange(of: token) { _, _ in
                playFlash()
            }
            .onAppear {
                if intensity > 0 {
                    playFlash()
                }
            }
    }

    private func playFlash() {
        opacity = 0

        withAnimation(.linear(duration: 0.05)) {
            opacity = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeOut(duration: 0.55)) {
                opacity = 0
            }
        }
    }
}
