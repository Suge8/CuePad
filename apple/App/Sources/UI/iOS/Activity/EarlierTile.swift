#if os(iOS)
import CueStore
import SwiftUI

/// 个数与"更早"那一页读同一个查询（`PiSessionList.earlier`），两边才对得上。
struct EarlierTile: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var total: Int?

    var body: some View {
        Group {
            if let total, total > 0 {
                Button { workspace.push(.earlier) } label: {
                    VStack(spacing: Spacing.hair) {
                        Text("更早").foregroundStyle(palette.ink2)
                        Text(total, format: .number).foregroundStyle(palette.ink3).monospacedDigit()
                    }
                    .font(Typography.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: Self.height)
                    .contentShape(.rect)
                }
                .buttonStyle(PressStyle(.card))
                .paper(cornerRadius: Radius.block)
                .accessibilityLabel(Text("更早"))
                .accessibilityValue(Text(total, format: .number))
            } else {
                // 读库的订阅要挂在一个真的视图上（docs/layout.md）
                Color.clear.frame(height: 0)
            }
        }
        .padding(.horizontal, SessionRail.phoneInset)
        .frame(width: SessionRail.Form.phone.width)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .observing(services.store, id: services.speech, into: $total, onError: workspace.fail) { [moment = services.speech] store in
            try PiSessionList.earlier(PiSessionQuery(limit: 1), at: moment, from: store).total
        }
    }

    private static let height: CGFloat = 44
}
#endif
