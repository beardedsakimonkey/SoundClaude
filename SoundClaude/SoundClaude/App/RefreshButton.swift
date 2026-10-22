import SwiftUI

struct RefreshButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let title: String
    let isLoading: Bool
    let action: () -> Void

    @State private var isHovered = false
    @State private var rotation = 0.0
    @State private var refreshCount = 0

    var body: some View {
        Button {
            if !reduceMotion {
                if #available(macOS 15.0, *) {
                    refreshCount += 1
                } else {
                    rotation += 360
                }
            }
            action()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary.opacity(isLoading ? 0.3 : isHovered ? 1 : 0.6))
                .animation(reduceMotion || isLoading ? nil : .easeInOut(duration: 0.2), value: isLoading)
                .modifier(RefreshRotateEffect(value: refreshCount))
                .frame(width: 32, height: 32)
                .rotationEffect(.degrees(rotation), anchor: UnitPoint(x: 0.5, y: 0.55))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: rotation)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .disabled(isLoading)
        .onContentHover { isHovered = $0 }
        .contentHelp(title)
    }
}

private struct RefreshRotateEffect: ViewModifier {
    let value: Int

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.symbolEffect(.rotate.clockwise, options: .nonRepeating.speed(2), value: value)
        } else {
            content
        }
    }
}
