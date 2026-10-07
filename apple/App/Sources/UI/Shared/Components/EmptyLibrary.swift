import SwiftUI

/// 空库首次打开：一个图标、一句现状、一句下一步、一个动作。Mac 与 iOS 用同一段话；动作按钮由平台给（各自的主按钮样式）。
struct EmptyLibrary<Action: View>: View {
    @ViewBuilder let action: Action
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "books.vertical").font(.system(size: 40, weight: .light)).foregroundStyle(palette.ink3)
                .accessibilityHidden(true)
            Text("还没有项目").font(.title3.weight(.semibold)).foregroundStyle(palette.ink).padding(.top, 16)
            Text("建一个项目放灵感，或者先在下方随手记一条").font(.subheadline).foregroundStyle(palette.ink2)
                .multilineTextAlignment(.center).padding(.top, 8)
            action.padding(.top, 20)
        }
        .frame(maxWidth: .infinity)
    }
}
