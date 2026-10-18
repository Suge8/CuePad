#if os(macOS)
import CueEditor
import CueStore
import CueText
import SwiftUI

/// 一条灵感或任务正文此刻的编辑：编辑器的操作口、打字中的正文、自动保存与保存状态。整页编辑页（散放的灵感，整条正文）与
/// 任务浮窗的输入框（任务标题下面的话，`Card.rest`）共用这一份，各自只管怎么摆。编辑器是这段正文的唯一写者（见 `EditorHost`）；
/// 离开时 `leave` 写下没保存的字，什么都没写的灵感不留下（新记的一条先建一条空的再编辑）。
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

    init(_ card: Card, part: CardTextPart = .whole, workspace: Workspace) {
        cardID = card.id
        initialText = part.text(of: card)
        text = initialText
        self.workspace = workspace
        let store = workspace.services.store, id = card.id
        autosave = Autosave(
            save: { [weak self] text in
                self?.saveState = .saving
                try await store.updateCard(id) { part.write(text, into: &$0) }
                self?.saveState = .saved
            },
            onError: { [weak self] error in
                self?.saveState = .failed
                workspace.fail(error)
            })
    }

    /// "已保存"亮过一会儿之后回到平时。
    func settleSaved() { if saveState == .saved { saveState = .idle } }

    /// 编辑器里的 ⌘↩ 与浮窗的"开始"：任务先写下没保存的字，再把库里此刻的正文交给 Agent（`Workspace.handOff`）；灵感没有这一下。
    func submit() {
        let autosave = autosave, workspace = workspace, id = cardID
        Task {
            await autosave?.flush()
            do {
                guard let card = try await workspace.services.store.card(id), card.isTask else { return }
                workspace.handOff(card)
            } catch {
                workspace.fail(error)
            }
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
            selectionActions: [.convertToTasks(from: card, workspace: workspace)],
            onSubmit: { [weak self] in self?.submit() },
            onError: workspace.fail)
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
                Text(card.variableValues[names[0]].flatMap { $0.isEmpty ? nil : $0 } ?? "未填")
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
