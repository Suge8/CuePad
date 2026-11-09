import SwiftUI

/// 两端各只有一个记灵感的入口：
/// - iOS 项目页没有随手记，这一格就是入口——"记一条灵感"，点了新建一条并打开它的纸页；它说的是下一步，不是空态，不等 iCloud 对完。
/// - Mac 的入口是底部随手记，这一格只说现状"这里还没有灵感"，不可点；本机正在和 iCloud 对时（`AppServices.isCatchingUp`）
///   久过 `Pending.delay` 换成"正在同步"：新装的 Mac 上灵感一条条地到，先说"还没有"是错的。
struct EmptyWallTile: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    #if os(macOS)
    @Environment(AppServices.self) private var services
    @State private var syncing = false
    #endif

    private static let mascot: CGFloat = 72

    var body: some View {
        #if os(iOS)
        Button(action: workspace.newCard) { cell(.welcome) { Text("记一条灵感") } }
            .buttonStyle(PressStyle(.card))
        #else
        cell(syncing ? .search : .welcome) {
            if syncing { SyncingLabel() } else { Text("这里还没有灵感") }
        }
        .pending(services.isCatchingUp, shown: $syncing)
        .accessibilityElement(children: .combine)
        #endif
    }

    private func cell(_ mascot: Mascot, @ViewBuilder line: () -> some View) -> some View {
        VStack(spacing: Spacing.item) {
            Image(decorative: mascot.rawValue).resizable().scaledToFit()
                .frame(width: Self.mascot, height: Self.mascot)
                .readerHidden(true)
            line()
                .font(Typography.bodyStrong).foregroundStyle(palette.ink2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Spacing.group).padding(.vertical, Spacing.block)
        .frame(maxWidth: .infinity)
        .paper()
        .contentShape(.rect(cornerRadius: Radius.card))
    }
}
