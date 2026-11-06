import SwiftUI

struct PlayerSpeedControl: View {
    @Bindable var playback: PlaybackController
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingSpeed = false

    private var rateLabel: String {
        playback.playbackRate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }

    var body: some View {
        Button {
            isShowingSpeed.toggle()
        } label: {
            Text(rateLabel)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isShowingSpeed ? Color.orange : Color.primary)
                .frame(width: 44, height: 44)
                .modifier(PlayerSpeedHoverFeedback(color: .orange, isActive: isShowingSpeed, cornerRadius: 22))
        }
        .buttonStyle(PlayerFooterButtonStyle())
        .keyboardShortcut("x", modifiers: [])
        .contentHelp("Playback speed and pitch (X)")
        .accessibilityLabel("Playback speed and pitch")
        .accessibilityValue(rateLabel)
        .popover(isPresented: $isShowingSpeed, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Speed")
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    HStack(spacing: 8) {
                        presetButton("Slower", semitones: -4)
                        presetButton("Faster", semitones: 3)
                    }
                }
                PlayerSpeedSlider(value: Binding(
                    get: { playback.playbackRate },
                    set: { playback.setPlaybackRate($0) }
                ))
            }
            .padding(20)
            .frame(width: 340)
            // The popover is its own key window, so the footer button's shortcut can't close it.
            .background {
                Button("Close speed") { isShowingSpeed = false }
                    .keyboardShortcut("x", modifiers: [])
                    .hidden()
                    .accessibilityHidden(true)
            }
            // Matches the queue panel's tint behind the glass.
            .background {
                (colorScheme == .dark ? Color.black : Color.white)
                    .opacity(colorScheme == .dark ? 0.4 : 0.6)
                    .ignoresSafeArea()
            }
        }
    }

    private func presetButton(_ title: String, semitones: Int) -> some View {
        let presetRate = Float(pow(2.0, Double(semitones) / 12))
        let isActive = playback.playbackRate == presetRate
        let rate = presetRate.formatted(.number.precision(.fractionLength(0...2))) + "×"
        return Button {
            // Clicking the active preset returns to normal speed.
            playback.setPlaybackRate(isActive ? 1 : presetRate)
        } label: {
            Text(title)
                .font(.body)
                .foregroundStyle(isActive ? Color.orange : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .contentShape(RoundedRectangle(cornerRadius: PlayerSpeedHoverFeedback.defaultCornerRadius))
        }
        .buttonStyle(.plain)
        .modifier(PlayerSpeedHoverFeedback(color: .orange, isActive: isActive))
        .contentHelp(rate)
        .accessibilityValue(rate)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

private struct PlayerSpeedHoverFeedback: ViewModifier {
    var color: Color = .primary
    var isActive: Bool = false
    var cornerRadius: CGFloat = defaultCornerRadius

    static let defaultCornerRadius: CGFloat = 10

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(isActive ? color.opacity(0.12) : Color.primary.opacity(isHovering && isEnabled ? 0.08 : 0))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(color.opacity(isActive && isHovering && isEnabled ? 0.12 * 0.7 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onContentHover { isHovering = $0 }
            .animation(.easeInOut(duration: 0.15), value: isHovering && isEnabled)
    }
}

private struct PlayerSpeedSlider: View {
    @Binding var value: Float

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isDragging = false
    @State private var isHovering = false
    @State private var hoverLocation: CGPoint?
    @FocusState private var isFocused: Bool

    // Steps are semitones, so they sit evenly on the log track: 0.5× and 2× are an octave from 1×.
    private let semitoneRange = -12...12
    // 0.75× and 1.5× are a fourth below and a fifth above, within 0.002×.
    private let markSemitones = [-12, -5, 0, 7, 12]
    private var marks: [Float] { markSemitones.map(speed(semitones:)) }
    private var steps: [Float] {
        semitoneRange.filter { !markSemitones.contains($0) }.map(speed(semitones:))
    }
    private let inset: CGFloat = 8
    private let trackHeight: CGFloat = 32

    private func fraction(_ speed: Float) -> CGFloat {
        // Equal speed ratios occupy equal distances: 0.5×, 1×, 2×.
        CGFloat((log2(min(max(speed, 0.5), 2)) + 1) / 2)
    }

    private func speed(semitones: Int) -> Float {
        Float(pow(2.0, Double(semitones) / 12))
    }

    private func semitones(_ speed: Float) -> Int {
        Int((12 * log2(speed)).rounded())
    }

    private func speed(at location: CGPoint, length: CGFloat) -> Float {
        let position = min(max((location.x - inset) / length, 0), 1)
        // Below the track, snap to the labeled markers.
        if location.y >= trackHeight {
            return marks.min { abs(fraction($0) - position) < abs(fraction($1) - position) }!
        }
        return speed(semitones: Int((position * 24).rounded()) - 12)
    }

    private func hoverIndicatorPosition(for speed: Float, length: CGFloat) -> CGFloat {
        let snappedPosition = inset + length * fraction(speed)
        guard !reduceMotion, let hoverLocation, hoverLocation.y < trackHeight else {
            return snappedPosition
        }
        let pointerPosition = min(max(hoverLocation.x, inset), inset + length)
        // Pull slightly toward the pointer while keeping the line anchored to its tick.
        return snappedPosition + (pointerPosition - snappedPosition) * 0.3
    }

    var body: some View {
        GeometryReader { geometry in
            let length = max(geometry.size.width - inset * 2, 1)
            let previewSpeed = isHovering && !isDragging
                ? hoverLocation.map { speed(at: $0, length: length) } : nil
            let previewPosition = previewSpeed.map { inset + length * fraction($0) }
            let isPreviewingLabels = (hoverLocation?.y ?? 0) >= trackHeight
            VStack(spacing: 0) {
                track(
                    width: geometry.size.width,
                    length: length,
                    previewPosition: previewSpeed.map { hoverIndicatorPosition(for: $0, length: length) }
                )
                ZStack(alignment: .topLeading) {
                    ForEach(marks, id: \.self) { mark in
                        // Highlight fixed labels in place; a traveling copy can overlap its neighbors.
                        markerLabel(mark, isHighlighted: isPreviewingLabels && previewSpeed == mark)
                            .opacity(!isPreviewingLabels && previewPosition.map { abs($0 - (inset + length * fraction(mark))) < 36 } == true ? 0 : 1)
                            .position(x: inset + length * fraction(mark), y: 22)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: previewSpeed)
                    }
                }
                .frame(width: geometry.size.width, height: 32)
                .overlay(alignment: .topLeading) {
                    if !isPreviewingLabels, let previewSpeed, let previewPosition {
                        markerLabel(previewSpeed, isHighlighted: true)
                            .position(x: previewPosition, y: 22)
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: previewSpeed)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                Text(value.formatted(.number.precision(.fractionLength(0...2))) + "×")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .fixedSize()
                    .position(x: inset + length * fraction(value), y: -9)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            // The marker labels and end margins are interactive too; speed(at:) clamps to the endpoints.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isDragging) { _, dragging, _ in dragging = true }
                    .onChanged { gesture in
                        isFocused = true
                        value = speed(at: gesture.location, length: length)
                    }
            )
            .onContentHover { isHovering = $0 }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverLocation = location
                case .ended: hoverLocation = nil
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onMoveCommand { direction in
                switch direction {
                case .left, .down: value = speed(semitones: max(semitones(value) - 1, -12))
                case .right, .up: value = speed(semitones: min(semitones(value) + 1, 12))
                default: break
                }
            }
            .accessibilityRepresentation {
                Slider(value: Binding(
                    get: { Double(semitones(value)) },
                    set: { value = speed(semitones: Int($0.rounded())) }
                ), in: -12...12, step: 1)
                    .accessibilityLabel("Playback speed")
                    .accessibilityValue(value.formatted(.number.precision(.fractionLength(0...2))) + "×")
            }
        }
        .frame(height: trackHeight + 32)
        // Room for the current value label.
        .padding(.top, 10)
    }

    private func track(width: CGFloat, length: CGFloat, previewPosition: CGFloat?) -> some View {
        // Overlays keep the hover indicator from changing the track's layout size.
        // The track fills the end margins; speeds map onto the inset span between them.
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return shape
            .fill(Color.primary.opacity(isDragging ? 0.24 : 0.16))
            .frame(width: width, height: trackHeight)
            .overlay(alignment: .topLeading) {
                ForEach(steps, id: \.self) { step in
                    Capsule()
                        .fill(Color.primary.opacity(isDragging ? 0.36 : 0.26))
                        .frame(width: 1, height: 5)
                        .position(x: inset + length * fraction(step), y: trackHeight / 2)
                }
            }
            .overlay(alignment: .topLeading) {
                ForEach(marks, id: \.self) { mark in
                    Capsule()
                        .fill(Color.primary.opacity(isDragging ? 0.36 : 0.26))
                        .frame(width: 2, height: 12)
                        .position(x: inset + length * fraction(mark), y: trackHeight / 2)
                }
            }
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: trackHeight)
                    .position(x: inset + length * fraction(value), y: trackHeight / 2)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: value)
            }
            .overlay(alignment: .topLeading) {
                if let previewPosition {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: 2, height: trackHeight)
                        .position(x: previewPosition, y: trackHeight / 2)
                        .animation(reduceMotion ? nil : .spring(response: 0.18, dampingFraction: 0.75), value: previewPosition)
                }
            }
        .clipShape(shape)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDragging)
    }

    private func markerLabel(_ speed: Float, isHighlighted: Bool = false) -> some View {
        let label = speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
        return Text(label)
            .font(.system(size: 14, weight: speed == 1 ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(Color.primary)
            .opacity(isHighlighted ? 1 : 0.45)
            .frame(width: 44, height: 44)
            .allowsHitTesting(false)
    }
}
