import AppKit
import SwiftUI

/// A vertical scroll view that reserves space for the system's legacy scrollbar.
struct ScrollbarReservedScrollView<Content: View>: View {
    @ViewBuilder let content: (CGSize) -> Content

    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    var body: some View {
        GeometryReader { geometry in
            let scrollbarWidth = scrollerStyle == .legacy
                ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
                : 0
            let contentSize = CGSize(
                width: max(0, geometry.size.width - scrollbarWidth),
                height: geometry.size.height
            )

            ScrollView {
                content(contentSize)
                    // AppKit can defer its narrower width proposal until the first scroll.
                    .frame(width: contentSize.width)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: geometry.size.width)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
    }
}
