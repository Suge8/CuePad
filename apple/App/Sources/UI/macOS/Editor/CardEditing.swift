#if os(macOS)
import CueEditor
import CueStore
import CueText
import SwiftUI

/// 一条灵感或任务草稿此刻的编辑：编辑器的操作口、打字中的正文、自动保存与保存状态。整页编辑页（散放的灵感）与
/// 任务浮窗的输入框（草稿）共用这一份，各自只管怎么摆。编辑器是这条正文的唯一写者（见 `EditorHost`）；离开时 `leave` 写下没保存的字，
/// 什么都没写的不留下（新记的一条、新写的提示词都是先建一条空的再编辑）。
@Observable
final class CardEditing {
    let cardID: UUID
    /// 打开那一刻的正文：编辑器只在创建时载入一次。
    let initialText: String
    @ObservationIgnored let handle = EditorHandle()
    /// 打字中的正文（底栏据此认出变量）。
    private(set) var text: String
    private(set) var saveState = SaveState.idle
    @ObservationIgnored private let workspace: Workspace
    @ObservationIgnored private var autosave: Autosave?

    init(_ card: Card, workspace: Workspace) {
        cardID = card.id
        initialText = card.body
        text = card.body
        self.workspace = workspace
        let store = workspace.services.store, id = card.id
        autosave = Autosave(
            save: { [weak self] body in
                self?.saveState = .saving
                do {
                    try await store.updateCard(id) { $0.body = body }
                } catch CueStoreError.notFound {
                    // 提示词送达就从库里删掉了（用掉了）：发出之后再打的字没有地方可写，也不算出错
                    self?.saveState = .idle
                    return
                }
                self?.saveState = .saved
            },
            onError: { [weak self] error in
                self?.saveState = .failed
                workspace.fail(error)
            })
    }

    /// "已保存"亮过一会儿之后回到平时。
    func settleSaved() { if saveState == .saved { saveState = .idle } }

    /// 主动作（底栏的主钮与编辑器里的 ⌘↩ 同一个）：任务的草稿交给 Agent（`Workspace.handOff`），散放的灵感挂到任务。交出去之前先写下没保存的字：
    /// 草稿送达就用掉了，之后再写就没有地方了。
    func submit(_ card: Card) {
        guard CardMenu.handsToAgent(card) else { return workspace.attaching = card }
        let autosave = autosave, workspace = workspace
        Task {
            await autosave?.flush()
            workspace.handOff(card)
        }
    }

    /// 离开编辑：写下没保存的字，空白的不留下。
    func leave() { workspace.leaveEditing(cardID, flush: autosave) }

    /// 这张卡的编辑器：正文变化交给自动保存，右键有选区动作，⌘↩ 是主动作。
    func field(_ card: Card, theme: CueEditorTheme) -> EditorHost {
        let workspace = workspace
        return EditorHost(
            initialText: initialText, theme: theme, handle: handle,
            onChange: { [weak self] next in
                self?.text = next
                self?.autosave?.changed(next)
            },
            selectionActions: Self.selectionActions(card, workspace: workspace),
            onSubmit: { [weak self] in self?.submit(card) },
            onError: workspace.fail)
    }

    /// 右键菜单里的选区动作：转为任务。
    private static func selectionActions(_ card: Card, workspace: Workspace) -> [CueSelectionAction] {
        [CueSelectionAction(title: "转为任务", systemImage: "checklist") { stored in workspace.convertToTasks(stored, in: card.projectID) }]
    }
}

/// 保存状态那几个字（编辑页的元信息行、浮窗里展开的提示词上）：保存中、"已保存"亮一会儿、没能保存一直亮着。
struct SaveStatus: View {
    let editing: CardEditing
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if let text = editing.saveState.text {
                Text(text).foregroundStyle(editing.saveState == .failed ? palette.failure : palette.ink3).transition(.opacity)
            }
        }
        .animation(Motion.quick, value: editing.saveState)
        // "已保存"只亮一会儿；状态再变（又在保存、出错）时这次计时作废
        .task(id: editing.saveState) {
            guard editing.saveState == .saved else { return }
            try? await Task.sleep(for: SaveState.savedDisplay)
            if !Task.isCancelled { editing.settleSaved() }
        }
    }
}

/// 保存状态：平时不显示；保存中显示，保存完显示"已保存"一会儿，失败一直显示直到下次保存成功。
enum SaveState: Equatable {
    case idle, saving, saved, failed

    static let savedDisplay: Duration = .seconds(1.5)

    var text: String? {
        switch self {
        case .idle: nil
        case .saving: "保存中…"
        case .saved: "已保存"
        case .failed: "没能保存"
        }
    }
}

/// 散放灵感的编辑页底栏：左边是变量（有才出现），右边是主动作"挂到任务"（⌘↩ 由编辑器自己接，同 `CardEditing.submit`）。
/// 分割线与转为任务在编辑器的右键菜单里。提示词不在这里写：它是任务的草稿，在任务浮窗里（`TaskSheet`）。
struct EditorBar: View {
    let card: Card
    let editing: CardEditing
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let names = CueVariables.names(in: editing.text)
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                if !names.isEmpty { VariablesChip(card: card, names: names) }
                Spacer(minLength: 0)
                Button { workspace.attaching = card } label: {
                    Label(CardMenu.Item.attachToTask.title, systemImage: CardMenu.Item.attachToTask.symbol)
                        .font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.onSignature)
                        .padding(.horizontal, 16).frame(height: 44)
                        .background(palette.signatureFill, in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(PressStyle())
                .help("挂到一个任务下，成为它要发给 Agent 的话（⌘↩）")
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
                Text("{{\(names[0])}}").foregroundStyle(palette.variable)
                Text(card.variableValues[names[0]].flatMap { $0.isEmpty ? nil : $0 } ?? "未填")
                    .foregroundStyle(card.variableValues[names[0]]?.isEmpty == false ? .primary : .secondary)
                    .lineLimit(1)
                if names.count > 1 { Text("+\(names.count - 1)").foregroundStyle(.secondary) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).accessibilityHidden(true)
            }
            .font(Typography.secondary.weight(.medium))
            .padding(.horizontal, 14).frame(height: 44)
            .frame(maxWidth: 260)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle(scale: 0.97))
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
    @State private var values: [String: String] = [:]

    var body: some View {
        Form {
            ForEach(names, id: \.self) { name in
                TextField("{{\(name)}}", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 320)
        .onAppear { values = card.variableValues }
        .onDisappear(perform: save)
        .onSubmit(close) // ↩ 提交并关闭（关闭时保存），与 ⌘K 一致
    }

    private func save() {
        let id = card.id, values = values
        guard values != card.variableValues else { return }
        workspace.perform { try await $0.updateCard(id) { $0.variableValues = values } }
    }
}

#endif
