import SwiftUI

/// 项目里一条灵感都没有时卡片墙上的那一格（两端项目页同一格纸，项目全空时也是它；有灵感时不出现）：上面吉祥物，下面一行字。
/// 两端各只有一个记灵感的入口：
/// - iOS 项目页没有随手记，这一格就是入口——"记一条灵感"，点了新建一条并打开它的纸页；它说的是下一步，不是空态，不等 iCloud 对完。
/// - Mac 的入口是底部随手记，这一格只说现状"这里还没有灵感"，不可点；本机正在和 iCloud 对时（`AppServices.isCatchingUp`）
///   久过 `Pending.delay` 换成"正在同步"：新装的 Mac 上灵感一条条地到，先说"还没有"是错的。
/// 字只有一行、按格宽缩一点，不折行、不竖排；手机辅助字号下墙只排一列，这一格铺满整行（`ProjectScreen`）。
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
        VStack(spacing: 10) {
            Image(mascot.rawValue).resizable().scaledToFit()
                .frame(width: Self.mascot, height: Self.mascot)
                .accessibilityHidden(true)
            line()
                .font(Typography.bodyStrong).foregroundStyle(palette.ink2)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 14).padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .paper()
        .contentShape(.rect(cornerRadius: Radius.card))
    }
}
