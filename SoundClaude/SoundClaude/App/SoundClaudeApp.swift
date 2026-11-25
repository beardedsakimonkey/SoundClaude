import SwiftUI

@main
struct SoundClaudeApp: App {
    @NSApplicationDelegateAdaptor(DockMenuDelegate.self) private var dockMenuDelegate
    @State private var model: AppModel
    @ObservedObject private var auth: AuthController
    @State private var isShowingKeyboardShortcuts = false

    init() {
        #if DEBUG
        setvbuf(stdout, nil, _IOLBF, 0)
        #endif
        let launch = LaunchMetrics.begin("App initialization")
        defer { LaunchMetrics.end(launch) }
        TextFocusKeys.install()
        let model = AppModel()
        _model = State(initialValue: model)
        _auth = ObservedObject(wrappedValue: model.auth)
        dockMenuDelegate.model = model
    }

    var body: some Scene {
        WindowGroup {
            mainView
                .frame(minWidth: 760, minHeight: 600)
                .onAppear { LaunchMetrics.markOnce("Root view appeared") }
                .task {
                    await model.start()
                }
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.willTerminateNotification
                )) { _ in
                    model.playback.saveSession()
                }
                .sheet(isPresented: $isShowingKeyboardShortcuts) {
                    KeyboardShortcutsView()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1030, height: 620)
        .commands {
            PlaybackCommands(model: model)
            QueueCommands()
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") {
                    isShowingKeyboardShortcuts.toggle()
                }
                .keyboardShortcut("?", modifiers: [])
            }
            #if DEBUG
            ViewUpdateDebugCommands()
            #endif
        }
        #if DEBUG
        Window("Network Activity", id: "network-activity") {
            NetworkActivityView()
        }
        .defaultSize(width: 1100, height: 650)
        Window("Cache Inspector", id: "cache-inspector") {
            CacheInspectorView(model: model)
        }
        .defaultSize(width: 1200, height: 700)
        #endif
    }

    @ViewBuilder
    private var mainView: some View {
        if let login = model.websiteLogin {
            WebsiteSignInView(login: login, cancel: model.cancelSignIn)
        } else {
            authStateView
        }
    }

    /// The signed-out view stays up through a copied-session import, so its
    /// button can show the outcome, and keeps one identity across failures.
    private var showsSignedOutView: Bool {
        if model.sessionImportPhase != nil { return true }
        switch auth.state {
        case .signedOut, .failed: return true
        case .restoring, .signingIn, .signedIn: return false
        }
    }

    @ViewBuilder
    private var authStateView: some View {
        if showsSignedOutView {
            SignedOutView(
                message: model.errorMessage ?? authFailureMessage,
                importPhase: model.sessionImportPhase,
                importFailureCount: model.importFailureCount,
                savedAccounts: auth.savedAccounts,
                artworkLoader: model.artworkLoader,
                onSelectSavedAccount: { user in Task { await model.signIn(savedAccount: user) } },
                onForgetSavedAccount: model.forgetSavedAccount,
                onSignIn: model.beginSignIn,
                onImportSession: { Task { await model.importCopiedSession() } }
            )
        } else {
            switch auth.state {
            case .restoring:
                progressView(label: "Restoring SoundCloud session")
            case .signingIn:
                progressView(label: "Signing in to SoundCloud")
            case let .signedIn(user):
                SignedInView(user: user, model: model)
                    .modifier(FadeInOnAppear())
                    .onAppear { LaunchMetrics.markOnce("Signed-in view appeared") }
            case .signedOut, .failed:
                EmptyView()
            }
        }
    }

    private var authFailureMessage: String? {
        if case let .failed(message) = auth.state { message } else { nil }
    }

    private func progressView(label: String) -> some View {
        LoadingSpinner()
            .accessibilityLabel(label)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
private final class DockMenuDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model else { return nil }
        let playback = model.playback
        let menu = NSMenu()
        menu.autoenablesItems = false

        func add(_ title: String, action: Selector, enabled: Bool) {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = playback
            item.isEnabled = enabled
        }

        let active = playback.isPlaybackActive
        add(active ? "Pause" : "Play",
            action: active ? #selector(PlaybackController.pause) : #selector(PlaybackController.play),
            enabled: playback.currentTrack != nil)
        let hasQueue = !model.queue.tracks.isEmpty
        add("Next Track", action: #selector(PlaybackController.next), enabled: hasQueue)
        add("Previous Track", action: #selector(PlaybackController.previous), enabled: hasQueue)
        return menu
    }
}

// Menu state must not invalidate the window content.
private struct PlaybackCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play or Pause") {
                model.playback.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])

            Button("Mute or Unmute") {
                model.playback.toggleMute()
            }
            .keyboardShortcut("m", modifiers: [])

            Button("Increase Volume") {
                model.playback.volume = min(model.playback.volume + 0.05, 1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.shift])

            Button("Decrease Volume") {
                model.playback.volume = max(model.playback.volume - 0.05, 0)
            }
            .keyboardShortcut(.downArrow, modifiers: [.shift])

            Button("Toggle Shuffle") {
                model.toggleShuffle()
            }
            .keyboardShortcut("s", modifiers: [.shift])

            Button("Cycle Repeat") {
                model.playback.cycleRepeatMode()
            }
            .keyboardShortcut("r", modifiers: [])

            Button("Like or Unlike Current Track") {
                model.toggleCurrentTrackLike()
            }
            .keyboardShortcut("l", modifiers: [])
            .disabled(model.playback.currentTrack == nil)

            Button("Seek Back 5 Seconds") {
                model.playback.seek(by: -5)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("Seek Forward 5 Seconds") {
                model.playback.seek(by: 5)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

            // Control-arrow is reserved for switching macOS Spaces.
            Button("Seek Back 30 Seconds") {
                model.playback.seek(by: -30)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.option])

            Button("Seek Forward 30 Seconds") {
                model.playback.seek(by: 30)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.option])

            ForEach(0..<10, id: \.self) { digit in
                Button("Seek to \(digit * 10)%") {
                    model.playback.jump(toFraction: Double(digit) / 10)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(digit))), modifiers: [])
                .disabled(model.playback.currentTrack == nil)
            }

            Divider()

            Button("Previous Track") {
                model.playback.previous()
            }
            .keyboardShortcut(.leftArrow, modifiers: [.shift])

            Button("Next Track") {
                model.playback.next()
            }
            .keyboardShortcut(.rightArrow, modifiers: [.shift])
        }
    }
}
