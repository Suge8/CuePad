import SwiftUI

struct ContextBoundary: View {
    let title: String
    var highlighted = false
    @Environment(\.palette) private var palette

    var body: some View {
        ChatMarker(ruled: true, highlighted: highlighted, action: nil) {
            HStack(spacing: Spacing.glyph) {
                Image(.renew).imageScale(.small)
                Text(title).foregroundStyle(palette.ink2)
            }
        }
    }
}
