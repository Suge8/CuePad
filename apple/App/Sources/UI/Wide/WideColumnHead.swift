import SwiftUI

/// 宽屏主区的栏头（Mac 主窗口与 iPad 宽窗同一个）：左边写这一页是什么，这一页自己的钮挨着它或在右端（`PageMenu.swift`）。会话页的栏头在会话页里（`WideSessionTitle`）。
struct WideColumnHead: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let overlaid = workspace.overlay != nil
        HStack(spacing: 0) {
            if overlaid {
                CloseButton()
            } else if workspace.mainRoute == .progress {
                ProjectScopeSlot()
            } else {
                title
            }
            Spacer(minLength: Spacing.item)
            #if os(macOS)
            // 看板那一排是列头，不给提醒常驻一格（列头少让一截）；要关注时才露
            if workspace.mainRoute != .progress || SyncAlertSlot.needed(services) { SyncAlertSlot() }
            #endif
            #if os(macOS)
            // iPad 上盖着的页（编辑、文件）的标题与操作在它自己那一排（`HeaderHost.panel`）
            if workspace.openCard != nil { CardMenuSlot() }
            #endif
        }
    }

    @ViewBuilder private var title: some View {
        switch workspace.mainRoute {
        case .project: WideProjectHeading()
        case .shelf: WideShelfHeading()
        case .archive: WidePlaceHeading(title: String(localized: "归档")) {}
        case .trash: WidePlaceHeading(title: String(localized: "回收站")) { EmptyTrashButton() }
        case .library: LibraryPanesSlot()
        case .settings: WideHeading(title: String(localized: "设置"))
        case .conflicts: WideHeading(title: String(localized: "两个版本"))
        case .earlier: WideHeading(title: String(localized: "历史"))
        default: EmptyView()
        }
    }
}

private struct CloseButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        // 箭头比放大镜、"⋯"细瘦：大一号、粗一档，与它们一样重
        Button { workspace.overlay = nil } label: { Image(.back).font(Glyph.control.weight(.bold)) }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .keyboardShortcut(.cancelAction)
            .help("收起（Esc）")
            .accessibilityLabel("收起")
            .padding(.trailing, Spacing.item)
    }
}

/// 项目列表页的栏头：标题后面紧跟着这一页的三颗图标钮（新建、归档、回收站），同项目页栏头里项目名后面那两颗（`WideProjectHeading`）一个样子、一个位置。
/// 归档与回收站原先是卡片上面单独一行带字的入口，新建在栏头最右端：三样分在两处，那一行又把卡片往下顶。
private struct WideShelfHeading: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: Spacing.item) {
            WideHeading(title: String(localized: "项目"))
            HStack(spacing: 0) {
                NewProjectButton()
                Button("归档", icon: .archive) { workspace.show(.archive) }.help("归档")
                Button("回收站", icon: .trash) { workspace.show(.trash) }.help("回收站")
            }
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .buttonStyle(ControlButtonStyle(kind: .icon))
        }
    }
}

struct NewProjectButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("新建项目", icon: .add) { workspace.projectForm = .init() }
            .help("新建项目")
    }
}

private struct LibraryPanesSlot: View {
    var body: some View {
        LibraryPanes()
            .frame(height: PaneMetrics.square)
            .padding(PaneMetrics.inset)
            .glass(in: .capsule)
            .fixedSize()
    }
}
