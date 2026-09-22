import AppKit
import SwiftUI

struct PlayerVolumeControl: View {
    @Bindable var playback: PlaybackController
    let usesCompactVolume: Bool

    private let sliderLength: CGFloat = 90

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isPressingVolume = false
    @State private var isShowingVolume = false
    @State private var isHoveringVolumeButton = false
    @State private var isHoveringVolumePopover = false
    @State private var isVolumePopoverPinned = false

    private var displayedVolume: Float {
        playback.isMuted ? 0 : playback.volume
    }

    private var shouldDismissVolume: Bool {
        isShowingVolume && !isHoveringVolumeButton && !isHoveringVolumePopover
            && !isPressingVolume && !isVolumePopoverPinned
    }

    var body: some View {
        HStack(spacing: 4) {
            Button {
                if usesCompactVolume {
                    isVolumePopoverPinned = true
                    isShowingVolume = true
                } else {
                    playback.toggleMute()
                }
            } label: {
                volumeSymbol
                    .frame(width: usesCompactVolume ? 32 : 24, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(usesCompactVolume ? "Show volume" : (playback.isMuted ? "Unmute" : "Mute"))
            .accessibilityLabel(usesCompactVolume ? "Show volume" : (playback.isMuted ? "Unmute" : "Mute"))
            .background {
                VolumeRightClickView(onRightClick: playback.toggleMute)
            }
            .accessibilityAction(named: playback.isMuted ? "Unmute" : "Mute") {
                playback.toggleMute()
            }
            .onContentHover { hovering in
                isHoveringVolumeButton = hovering
                if hovering && usesCompactVolume { isShowingVolume = true }
            }
            // The arrow edge refers to the button's attachment anchor.
            .popover(isPresented: $isShowingVolume, arrowEdge: .top) {
                volumeSlider(axis: .vertical)
                    .frame(width: 24, height: sliderLength)
                    .padding(12)
                    .contentShape(Rectangle())
                    .onHover { isHoveringVolumePopover = $0 }
            }

            if !usesCompactVolume {
                volumeSlider(axis: .horizontal)
                    .frame(width: sliderLength)
            }
        }
        .task(id: shouldDismissVolume) {
            guard shouldDismissVolume else { return }
            // Allow the pointer to cross from the button into the popover.
            do {
                try await Task.sleep(for: .milliseconds(350))
                isShowingVolume = false
            } catch { }
        }
        .onChange(of: isShowingVolume) { _, isShowing in
            if !isShowing {
                isVolumePopoverPinned = false
                isHoveringVolumePopover = false
            }
        }
        .onChange(of: usesCompactVolume) { _, _ in
            isShowingVolume = false
        }
    }

    private var volumeSymbol: some View {
        ZStack {
            if playback.volume == 0 || playback.isMuted {
                Image(systemName: "speaker.slash.fill")
            } else {
                Image(systemName: "speaker.wave.3.fill", variableValue: Double(playback.volume))
            }
        }
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(Color(white: isPressingVolume ? 1 : 0.65))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isPressingVolume)
    }

    private func volumeSlider(axis: Axis) -> some View {
        PlayerVolumeSlider(value: Binding(
            get: { displayedVolume },
            set: {
                playback.volume = $0
                playback.isMuted = false
            }
        ), pressState: $isPressingVolume, axis: axis)
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(displayedVolume * 100)) percent")
    }

}

private struct PlayerVolumeSlider: View {
    @Binding var value: Float
    let pressState: GestureState<Bool>
    var axis: Axis = .horizontal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool

    private var isPressed: Bool { pressState.wrappedValue }

    var body: some View {
        GeometryReader { geometry in
            let isVertical = axis == .vertical
            let length = isVertical ? geometry.size.height : geometry.size.width
            let fillLength = length * CGFloat(min(max(value, 0), 1))

            ZStack(alignment: isVertical ? .bottom : .leading) {
                Capsule()
                    .fill(.white.opacity(0.18))
                    .frame(width: isVertical ? 8 : nil, height: isVertical ? nil : 8)

                Rectangle()
                    .fill(.white.opacity(isPressed ? 1 : 0.65))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isPressed)
                    .frame(width: isVertical ? 8 : fillLength, height: isVertical ? fillLength : 8)
            }
            .clipShape(Capsule())
            .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.8), value: value)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating(pressState) { _, isPressed, _ in
                        isPressed = true
                    }
                    .onChanged { gesture in
                        isFocused = true
                        guard length > 0 else { return }
                        let position = isVertical ? length - gesture.location.y : gesture.location.x
                        value = Float(min(max(position / length, 0), 1))
                    }
            )
        }
        .frame(width: axis == .vertical ? 24 : nil, height: axis == .horizontal ? 24 : nil)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left, .down:
                value = max(0, value - 0.05)
            case .right, .up:
                value = min(1, value + 0.05)
            default:
                break
            }
        }
        .accessibilityRepresentation {
            Slider(value: $value, in: 0...1)
                .accessibilityLabel("Volume")
                .accessibilityValue("\(Int(value * 100)) percent")
        }
    }
}

private struct VolumeRightClickView: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onRightClick = onRightClick
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onRightClick = onRightClick
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onRightClick: (() -> Void)?
        private var monitor: Any?

        // Let SwiftUI continue to handle left-clicks and hover.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }

            monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) {
                [weak self] event in
                guard let self,
                      let window = self.window,
                      event.window === window,
                      !self.isHiddenOrHasHiddenAncestor else { return event }

                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.intersection(self.visibleRect).contains(location) else {
                    return event
                }
                self.onRightClick?()
                return nil
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}
