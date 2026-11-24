import CueStore
import SwiftUI

#if os(macOS)
struct CaptureState {
    var draft = ComposerDraft()
    var project: UUID?
}

struct CaptureComposer: View {
    @Binding var state: CaptureState
    let defaultProject: UUID?
    var saved: () -> Void = {}
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var saving = false
    @FocusState private var focused: Bool
    @Environment(\.panelCovered) private var covered

    private var project: UUID { state.project ?? defaultProject ?? Project.defaultID }

    var body: some View {
        Composer(
            draft: $state.draft, prompt: .verbatim(CaptureCopy.prompt), label: "随手记",
            focus: $focused, accepts: .files, form: .open, submit: save,
            header: { header }, tools: { EmptyView() }, send: { saveButton }
        )
        .onAppear { if !covered { focused = true } }
    }

    private var header: some View {
        HStack(spacing: Spacing.item) {
            DestinationMenu(project: project) { state.project = $0 }
            Spacer(minLength: 8)
            if let notice = workspace.notice {
                Text(notice.text).font(Typography.meta)
                    .foregroundStyle(notice.isError ? palette.failure : palette.ink3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            handOffButton
        }
        .animation(Motion.fade, value: workspace.notice)
        .padding(.horizontal, Spacing.group).padding(.top, Spacing.item)
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

struct DestinationMenu: View {
    let project: UUID
    var lead = Text(verbatim: "→")
    let choose: (UUID) -> Void
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = workspace.catalog?.project(project)
        MenuButton(sections: [
            ChoiceMenu.Section(choices: (workspace.catalog?.projects ?? []).map { item in
                ChoiceMenu.Choice(title: .verbatim(item.shownName), checked: item.id == project) { choose(item.id) }
            }),
        ], accessibilityLabel: "记到 \(current?.shownName ?? "")") {
            DestinationChip(project: current, lead: lead)
        }
    }
}

struct DestinationChip<Icon: View>: View {
    var lead: Text?
    let title: Text
    @ViewBuilder let icon: Icon
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.tight) {
            if let lead { lead.foregroundStyle(palette.ink3) }
            icon
            title
        }
        .chip(menu: true)
    }
}

extension DestinationChip where Icon == ProjectGlyph {
    init(project: Project?, lead: Text? = nil) {
        self.init(lead: lead, title: Text(project?.shownName ?? "")) { ProjectGlyph(project: project, size: Self.glyph) }
    }

    private static var glyph: CGFloat {
        #if os(macOS)
        12
        #else
        13
        #endif
    }
}
