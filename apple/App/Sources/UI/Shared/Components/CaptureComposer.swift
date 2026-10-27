import CueStore
import SwiftUI

#if os(macOS)
/// 随手记正在写的这一条：草稿与手动换过的落点（nil 时落在调用方给的落点）。
/// Mac 的底部输入栏与菜单栏面板各留一份。
struct CaptureState {
    var draft = ComposerDraft()
    var project: UUID?
}

/// 随手记（Mac 底部输入栏与菜单栏面板共用；手机上随手记在"对 Cue 说"里，见 `CueComposer`）：共用的 `Composer`，头部左上是落点菜单（先看去哪、再写），
/// 提交钮是"记下"（⌘↩，↩ 换行）。记下的是灵感，所以这里没有发送；记下后提示落点、点提示去那里。
/// 文案与存法见 `CaptureCopy`、`CaptureDraft`。两处只差：Mac 底部输入栏平时收成一行、占位带上落点（`pinnedOpen` 为 false），
/// 菜单栏面板的提示写在头部右边，最右是"交给 Cue"（这一条不记成灵感，直接说给 Cue；它管的是这份草稿，所以挨着草稿，不占 Cue 那一行的宽）。
struct CaptureComposer: View {
    @Binding var state: CaptureState
    /// 没手动换过落点时落在哪（主窗口是正在看的项目，菜单栏面板是上次打开的项目）；不在项目里时是默认项目。
    let defaultProject: UUID?
    /// 一直展开、出现即聚焦（菜单栏面板，形态 `.open`）；否则聚焦或有内容时才展开。
    let pinnedOpen: Bool
    /// 记下之后（iOS 收起输入框）；草稿在这之前已清空。
    var saved: () -> Void = {}
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var saving = false
    @FocusState private var focused: Bool
    @Environment(\.panelCovered) private var covered

    private var project: UUID { state.project ?? defaultProject ?? Project.defaultID }
    private var destination: String { workspace.catalog?.project(project)?.shownName ?? "" }
    /// 收成一行（`Composer` 同一条规则）：没有头部的落点胶囊，占位要带上落点。
    private var collapsed: Bool { !pinnedOpen && !focused && state.draft.isEmpty(accepting: .files) }

    var body: some View {
        Composer(
            draft: $state.draft, prompt: .verbatim(collapsed ? CaptureCopy.placeholder(to: destination) : CaptureCopy.prompt), label: "随手记",
            focus: $focused, accepts: .files, form: pinnedOpen ? .open : .line(opensOnFocus: true), shortcuts: [.send: save],
            header: { header }, tools: { EmptyView() }, send: { saveButton }
        )
        // 一直展开的出现的同一刻聚焦
        .onAppear { if pinnedOpen, !covered { focused = true } }
    }

    private var header: some View {
        HStack(spacing: 8) {
            destinationMenu
            Spacer(minLength: 8)
            if pinnedOpen, let notice = workspace.notice {
                Text(notice.text).font(Typography.meta)
                    .foregroundStyle(notice.isError ? palette.failure : palette.ink3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if pinnedOpen { handOffButton }
        }
        .animation(Motion.fade, value: workspace.notice)
        .padding(.horizontal, 12).padding(.top, 10)
    }

    private var destinationMenu: some View {
        MenuButton(sections: [
            ChoiceMenu.Section(choices: (workspace.catalog?.projects ?? []).map { item in
                ChoiceMenu.Choice(title: .verbatim(item.shownName), checked: item.id == project) { state.project = item.id }
            }),
        ], accessibilityLabel: "记到 \(destination)") {
            DestinationChip(project: workspace.catalog?.project(project))
        }
    }

    private var handOffButton: some View {
        let cue = workspace.cue
        let empty = state.draft.isEmpty(accepting: .files) || !cue.canHear
        return Button("交给 \(cue.name)", icon: .handOff, action: handToCue)
            .font(Typography.meta.weight(.semibold))
            .buttonStyle(ControlButtonStyle(kind: empty ? .secondary : .primary, compact: true))
            .fixedSize()
            .disabled(empty)
            .help("把这次随手记直接说给 \(cue.name)")
    }

    /// 这次随手记不记成灵感，直接作为一句话说给 Cue。
    private func handToCue() {
        workspace.speak(to: .cue, from: $state.draft, saying: Dotted(String(localized: "已交给 \(workspace.cue.name)"))) { $0.stored }
    }

    private var saveButton: some View {
        Button(action: save) { SendGlyph(.save(enabled: !saving)) }
            .buttonStyle(PressStyle(.button))
            .disabled(saving)
            .accessibilityLabel("记下")
            .help("记下（⌘↩）")
    }

    private func save() {
        let note = CaptureDraft(text: state.draft.text, files: state.draft.files), project = project
        guard !note.isEmpty, !saving else { return }
        saving = true
        workspace.attempt {
            defer { saving = false }
            try await note.save(in: project, workspace: workspace)
            state.draft = ComposerDraft()
            saved()
        }
    }
}

#endif

/// 头部的落点胶囊："[前缀] 图标 名字 ⌃⌄"，点开换去处。随手记与 iOS 进展页的快速添加写"→ 项目图标 项目名"（init(project:)），
/// 新会话与发给 Agent 的输入框用同一个胶囊写"新会话 · 项目名""交给 会话名"。
struct DestinationChip<Icon: View>: View {
    var lead: String?
    let title: Text
    @ViewBuilder let icon: Icon
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: ChipMetrics.spacing) {
            if let lead { Text(lead).foregroundStyle(palette.ink3) }
            icon
            title.foregroundStyle(palette.ink).lineLimit(1)
            Image(.choose).font(ChipMetrics.chevron).foregroundStyle(palette.ink3).accessibilityHidden(true)
        }
        .font(ChipMetrics.font)
        .padding(.horizontal, ChipMetrics.inset).frame(height: ChipMetrics.height)
        .background(palette.fill, in: .capsule)
        .contentShape(.capsule)
    }
}

/// 胶囊的尺寸（泛型类型里放不了静态存储属性）。
private enum ChipMetrics {
    #if os(macOS)
    static let spacing: CGFloat = 5, glyph: CGFloat = 12, inset: CGFloat = 8, height: CGFloat = 24
    static let font = Typography.meta
    static let chevron = Glyph.mark
    #else
    static let spacing: CGFloat = 6, glyph: CGFloat = 13, inset: CGFloat = 12, height: CGFloat = 32
    static let font = Font.subheadline.weight(.medium)
    static let chevron = Font.caption2
    #endif
}

extension DestinationChip where Icon == ProjectGlyph {
    init(project: Project?) {
        self.init(lead: "→", title: Text(project?.shownName ?? "")) { ProjectGlyph(project: project, size: ChipMetrics.glyph) }
    }
}
