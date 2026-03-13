import SwiftUI

/// Full-screen countdown overlay before recording starts.
/// Shows 3, 2, 1 with scale + fade animations.
struct CountdownView: View {
    @ObservedObject var appState: AppState
    @State private var currentNumber = 3
    @State private var scale: CGFloat = 1.0
    @State private var numberOpacity: Double = 1.0

    var onComplete: () -> Void

    var body: some View {
        ZStack {
            // Semi-transparent backdrop
            Color.black.opacity(0.3)
                .ignoresSafeArea()

            // Countdown number
            Text("\(currentNumber)")
                .font(.system(size: 120, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 20)
                .scaleEffect(scale)
                .opacity(numberOpacity)
        }
        .onAppear {
            startCountdown()
        }
    }

    private func startCountdown() {
        currentNumber = 3
        animateNumber()
    }

    private func animateNumber() {
        // Reset
        scale = 0.5
        numberOpacity = 1.0

        // Animate in
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            scale = 1.0
        }

        // Fade out and next
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeOut(duration: 0.25)) {
                numberOpacity = 0
                scale = 1.3
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if currentNumber > 1 {
                    currentNumber -= 1
                    animateNumber()
                } else {
                    onComplete()
                }
            }
        }
    }
}
