import SwiftUI

@main
struct SoundClaudeApp: App {
    @StateObject private var model = AppModel()
    @State private var isShowingKeyboardShortcuts = false

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .sheet(isPresented: $isShowingKeyboardShortcuts) {
                    KeyboardShortcutsView()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandMenu("Playback") {
                Button("Play or Pause") {
                    model.playback.togglePlayPause()
                }
                .keyboardShortcut(.space, modifiers: [])

                Button("Mute or Unmute") {
                    model.playback.toggleMute()
                }
                .keyboardShortcut("m", modifiers: [])

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
                    isShowingKeyboardShortcuts = true
                }
                .keyboardShortcut("?", modifiers: [])
            }
        }
    }
}
