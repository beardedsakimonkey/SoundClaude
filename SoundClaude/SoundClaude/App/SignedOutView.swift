import SwiftUI

struct SignedOutView: View {
    let message: String?
    let onSignIn: () -> Void
    let onImportSession: () -> Void

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
            DisclosureGroup("Use an existing browser session") {
                VStack(spacing: 8) {
                    Text("Copy the oauth_token cookie value from soundcloud.com in your browser’s developer tools. Importing it saves it in Keychain and clears the clipboard.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Import Copied Session", action: onImportSession)
                }
                .padding(.top, 8)
            }
            .frame(maxWidth: 420)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if DEBUG
        .debugViewUpdates("SignedOutView")
        #endif
    }
}

struct WebsiteSignInView: View {
    @ObservedObject var login: WebsiteLogin
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in at soundcloud.com").font(.headline)
                Spacer()
                Button("Cancel", action: cancel)
            }
            .padding()
            if let error = login.errorMessage {
                Text(error).foregroundStyle(.red).padding(.horizontal).padding(.bottom)
            }
            WebsiteLoginView(login: login)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
