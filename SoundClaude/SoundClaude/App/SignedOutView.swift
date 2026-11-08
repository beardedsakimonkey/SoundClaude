import SwiftUI

struct SignedOutView: View {
    let message: String?
    let onSignIn: () -> Void
    let onImportSession: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var copiedSessionCommand = false
    @State private var copySessionCommandCount = 0
    @State private var isHoveringSoundCloudLink = false

    private static let sessionCommand = #"copy(document.cookie.match(/oauth_token=([^;]+)/)[1])"#

    /// Minimal JS highlighting for `sessionCommand`: regexes, numbers, and calls.
    private static let highlightedSessionCommand: AttributedString = {
        let tokens = sessionCommand.matches(of: #/\/[^\/]+\/|[A-Za-z_]\w*|\d+|./#).map { String($0.output) }
        var result = AttributedString()
        for (index, token) in tokens.enumerated() {
            var piece = AttributedString(token)
            let next = index + 1 < tokens.count ? tokens[index + 1] : ""
            if token.hasPrefix("/") {
                piece.foregroundColor = Color(nsColor: NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .systemYellow : .systemGreen
                })
            } else if token.first?.isNumber == true {
                piece.foregroundColor = Color(nsColor: .systemPurple)
            } else if token.first?.isLetter == true, next == "(" {
                piece.foregroundColor = Color(nsColor: .systemOrange)
            }
            result += piece
        }
        return result
    }()

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                HStack(spacing: 36) {
                    header
                        .frame(minWidth: 220, maxWidth: .infinity)
                    signInOptions
                        .frame(maxWidth: 480)
                }
                .frame(maxWidth: 860)
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
            Text("Sign in to access your SoundCloud library")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signInOptions: some View {
        VStack(spacing: 24) {
            signInButton
            HStack(spacing: 18) {
                Rectangle().frame(height: 1)
                Text("or").font(.callout)
                Rectangle().frame(height: 1)
            }
            .foregroundStyle(.secondary.opacity(0.4))
            sessionCard
        }
    }

    private var signInButton: some View {
        Button(action: onSignIn) {
            HStack(spacing: 12) {
                Image("SoundCloudLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
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
                Text("Use an existing browser session")
                    .font(.system(size: 16, weight: .medium))
                    .frame(minHeight: 30)

                // Step 1 is its own row so the link can be a separate view that tracks hover.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("1. Sign in to ")
                        Link("soundcloud.com", destination: URL(string: "https://soundcloud.com")!)
                            .foregroundStyle(Color(nsColor: .linkColor))
                            .underline(isHoveringSoundCloudLink)
                            .onHover { isHoveringSoundCloudLink = $0 }
                            .buttonStyle(SignedOutLinkStyle())
                        Text(" in your browser.")
                    }
                    // Spacing 3 keeps the shortcuts as tight as a wrapped line of step 2.
                    VStack(alignment: .leading, spacing: 3) {
                        Text("2. Open the browser’s developer console with \(Text("⌥⌘J").foregroundStyle(.primary)) in Chrome or \(Text("⌥⌘K").foregroundStyle(.primary)) in Firefox.")
                    }
                    Text("3. Paste and run this command to copy your session token.")
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                Text(Self.highlightedSessionCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        // Flashes the block on each copy: a quick rise, then a slower fade.
                        RoundedRectangle(cornerRadius: 8)
                            .fill(colorScheme == .dark ? Color.white : Color.black.opacity(0.5))
                            .keyframeAnimator(initialValue: 0.0, trigger: copySessionCommandCount) { shape, opacity in
                                shape.opacity(opacity)
                            } keyframes: { _ in
                                CubicKeyframe(0.22, duration: 0.08)
                                CubicKeyframe(0, duration: 0.5)
                            }
                            .allowsHitTesting(false)
                    }
                Button {
                    NSPasteboard.general.clearContents()
                    copiedSessionCommand = NSPasteboard.general.setString(Self.sessionCommand, forType: .string)
                    copySessionCommandCount += 1
                } label: {
                    // Both titles stay in the layout and a hidden doc.on.doc reserves
                    // the icon's size, so the button never resizes when the state flips.
                    Label {
                        ZStack(alignment: .leading) {
                            Text("Copy Command")
                                .opacity(copiedSessionCommand ? 0 : 1)
                            Text("Command Copied")
                                .opacity(copiedSessionCommand ? 1 : 0)
                        }
                    } icon: {
                        Image(systemName: "doc.on.doc")
                            .hidden()
                            .overlay {
                                Image(systemName: copiedSessionCommand ? "checkmark" : "doc.on.doc")
                                    .contentTransition(.symbolEffect(.replace))
                            }
                    }
                    .animation(.easeInOut(duration: 0.2), value: copiedSessionCommand)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 28)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(SignedOutActionStyle(isPrimary: false, cornerRadius: 8))
                .task(id: copySessionCommandCount) {
                    guard copiedSessionCommand else { return }
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    copiedSessionCommand = false
                }
                Text("4. Return here and import the copied session.")
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
                if let message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
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

private struct SignedOutLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private struct SignedOutActionStyle: ButtonStyle {
    let isPrimary: Bool
    var cornerRadius: CGFloat = 12
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false
    private let primaryColor = Color(.sRGB, red: 0.95, green: 0.5, blue: 0.06, opacity: 1)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isPrimary
                        ? AnyShapeStyle(LinearGradient(
                            colors: [
                                Color(.sRGB, red: 1, green: 0.59, blue: 0.24, opacity: 1),
                                primaryColor,
                                Color(.sRGB, red: 0.92, green: 0.45, blue: 0, opacity: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom))
                        : AnyShapeStyle(LinearGradient(colors: [.primary.opacity(0.07), .primary.opacity(0.05)],
                                         startPoint: .top, endPoint: .bottom)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill((isPrimary ? Color.white : Color.primary).opacity(isEnabled && isHovering ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(isPrimary ? 0.25 : 0.08), lineWidth: 1)
            }
            .shadow(color: isPrimary ? primaryColor.opacity(0.12) : .clear, radius: 18, y: 4)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .onHover { isHovering = $0 }
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
