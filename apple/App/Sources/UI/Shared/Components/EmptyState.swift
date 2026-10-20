import SwiftUI

/// 空态与出错页：吉祥物、一句现状、一句下一步、一个可选动作。全 App 共用这一套布局。
/// 整页尺寸的那张纸与所在页面的内容同宽（左右边线与标题、其他纸对齐，中轴就是页面的中轴），纸里的字居中、最宽 420。
/// 吉祥物出场时从下方轻轻弹上来，只这一次；减弱动态效果时只淡入、不挪。
/// "这里还没有"类的空态（`waitsForSync`）在本机正在和 iCloud 对时（`AppServices.isCatchingUp`）不先说空：对得快就等对完再出，
/// 久过 `Pending.delay` 换成"正在从 iCloud 同步"——新装的设备上东西一页页地到，说"还没有"是错的。
struct EmptyState<Action: View>: View {
    let mascot: Mascot
    let title: String
    var message: String?
    var compact = false
    var waitsForSync = false
    @ViewBuilder var action: Action
    @Environment(AppServices.self) private var services: AppServices?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var shown = false
    @State private var syncing = false

    private var catchingUp: Bool { waitsForSync && services?.isCatchingUp == true }

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
                    if !syncing { action }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(spacing: 16) {
                    illustration
                    copy
                    if !syncing { action }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
        }
        .paper(radius: compact ? 18 : 24)
        .scaleEffect(shown || reduceMotion ? 1 : 0.97)
        .opacity(shown ? 1 : 0)
        .buttonStyle(ControlButtonStyle(kind: .primary))
        .onAppear { if !catchingUp { appear() } }
        .onChange(of: catchingUp) { if !catchingUp { appear() } }
        .pending(catchingUp, shown: $syncing)
        .onChange(of: syncing) { if syncing { appear() } }
    }

    private func appear() {
        guard !shown else { return }
        withAnimation(reduceMotion ? Motion.quick : Motion.snappy) { shown = true }
    }

    private var illustration: some View {
        Image(syncing ? Mascot.search.rawValue : mascot.rawValue).resizable().scaledToFit()
            .frame(width: compact ? 48 : 104, height: compact ? 48 : 104)
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: compact ? .leading : .center, spacing: compact ? 4 : 6) {
            HStack(spacing: 6) {
                if syncing { Spinner(.small) }
                Text(syncing ? "正在从 iCloud 同步" : title)
            }
            .font(compact ? Typography.secondary.weight(.medium) : Typography.emptyTitle)
            .foregroundStyle(palette.ink)
            if let message = syncing ? "别的设备上的内容到了就会出现在这里" : message {
                Text(message).font(compact ? Typography.meta : Typography.secondary)
                    .foregroundStyle(palette.ink2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension EmptyState where Action == EmptyView {
    init(mascot: Mascot, title: String, message: String? = nil, waitsForSync: Bool = false) {
        self.init(mascot: mascot, title: title, message: message, waitsForSync: waitsForSync) { EmptyView() }
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
    let icon: Icon?
    var kind = Kind.primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let icon {
                Label(title, icon: icon)
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

/// 项目页还没有灵感：任务存在时用轻量纸卡；完全空时复用 EmptyState 的整页布局。
/// iOS 新建一条并打开它的纸页，Mac 聚焦底部输入栏；两端按钮、图标、按压与出现动效共用。
struct EmptyIdeas: View {
    var compact = false
    let write: () -> Void

    var body: some View {
        EmptyState(mascot: .empty, title: "还没有灵感", message: "随时记下新的想法", compact: compact, waitsForSync: true) {
            EmptyStateButton(title: "记一条", icon: .write, kind: compact ? .small : .primary, action: write)
                .accessibilityLabel("记一条灵感")
        }
    }
}

