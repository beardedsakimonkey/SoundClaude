import SwiftUI

struct SignedOutView: View {
    let message: String?
    let onSignIn: () -> Void
    let onImportSession: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var showsSessionImport = true
    @State private var copiedSessionCommand = false

    private let sessionCommand = "copy(document.cookie.split('; ').find(c => c.startsWith('oauth_token='))?.slice('oauth_token='.length) ?? '')"

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    header
                    signInButton
                    HStack(spacing: 18) {
                        Rectangle().frame(height: 1)
                        Text("or").font(.callout)
                        Rectangle().frame(height: 1)
                    }
                    .foregroundStyle(.secondary.opacity(0.4))
                    sessionCard
                }
                .frame(maxWidth: 440)
                .padding(32)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .background {
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    RadialGradient(
                        stops: [
                            .init(color: .gray.opacity(colorScheme == .dark ? 0.14 : 0.09), location: 0),
                            .init(color: .gray.opacity(colorScheme == .dark ? 0.05 : 0.03), location: 0.45),
                            .init(color: .clear, location: 1)
                        ],
                        center: UnitPoint(x: 0.5, y: 0.3),
                        startRadius: 0,
                        endRadius: max(geometry.size.width, geometry.size.height) * 0.75
                    )
                }
                .ignoresSafeArea()
            }
        }
        #if DEBUG
        .debugViewUpdates("SignedOutView")
        #endif
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 128, height: 128)
                .accessibilityHidden(true)
            Text("SoundClaude")
                .font(.system(size: 34, weight: .semibold))
            Text(message ?? "Sign in to load your liked tracks.")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signInButton: some View {
        Button(action: onSignIn) {
            HStack(spacing: 12) {
                Text("Sign in with SoundCloud")
                    .font(.system(size: 15, weight: .medium))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .opacity(0.75)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 40)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(SignedOutActionStyle(isPrimary: true))
        .frame(maxWidth: 334)
    }

    private var sessionCard: some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: "macwindow")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 46, height: 46)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showsSessionImport.toggle()
                    }
                } label: {
                    HStack(spacing: 12) {
                        Text("Use an existing browser session")
                            .font(.system(size: 16, weight: .medium))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(showsSessionImport ? 0 : -90))
                    }
                    .frame(minHeight: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showsSessionImport ? "Expanded" : "Collapsed")

                if showsSessionImport {
                    Text("1. Sign in at soundcloud.com in your browser.\n2. Open the browser’s developer console.\n3. Paste and run this command to copy your session token.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(sessionCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    Button {
                        NSPasteboard.general.clearContents()
                        copiedSessionCommand = NSPasteboard.general.setString(sessionCommand, forType: .string)
                    } label: {
                        Label(copiedSessionCommand ? "Command Copied" : "Copy Command",
                              systemImage: copiedSessionCommand ? "checkmark" : "doc.on.doc")
                    }
                    Text("4. Return here and import the copied session. Importing saves it in Keychain and clears the clipboard.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: onImportSession) {
                        Text("Import Copied Session")
                            .font(.system(size: 15, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .contentShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(SignedOutActionStyle(isPrimary: false))
                }
            }
        }
        .padding(20)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct SignedOutActionStyle: ButtonStyle {
    let isPrimary: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(isPrimary
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(LinearGradient(colors: [.primary.opacity(0.07), .primary.opacity(0.05)],
                                         startPoint: .top, endPoint: .bottom)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.white.opacity(isPrimary ? 0.25 : 0.08), lineWidth: 1)
            }
            .shadow(color: isPrimary ? .accentColor.opacity(0.12) : .clear, radius: 18, y: 4)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
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
