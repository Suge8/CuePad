import SwiftUI

/// 宽屏主区的栏头（Mac 主窗口与 iPad 宽窗同一个）：左边写这一页是什么，右边是这一页的操作（`PageMenuSlot`）。会话页的栏头在会话页里（`WideSessionTitle`）。
struct WideColumnHead: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        let overlaid = workspace.overlay != nil
        HStack(spacing: 0) {
            if overlaid {
                CloseButton()
                #if os(macOS)
                OverlayTitle()
                #endif
            } else if workspace.mainRoute == .progress {
                PageMenuSlot(leads: true)
            } else {
                title
            }
            Spacer(minLength: Spacing.item)
            #if os(macOS)
            // 看板那一排是列头，不给提醒常驻一格（列头少让一截）；要关注时才露
            if workspace.mainRoute != .progress || SyncAlertSlot.needed(services) { SyncAlertSlot() }
            #endif
            if !overlaid, workspace.mainRoute == .shelf {
                NewProjectButton()
                    .labelStyle(.iconOnly)
                    .buttonStyle(ControlButtonStyle(kind: .circular))
                    .padding(.leading, Spacing.item)
            }
            #if os(macOS)
            if workspace.openCard != nil {
                CardMenuSlot()
            } else if overlaid || workspace.mainRoute != .progress {
                PageMenuSlot()
            }
            #else
            // 盖着的页（编辑、文件）的标题与操作在它自己那一排（`HeaderHost.panel`）
            if !overlaid, workspace.mainRoute != .progress { PageMenuSlot() }
            #endif
        }
    }

    @ViewBuilder private var title: some View {
        switch workspace.mainRoute {
        case .project: WideProjectHeading()
        case .shelf: WideHeading(title: String(localized: "项目"))
        case .archive: WideHeading(title: String(localized: "归档"))
        case .trash: WideHeading(title: String(localized: "回收站"))
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

struct NewProjectButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("新建项目", icon: .newProject) { workspace.projectForm = .init() }
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
