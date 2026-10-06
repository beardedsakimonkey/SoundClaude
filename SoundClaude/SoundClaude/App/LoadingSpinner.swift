import SwiftUI

struct LoadingSpinner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        ProgressView()
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.3)) {
                    isVisible = true
                }
            }
            .onDisappear {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    isVisible = false
                }
            }
    }
}
