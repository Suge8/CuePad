#if os(macOS)
import SwiftUI

struct StoredRow<Mark: View, Actions: View>: View {
    let title: String
    let detail: String
    let stamp: Date?
    @ViewBuilder let mark: Mark
    @ViewBuilder let actions: Actions
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.item) {
            mark.font(Glyph.row).frame(width: Self.markWidth)
            Text(title).font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
            Text(detail).font(Typography.secondary).lineLimit(1)
            Spacer(minLength: Spacing.group)
            if let stamp { Text(DateLabel.short(stamp)).font(Typography.meta.monospacedDigit()).fixedSize().yieldsToReveal() }
        }
        .foregroundStyle(palette.ink3)
        .frame(height: Self.height)
        .contentShape(.rect)
        .hoverReveal {
            HStack(spacing: Spacing.tight) { actions }
                .labelStyle(.iconOnly).buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
                .padding(.horizontal, Spacing.tight)
        }
        .row()
    }

    private static var markWidth: CGFloat { 18 }
    private static var height: CGFloat { 38 }
}

extension View {
    func storedList() -> some View {
        frame(maxWidth: Spacing.reading, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, Spacing.page).padding(.bottom, Spacing.section)
    }
}
#endif
