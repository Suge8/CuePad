import SwiftUI

/// 空态与出错页：吉祥物、一句现状、一句下一步、一个可选动作（动作按钮由平台给）。全 App 的空态都用它，不用系统的 `ContentUnavailableView`：
/// 吉祥物是品牌里唯一有表情的东西，空的时候正好让它出来。吉祥物出场时从下方轻轻弹上来，只这一次；减弱动态效果时直接在位。
struct EmptyState<Action: View>: View {
    let mascot: Mascot
    let title: String
    var message: String?
    @ViewBuilder var action: Action
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(spacing: 0) {
            Image(mascot.rawValue).resizable().scaledToFit().frame(height: 112)
                .scaleEffect(shown || reduceMotion ? 1 : 0.85, anchor: .bottom)
                .offset(y: shown || reduceMotion ? 0 : 10)
                .opacity(shown || reduceMotion ? 1 : 0)
                .accessibilityHidden(true)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(palette.ink).padding(.top, 14)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(palette.ink2).padding(.top, 6)
            }
            action.padding(.top, 20)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .onAppear { withAnimation(Motion.pressUp) { shown = true } }
    }
}

extension EmptyState where Action == EmptyView {
    init(mascot: Mascot, title: String, message: String? = nil) {
        self.init(mascot: mascot, title: title, message: message) { EmptyView() }
    }

    /// 没搜到；没有搜索词（只按条件筛）时不复述空词。
    static func noMatch(_ query: String) -> Self {
        EmptyState(mascot: .search, title: query.isEmpty ? "没有符合条件的结果" : "没有找到“\(query)”", message: "换个词或条件试试")
    }
}

/// 吉祥物的表情，对应 Assets 里的 `mascot-*` 图（由 `design/final/ip-*.png` 经 `design/tools/cutout.swift` 抠图、缩到 360px）。
enum Mascot: String {
    /// 打招呼：空库首次打开。
    case welcome = "mascot-welcome"
    /// 摊手：这里还没有东西。
    case empty = "mascot-empty"
    /// 拿放大镜：没搜到。
    case search = "mascot-search"
    /// 靠着垃圾桶睡着：回收站是空的。
    case trash = "mascot-trash"
    /// 捂嘴笑：都处理完了。
    case clean = "mascot-clean"
    /// 挠头：出错了。
    case error = "mascot-error"
}

/// 项目页与未分类还没有灵感：一句现状加一颗"记一条"，记到这里（iOS 浮起随手记，Mac 聚焦底部输入栏，由 `write` 给）。Mac 与 iOS 同一份。
struct EmptyIdeas: View {
    let write: () -> Void

    var body: some View {
        EmptyState(mascot: .empty, title: "还没有灵感") {
            #if os(iOS)
            Button("记一条", action: write).prominentButton().controlSize(.large)
            #else
            Button(action: write) { Text("记一条").primaryCapsule() }.buttonStyle(PressStyle())
            #endif
        }
    }
}

/// 空库首次打开：Mac 与 iOS 同一段话；动作按钮由平台给（各自的主按钮样式）。
struct EmptyLibrary<Action: View>: View {
    @ViewBuilder let action: Action

    var body: some View {
        EmptyState(mascot: .welcome, title: "还没有项目", message: "建一个项目放灵感，或者先在下方随手记一条") { action }
    }
}
