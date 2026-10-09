import SwiftUI

/// 空态与出错页：吉祥物、一句现状、一句下一步、一个可选动作（动作按钮由平台给）。全 App 的空态都用它，不用系统空态组件。
/// 吉祥物出场时从下方轻轻弹上来，只这一次；减弱动态效果时直接在位。
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
            Image(mascot.rawValue).resizable().scaledToFit().frame(height: 104)
                .scaleEffect(shown || reduceMotion ? 1 : 0.86, anchor: .bottom)
                .offset(y: shown || reduceMotion ? 0 : 8)
                .opacity(shown || reduceMotion ? 1 : 0)
                .accessibilityHidden(true)
            Text(title).font(Typography.emptyTitle).foregroundStyle(palette.ink).padding(.top, 12)
            if let message {
                Text(message).font(Typography.secondary).foregroundStyle(palette.ink2).padding(.top, 5)
            }
            action.padding(.top, 16)
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

/// 吉祥物的表情，对应 Assets 里的 mascot 图。
enum Mascot: String {
    case welcome = "mascot-welcome"
    case empty = "mascot-empty"
    case search = "mascot-search"
    case trash = "mascot-trash"
    case clean = "mascot-clean"
    case error = "mascot-error"
}

/// 项目页与未分类还没有灵感：任务存在时用轻量纸卡；完全空时用同一套组件的整页尺寸。
/// iOS 浮起随手记，Mac 聚焦底部输入栏；两端按钮、图标、按压与出现动效共用。
struct EmptyIdeas: View {
    var compact = false
    let write: () -> Void

    var body: some View {
        EmptyIdeaSurface(compact: compact, write: write)
    }
}

private struct EmptyIdeaSurface: View {
    let compact: Bool
    let write: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        Group {
            if compact { compactBody } else { fullBody }
        }
        .onAppear { withAnimation(Motion.pressUp) { shown = true } }
    }

    private var compactBody: some View {
        HStack(spacing: 12) {
            Image("mascot-empty")
                .resizable().scaledToFit()
                .frame(width: 40, height: 40)
                .padding(5)
                .background(palette.fill, in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("还没有灵感").font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink)
                Text("先记下一条，任务再慢慢拆").font(Typography.meta).foregroundStyle(palette.ink3)
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 68)
        .paper(radius: 18, lifted: true)
        .contentShape(.rect(cornerRadius: 18, style: .continuous))
        .scaleEffect(shown || reduceMotion ? 1 : 0.97)
        .opacity(shown || reduceMotion ? 1 : 0)
        .animation(Motion.pressUp, value: shown)
    }

    private var fullBody: some View {
        VStack(spacing: 0) {
            Image("mascot-empty")
                .resizable().scaledToFit()
                .frame(height: 104)
                .scaleEffect(shown || reduceMotion ? 1 : 0.86, anchor: .bottom)
                .offset(y: shown || reduceMotion ? 0 : 8)
                .opacity(shown || reduceMotion ? 1 : 0)
                .accessibilityHidden(true)
            Text("还没有灵感").font(Typography.emptyTitle).foregroundStyle(palette.ink).padding(.top, 12)
            Text("先记下一条，任务再慢慢拆").font(Typography.secondary).foregroundStyle(palette.ink2).padding(.top, 5)
            action.padding(.top, 16)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var action: some View {
        Button(action: write) {
            Label("记一条", systemImage: "square.and.pencil")
        }
        .buttonStyle(EmptyIdeaButtonStyle(compact: compact))
        .accessibilityLabel("记一条灵感")
    }
}

/// 空态唯一的动作按钮：紧凑空态是轻底小胶囊，整页空态是签名色主按钮；线宽、圆角和按压保持一致。
private struct EmptyIdeaButtonStyle: ButtonStyle {
    let compact: Bool
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(compact ? Typography.meta.weight(.medium) : Typography.secondary.weight(.semibold))
            .foregroundStyle(compact ? palette.signature : palette.onSignature)
            .padding(.horizontal, compact ? 10 : 16)
            .frame(height: compact ? 32 : 42)
            .background(compact ? palette.selection : palette.signatureFill, in: .capsule)
            .overlay {
                Capsule().strokeBorder(compact ? palette.signature.opacity(0.18) : .clear, lineWidth: 1)
            }
            .scaleEffect(pressed && !reduceMotion ? 0.95 : 1)
            .opacity(pressed && reduceMotion ? 0.86 : 1)
            .animation(pressed ? Motion.pressDown : Motion.pressUp, value: pressed)
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: pressed)
    }
}

/// 空库首次打开：Mac 与 iOS 同一段话；动作按钮由平台给（各自的主按钮样式）。
struct EmptyLibrary<Action: View>: View {
    @ViewBuilder let action: Action

    var body: some View {
        EmptyState(mascot: .welcome, title: "还没有项目", message: "建一个项目放灵感，或者先在下方随手记一条") { action }
    }
}
