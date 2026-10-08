import SwiftUI

struct DetailPlayButtonConfiguration {
    let trackURN: String?
    var isCollection = false
    var isStarting = false
    let isPlaying: Bool
    var isEnabled = true
    let iconOnly: Bool
    var subject = ""

    var playLabel: String { isStarting ? "Start" : "Play" }
    var actionLabel: String { (isPlaying ? "Pause" : playLabel) + (subject.isEmpty ? "" : " \(subject)") }
}

struct DetailPlayButton: View {
    let configuration: DetailPlayButtonConfiguration
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            ZStack {
                Label(configuration.playLabel, systemImage: "play.fill")
                    .opacity(configuration.isPlaying ? 0 : 1)
                    .accessibilityHidden(configuration.isPlaying)
                Label("Pause", systemImage: "pause.fill")
                    .opacity(configuration.isPlaying ? 1 : 0)
                    .accessibilityHidden(!configuration.isPlaying)
            }
            .animation(nil, value: configuration.isPlaying)
            .foregroundStyle(configuration.isStarting ? Color.green : Color.primary)
            .font(.title3.weight(.semibold))
            .padding(.horizontal, configuration.iconOnly ? 0 : 24)
            .frame(width: configuration.iconOnly ? 44 : nil)
            .frame(minHeight: 24)
        }
        .labelStyle(DetailPlayButtonLabelStyle(iconOnly: configuration.iconOnly))
        .buttonStyle(TrackActionButtonStyle(
            fill: .primary.opacity(0.12)
        ))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: configuration.isStarting)
        .disabled(!configuration.isEnabled)
        .contentHelp(configuration.actionLabel)
        .accessibilityLabel(configuration.actionLabel)
    }
}

private struct DetailPlayButtonLabelStyle: LabelStyle {
    let iconOnly: Bool

    func makeBody(configuration: Configuration) -> some View {
        if iconOnly {
            configuration.icon
        } else {
            HStack {
                configuration.icon
                configuration.title
            }
        }
    }
}

// The page supplies sizing and behavior; the navigation host keeps the button mounted.
struct DetailPlayButtonSlot: View {
    let configuration: DetailPlayButtonConfiguration
    let action: () -> Void

    var body: some View {
        DetailPlayButton(configuration: configuration, action: action)
            .hidden()
            .accessibilityHidden(true)
            .anchorPreference(key: DetailPlayButtonPreferenceKey.self, value: .bounds) {
                DetailPlayButtonSource(bounds: $0, configuration: configuration, action: action)
            }
    }
}

struct DetailPlayButtonSource {
    let bounds: Anchor<CGRect>
    let configuration: DetailPlayButtonConfiguration
    let action: () -> Void
}

struct DetailPlayButtonPreferenceKey: PreferenceKey {
    static let defaultValue: DetailPlayButtonSource? = nil

    static func reduce(value: inout DetailPlayButtonSource?, nextValue: () -> DetailPlayButtonSource?) {
        value = nextValue() ?? value
    }
}

struct DetailPlayButtonOverlay: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(DetailPlayButtonPreferenceKey.self) { source in
            GeometryReader { geometry in
                if let source {
                    let bounds = geometry[source.bounds]
                    DetailPlayButton(configuration: source.configuration, action: source.action)
                        .modifier(FadeInOnAppear())
                        .transition(.identity)
                        .geometryGroup()
                        .frame(width: bounds.width, height: bounds.height)
                        .position(x: bounds.midX, y: bounds.midY)
                        .animation(nil, value: source.configuration.trackURN)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.3),
                            value: source.configuration.isCollection
                        )
                }
            }
            .clipped()
        }
    }
}
