import SwiftUI

@main
struct SoundClaudeApp: App {
    @StateObject private var model: AppModel
    @ObservedObject private var auth: AuthController
    @ObservedObject private var likes: LikesController
    @State private var isShowingKeyboardShortcuts = false

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        _auth = ObservedObject(wrappedValue: model.auth)
        _likes = ObservedObject(wrappedValue: model.likes)
    }

    var body: some Scene {
        WindowGroup {
            mainView
                .frame(minWidth: 760, minHeight: 620)
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
        .commands {
            appCommands()
        }
    }

    @ViewBuilder
    private var mainView: some View {
        switch auth.state {
        case .signedOut:
            SignedOutView(message: model.errorMessage) {
                Task { await model.signIn() }
            }
        case let .failed(message):
            SignedOutView(message: message) {
                Task { await model.signIn() }
            }
        case .restoring:
            progressView(label: "Restoring SoundCloud session")
        case .signingIn:
            progressView(label: "Waiting for SoundCloud sign-in")
        case let .signedIn(user):
            SignedInView(user: user, model: model)
        }
    }

    private func progressView(label: String) -> some View {
        ProgressView()
            .accessibilityLabel(label)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @CommandsBuilder
    private func appCommands() -> some Commands {
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
            .keyboardShortcut("s", modifiers: [])

            Button("Cycle Repeat") {
                model.playback.cycleRepeatMode()
            }
            .keyboardShortcut("r", modifiers: [])

            Button("Like or Unlike Current Track") {
                model.toggleCurrentTrackLike()
            }
            .keyboardShortcut("l", modifiers: [])
            .disabled(model.playback.currentTrack.map {
                likes.updatingTrackURNs.contains($0.urn)
            } ?? true)

            Button("Seek Back 5 Seconds") {
                model.playback.seek(by: -5)
            }
            .keyboardShortcut(.leftArrow, modifiers: [])

            Button("Seek Forward 5 Seconds") {
                model.playback.seek(by: 5)
            }
            .keyboardShortcut(.rightArrow, modifiers: [])

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

        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") {
                isShowingKeyboardShortcuts.toggle()
            }
            .keyboardShortcut("?", modifiers: [])
        }
    }
}
