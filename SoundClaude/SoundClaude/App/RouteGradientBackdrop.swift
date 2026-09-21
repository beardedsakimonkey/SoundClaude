import SwiftUI

struct RouteGradientBackdrop: View {
    var body: some View {
        backdrop
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var backdrop: some View {
        let gradient = LinearGradient(
            colors: [.gray.opacity(0.12), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 150)

        if #available(macOS 26.0, *) {
            gradient.backgroundExtensionEffect()
        } else {
            gradient
        }
    }
}
