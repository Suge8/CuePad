import SwiftUI

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
            if workspace.mainRoute != .progress || SyncAlertSlot.needed(services) { SyncAlertSlot() }
            #endif
            #if os(macOS)
            if let card = workspace.openCard {
                ChatAlongsideButton(cardID: card)
                CardMenuSlot()
            }
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
        default: EmptyView()
        }
    }
}

private struct CloseButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button { workspace.overlay = nil } label: { Image(.back).font(Glyph.control.weight(.bold)) }
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .keyboardShortcut(.cancelAction)
            .help("收起（Esc）")
            .accessibilityLabel("收起")
            .padding(.trailing, Spacing.item)
    }
}

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
