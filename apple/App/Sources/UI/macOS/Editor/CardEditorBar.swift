#if os(macOS)
import CueEditor
import CueStore
import CueText
import SwiftUI

extension CardEditing {
    /// 编辑器里的 ⌘↩：任务先写下没保存的字，再把库里此刻的正文交给 Agent（`Workspace.handOff`）；灵感没有这一下。
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

    /// 这张卡的编辑器：正文变化交给自动保存，右键有选区动作，⌘↩ 是主动作。
    func field(_ card: Card, theme: CueEditorTheme) -> EditorHost {
        let workspace = workspace
        return EditorHost(
            initialText: initialText, theme: theme, handle: handle,
            onChange: { [weak self] in self?.changed($0) },
            selectionActions: [.convertToTasks(from: card, workspace: workspace)],
            onSubmit: { [weak self] in self?.submit() },
            onError: workspace.fail)
    }

    /// 高贴着字、不自己滚的那一种（任务气泡）。
    func fittedField(_ card: Card, theme: CueEditorTheme) -> FittedEditorHost {
        FittedEditorHost(host: field(card, theme: theme))
    }
}

/// 保存状态那几个字（编辑页的元信息行）：保存中、"已保存"亮一会儿、没能保存一直亮着。
struct SaveStatus: View {
    let editing: CardEditing
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let text = editing.saveState.text {
                Text(text).foregroundStyle(editing.saveState == .failed ? palette.failure : palette.ink3).transition(.opacity)
            }
        }
        .animation(Motion.fade, value: editing.saveState)
        // "已保存"只亮一会儿；状态再变（又在保存、出错）时这次计时作废
        .task(id: editing.saveState) {
            guard editing.saveState == .saved else { return }
            try? await Task.sleep(for: SaveState.savedDisplay)
            if !Task.isCancelled { editing.settleSaved() }
        }
    }
}

/// 散放灵感的编辑页底栏：变量（有才出现）。转为任务在编辑器的右键菜单里。
struct EditorBar: View {
    let card: Card
    let editing: CardEditing

    var body: some View {
        let names = CueVariables.names(in: editing.text)
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if !names.isEmpty { VariablesChip(card: card, names: names) }
                Spacer(minLength: 0)
            }
        }
    }
}

/// 变量取值：显示第一个变量与其值，点开逐个填写；取值存在卡片上。
private struct VariablesChip: View {
    let card: Card
    let names: [String]
    @Environment(\.palette) private var palette
    @State private var editing = false

    var body: some View {
        Button { editing.toggle() } label: {
            HStack(spacing: 6) {
                Text("{{\(names[0])}}").foregroundStyle(palette.ink)
                Text(card.variableValues[names[0]].flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "未填"))
                    .foregroundStyle(card.variableValues[names[0]]?.isEmpty == false ? palette.ink : palette.ink2)
                    .lineLimit(1)
                if names.count > 1 { Text("+\(names.count - 1)").foregroundStyle(palette.ink2) }
                Image(.expand).font(.system(size: 9, weight: .bold)).foregroundStyle(palette.ink2).accessibilityHidden(true)
            }
            .font(Typography.secondary.weight(.medium))
            .padding(.horizontal, 14).frame(height: 44)
            .frame(maxWidth: 260)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .glass(in: .capsule, interactive: true)
        .popover(isPresented: $editing, arrowEdge: .top) { VariablesForm(card: card, names: names) { editing = false } }
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
