#if os(macOS)
import CueEditor
import CueStore
import CueText
import SwiftUI

extension CardEditing {
    /// 任务先写下没保存的字，再把库里此刻的正文交给 Agent；灵感没有这一下。
    func submit() {
        let workspace = workspace
        Task {
            do {
                guard let card = try await flushed(), card.isTask else { return }
                workspace.handOff(card)
            } catch {
                workspace.fail(error)
            }
        }
    }

    func field(_ card: Card, theme: CueEditorTheme, bottomInset: CGFloat = 0) -> some View {
        var editor = host(card, theme: theme)
        editor.bottomInset = bottomInset
        return editor.overlay { AttachmentSpotLayer(spot: handle.spot) }
    }

    func fittedField(_ card: Card, theme: CueEditorTheme) -> some View {
        FittedEditorHost(host: host(card, theme: theme)).overlay { AttachmentSpotLayer(spot: handle.spot) }
    }

    private func host(_ card: Card, theme: CueEditorTheme) -> EditorHost {
        let workspace = workspace
        return EditorHost(
            initialText: initialText, theme: theme, handle: handle,
            onChange: { [weak self] in self?.changed($0) },
            selectionActions: [.convertToTasks(from: card, workspace: workspace)],
            onSubmit: { [weak self] in self?.submit() },
            onError: workspace.fail)
    }
}

struct EditorBar: View {
    /// 变量胶囊的高度加上下留白，末行可完整滚到胶囊上方。
    static let clearance: CGFloat = 44 + Spacing.block * 2
    let card: Card
    let editing: CardEditing

    var body: some View {
        let names = CueVariables.names(in: editing.text)
        GlassEffectContainer(spacing: Spacing.item) {
            HStack(spacing: Spacing.item) {
                if !names.isEmpty { VariablesChip(card: card, names: names) }
                Spacer(minLength: 0)
            }
        }
    }
}

private struct VariablesChip: View {
    let card: Card
    let names: [String]
    @Environment(\.palette) private var palette
    @State private var editing = false

    var body: some View {
        Button { editing.toggle() } label: {
            HStack(spacing: Spacing.tight) {
                Text("{{\(names[0])}}").foregroundStyle(palette.ink)
                Text(card.variableValues[names[0]].flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "未填"))
                    .foregroundStyle(card.variableValues[names[0]]?.isEmpty == false ? palette.ink : palette.ink2)
                    .lineLimit(1)
                if names.count > 1 { Text("+\(names.count - 1)").foregroundStyle(palette.ink2) }
                Chevron(.expand).foregroundStyle(palette.ink2)
            }
            .font(Typography.secondary.weight(.medium))
            .padding(.horizontal, Spacing.inset).frame(height: 44)
            .frame(maxWidth: 260)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .glass(in: .capsule, interactive: true)
        .bubble(isPresented: $editing) { VariablesForm(card: card, names: names) { editing = false } }
        .help("变量取值")
        .accessibilityLabel("变量取值，共 \(names.count) 个")
    }
}

private struct VariablesForm: View {
    let card: Card
    let names: [String]
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var values: [String: String] = [:]

    var body: some View {
        Form {
            ForEach(names, id: \.self) { name in
                TextField("{{\(name)}}", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }), palette: palette)
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .onAppear { values = card.variableValues }
        .onDisappear { workspace.saveVariables(values, of: card) }
        .onSubmit(close) // ↩ 提交并关闭（关闭时保存），与 ⌘K 一致
    }
}

#endif
