#if os(iOS)
import CueStore
import SwiftUI

/// 技能与说明里打开的一样，推在那一页上：说明的纸页（`InstructionScreen`）或比一比（`CompareView`）。
struct LibraryItemScreen: View {
    let item: LibraryItem
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        switch item {
        case .instruction(let kind): InstructionScreen(kind: kind)
        case .compare(let id):
            CompareView(tidyID: id) { dismiss() }
                .padding(.bottom, 12)
                .safeAreaPadding(.top, FloatingHeaderLayout.height + 8)
                .floatingHeader("比一比", detail: Dotted(workspace.library?.tidies.first { $0.id == id }?.title ?? ""))
        }
    }
}

/// 一份说明的纸页（手机）：改动攒在这里，顶栏右边的纸飞机"发往 Mac"（有改动才亮），那台写进文件、快照同步回来（`InstructionDraft`）。
/// 顶栏第二行写文件名、发着没有；Mac 上又改过而你没改的当场跟上，你改着的留着、写出 Mac 上改过了，由你选换成 Mac 上的或留你的。
/// 不点纸飞机就不发：退出这一页时没发的留在 `Workspace.instructionDraft`，回来接着改。
private struct InstructionScreen: View {
    let kind: LibraryInstruction.Kind
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss
    @State private var draft: InstructionDraft?

    var body: some View {
        let instruction = workspace.library?.instruction(kind)
        VStack(spacing: 0) {
            if let draft {
                if case .conflict(let file) = draft.state { conflict(draft, file: file) }
                IOSEditorHost(initialText: draft.text, theme: .editor(palette, horizontalInset: 20), handle: draft.handle,
                              onChange: { draft.changed($0) }, onError: workspace.fail)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.paper.ignoresSafeArea())
        .floatingHeader(.verbatim(workspace.instructionName(kind)), detail: detail(instruction)) { send }
        .onChange(of: instruction?.kind, initial: true) {
            guard workspace.library != nil else { return }
            guard let instruction else { dismiss(); return }
            if draft == nil { draft = workspace.instructionDraft(instruction) }
        }
        .onChange(of: instruction?.text) { draft?.follow(instruction?.text) }
    }

    /// 顶栏第二行：文件名、发着没有。
    private func detail(_ instruction: LibraryInstruction?) -> Dotted {
        let name = instruction.map { ($0.path as NSString).lastPathComponent } ?? ""
        let state: String? = switch draft?.state {
        case .saving: String(localized: "正在发往 Mac…")
        case .saved: String(localized: "Mac 上已写好")
        case .followed: String(localized: "Mac 上改过，已跟上")
        case .failed: String(localized: "没发出去")
        default: draft?.dirty == true ? String(localized: "有改动没发") : nil
        }
        return Dotted(name, state)
    }

    private var send: some View {
        Button("发往 Mac", icon: .send) { if let draft { Task { await draft.send() } } }
            .disabled(!(draft?.dirty ?? false) || draft?.state == .saving || draft?.conflicted == true)
            .task(id: draft?.state) {
                guard let draft, draft.state == .saved || draft.state == .followed else { return }
                try? await Task.sleep(for: SaveState.savedDisplay * 2)
                if !Task.isCancelled { draft.settle() }
            }
    }

    /// Mac 上改过、你也改着：一条纸上的横条写出来，给"换成 Mac 上的"（丢下你的）与"留我的"（以 Mac 上此刻的为基准发过去盖过它）。
    private func conflict(_ draft: InstructionDraft, file: String?) -> some View {
        HStack(spacing: 10) {
            Text("Mac 上改过了，你改的还没发").font(.footnote).foregroundStyle(palette.ink)
            Spacer(minLength: 8)
            if file != nil {
                Button("换成 Mac 上的") { draft.takeFile() }.font(.footnote.weight(.medium)).foregroundStyle(palette.ink)
                Button("留我的") { Task { await draft.keepMine() } }.font(.footnote.weight(.medium)).foregroundStyle(palette.ink)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(palette.bubble)
        .padding(.top, FloatingHeaderLayout.height + 8)
    }
}
#endif
