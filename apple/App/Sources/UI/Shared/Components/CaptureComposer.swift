import CueStore
import SwiftUI

#if os(macOS)
struct CaptureState {
    var draft = ComposerDraft()
    var project: UUID?
}

/// 菜单栏面板最右的"交给 Cue"管的是这份草稿，所以挨着草稿，不占 Cue 那一行的宽。
struct CaptureComposer: View {
    @Binding var state: CaptureState
    let defaultProject: UUID?
    let pinnedOpen: Bool
    /// 草稿在这之前已清空。
    var saved: () -> Void = {}
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var saving = false
    @FocusState private var focused: Bool
    @Environment(\.panelCovered) private var covered

    private var project: UUID { state.project ?? defaultProject ?? Project.defaultID }
    private var destination: String { workspace.catalog?.project(project)?.shownName ?? "" }
    private var collapsed: Bool { !pinnedOpen && !focused && state.draft.isEmpty(accepting: .files) }

    var body: some View {
        Composer(
            draft: $state.draft, prompt: .verbatim(collapsed ? CaptureCopy.placeholder(to: destination) : CaptureCopy.prompt), label: "随手记",
            focus: $focused, accepts: .files, form: pinnedOpen ? .open : .line(opensOnFocus: true), shortcuts: [.send: save],
            header: { header }, tools: { EmptyView() }, send: { saveButton }
        )
        .onAppear { if pinnedOpen, !covered { focused = true } }
    }

    private var header: some View {
        HStack(spacing: Spacing.item) {
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
        .padding(.horizontal, Spacing.group).padding(.top, Spacing.item)
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
            .buttonStyle(ControlButtonStyle(kind: empty ? .secondary : .primary, size: .compact))
            .fixedSize()
            .disabled(empty)
            .help("把这次随手记直接说给 \(cue.name)")
    }

    private func handToCue() {
        workspace.speak(to: .cue, from: $state.draft, saying: Dotted(String(localized: "已交给 \(workspace.cue.name)"))) { $0.stored }
    }

    private var saveButton: some View {
        Button(action: save) { SendGlyph(.save(enabled: !saving)) }
            .buttonStyle(PressStyle(.button))
            .disabled(saving)
            .accessibilityLabel("记下")
            .help("记下（↩）")
    }

    private func save() {
        let project = project, taken = state.draft, claim = workspace.claimImports(taken)
        guard !taken.isEmpty(accepting: .files), !saving else { return }
        saving = true
        // 同发送：输入框当场清空，等待导入与保存期间新打的字留在输入框里；写不成放回去，新打的接在后面
        state.draft = ComposerDraft()
        workspace.attempt {
            defer { saving = false }
            let settled = await claim.settled()
            let note = CaptureDraft(text: settled.text, files: settled.files)
            guard !note.isEmpty else { return }
            do {
                try await note.save(in: project, workspace: workspace)
            } catch {
                state.draft = settled.followed(by: state.draft, keeping: ComposerDraft())
                throw error
            }
            saved()
        }
    }
}

#endif

struct DestinationChip<Icon: View>: View {
    var lead: String?
    let title: Text
    @ViewBuilder let icon: Icon
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.tight) {
            if let lead { Text(lead).foregroundStyle(palette.ink3) }
            icon
            title
        }
        .chip(menu: true)
    }
}

extension DestinationChip where Icon == ProjectGlyph {
    init(project: Project?) {
        self.init(lead: "→", title: Text(project?.shownName ?? "")) { ProjectGlyph(project: project, size: Self.glyph) }
    }

    private static var glyph: CGFloat {
        #if os(macOS)
        12
        #else
        13
        #endif
    }
}
