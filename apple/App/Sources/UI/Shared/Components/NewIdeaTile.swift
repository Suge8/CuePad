import SwiftUI

/// 项目里一条灵感都没有时卡片墙上的那一格（两端项目页同一个，项目全空时也是它；有灵感时不出现）：一格纸，上面吉祥物、下面"记一条灵感"，整格可点。
/// iOS 新建一条并打开它的纸页，Mac 聚焦底部输入栏。不说"还没有"：它是入口，不是空态，也就不等 iCloud 对完（`EmptyState.waitsForSync`）。
/// 字只有一行、按格宽缩一点，不折行、不竖排；手机辅助字号下这一格铺满整行（`ProjectScreen`）。
struct NewIdeaTile: View {
    let action: () -> Void
    @Environment(\.palette) private var palette

    private static let mascot: CGFloat = 72
    private static let radius: CGFloat = 16

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(Mascot.welcome.rawValue).resizable().scaledToFit()
                    .frame(width: Self.mascot, height: Self.mascot)
                    .accessibilityHidden(true)
                Text("记一条灵感")
                    .font(Typography.bodyStrong).foregroundStyle(palette.ink2)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 14).padding(.vertical, 18)
            .frame(maxWidth: .infinity)
            .paper(radius: Self.radius)
            .contentShape(.rect(cornerRadius: Self.radius))
        }
        .buttonStyle(PressStyle(.card))
    }
}
