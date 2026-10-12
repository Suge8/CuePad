import SwiftUI

/// 空态与出错页：吉祥物、一句现状、一句下一步、一个可选动作。全 App 共用这一套布局。
/// 整页尺寸的那张纸与所在页面的内容同宽（左右边线与标题、其他纸对齐，中轴就是页面的中轴），纸里的字居中、最宽 420。
/// 吉祥物出场时从下方轻轻弹上来，只这一次；减弱动态效果时直接在位。
struct EmptyState<Action: View>: View {
    let mascot: Mascot
    let title: String
    var message: String?
    var compact = false
    @ViewBuilder var action: Action
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var shown = false

    var body: some View {
        Group {
            if compact {
                // 辅助字号改为上下排，按钮不挤掉标题与说明。
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(spacing: 12))
                layout {
                    illustration
                    copy
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
                    action
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 16) {
                    illustration
                    copy
                    action
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .paper(radius: compact ? 18 : 24)
        .scaleEffect(shown || reduceMotion ? 1 : 0.97)
        .opacity(shown || reduceMotion ? 1 : 0)
        .buttonStyle(ControlButtonStyle(kind: .primary))
        .onAppear { withAnimation(reduceMotion ? Motion.quick : Motion.snappy) { shown = true } }
    }

    private var illustration: some View {
        Image(mascot.rawValue).resizable().scaledToFit()
            .frame(width: compact ? 48 : 104, height: compact ? 48 : 104)
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: compact ? .leading : .center, spacing: compact ? 4 : 6) {
            Text(title).font(compact ? Typography.secondary.weight(.medium) : Typography.emptyTitle)
                .foregroundStyle(palette.ink)
            if let message {
                Text(message).font(compact ? Typography.meta : Typography.secondary)
                    .foregroundStyle(palette.ink2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
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

/// 空态的动作按钮：small 给纸卡里的次要动作（墨色：页上已有任务或会话时焦点不在它，签名色留给页上别处），
/// primary 给整页唯一的主动作。两种尺寸共用同一字体、圆角、线宽、按压和触感。
struct EmptyStateButton: View {
    enum Kind { case small, primary }

    let title: String
    let systemImage: String?
    var kind = Kind.primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(ControlButtonStyle(kind: kind == .small ? .secondary : .primary, compact: kind == .small))
    }
}

/// 吉祥物的表情，对应 Assets 里的 mascot 图。
enum Mascot: String {
    case welcome = "mascot-welcome"
    case empty = "mascot-empty"
    case search = "mascot-search"
    case trash = "mascot-trash"
    case clean = "mascot-clean"
    case error = "mascot-error"
    case hello = "mascot-hello"
}

/// 项目页与未分类还没有灵感：任务存在时用轻量纸卡；完全空时复用 EmptyState 的整页布局。
/// iOS 浮起随手记，Mac 聚焦底部输入栏；两端按钮、图标、按压与出现动效共用。
struct EmptyIdeas: View {
    var compact = false
    let write: () -> Void

    var body: some View {
        EmptyState(mascot: .empty, title: "还没有灵感", message: "随时记下新的想法", compact: compact) {
            EmptyStateButton(title: "记一条", systemImage: "square.and.pencil", kind: compact ? .small : .primary, action: write)
                .accessibilityLabel("记一条灵感")
        }
    }
}

/// 空库首次打开：Mac 与 iOS 同一段话；动作按钮由平台给。
struct EmptyLibrary<Action: View>: View {
    @ViewBuilder let action: Action

    var body: some View {
        EmptyState(mascot: .welcome, title: "还没有项目", message: "建一个项目放灵感，或者先在下方随手记一条") { action }
    }
}
