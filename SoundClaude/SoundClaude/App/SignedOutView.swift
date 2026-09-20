import SwiftUI

struct SignedOutView: View {
    let message: String?
    let onSignIn: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Color.accentColor)
            Text("SoundClaude")
                .font(.largeTitle.weight(.semibold))
            Text(message ?? "Sign in to load your liked tracks.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            Button("Sign in with SoundCloud", action: onSignIn)
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
