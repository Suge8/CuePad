#if os(macOS)
import CueStore
import SwiftUI

/// 技能与说明里打开的一样，盖在当前页上（同灵感的编辑页：铺满内容区、与页面同底色，开合原地淡入淡出，左上"收起"、Esc 关）。
/// 打开时先在看不见时挂好（编辑器要接过键盘），下一帧再淡入：淡入的每一帧只剩改透明度。
struct LibraryItemLayer: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            if workspace.isLibraryReady, let item = workspace.openLibraryItem {
                LibraryItemPage(item: item).id(item).transition(.opacity)
            }
        }
        .animation(HandOff.quick, value: workspace.openLibraryItem)
    }
}

private struct LibraryItemPage: View {
    let item: LibraryItem
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch item {
            case .instruction(let kind): InstructionEditorPage(kind: kind)
            case .compare(let id):
                CompareView(tidyID: id) { workspace.openLibraryItem = nil }
                    .padding(.horizontal, Spacing.page).padding(.bottom, 20)
                    .safeAreaPadding(.top, Bars.contentGap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk.ignoresSafeArea())
    }
}

/// 一份说明的编辑页（Mac）：同灵感的编辑页，字在一列里居中，自动存、没有保存钮（`InstructionDraft`）。页顶一行写它是哪一份、文件在哪、存好没有；
/// 文件在别处被改了（终端里、别的编辑器、手机发来的）当场跟上，你改着没存上的留着、写出文件变了，给"换成文件里的"。
/// 快照里没有这一份了（项目解绑了文件夹）就收起。
private struct InstructionEditorPage: View {
    let kind: LibraryInstruction.Kind
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var draft: InstructionDraft?

    private static let textWidth: CGFloat = 680
    private static let inset: CGFloat = 24

    var body: some View {
        let instruction = workspace.library?.instruction(kind)
        VStack(spacing: 10) {
            if let instruction, let draft {
                meta(instruction, draft).frame(maxWidth: Self.textWidth, alignment: .leading).padding(.horizontal, Self.inset)
                EditorHost(
                    initialText: draft.text, theme: .editor(palette, horizontalInset: Self.inset, maxTextWidth: Self.textWidth), handle: draft.handle,
                    onChange: { draft.changed($0) })
            }
        }
        .padding(.top, Spacing.pageTop)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: instruction?.kind, initial: true) {
            guard workspace.library != nil else { return }
            guard let instruction else { workspace.openLibraryItem = nil; return }
            if draft == nil { draft = InstructionDraft(instruction, workspace: workspace) }
        }
        .onChange(of: instruction?.text) { draft?.follow(instruction?.text) }
        .task(id: draft != nil) {
            await NextFrame.wait()
            draft?.handle.focus()
        }
        .onDisappear { if let draft { Task { await draft.leave() } } }
    }

    /// 页顶一行：图标、名字、文件在哪、存好没有（或文件变了与"换成文件里的"）。
    private func meta(_ instruction: LibraryInstruction, _ draft: InstructionDraft) -> some View {
        HStack(spacing: 8) {
            Image(.instruction).imageScale(.small)
            Text(verbatim: workspace.instructionName(kind)).foregroundStyle(palette.ink)
            Dotted.inline
            Text(verbatim: workspace.library?.shown(instruction.path) ?? instruction.path).lineLimit(1).truncationMode(.middle)
            DraftStatus(draft: draft)
        }
        .font(Typography.meta)
        .foregroundStyle(palette.ink3)
    }
}

/// 存好没有：存的时候"保存中…"，存好"已保存"亮一会儿；在别处改过且已跟上写"在别处改过，已跟上"；你改着而文件变了写出来、给"换成文件里的"。
struct DraftStatus: View {
    let draft: InstructionDraft
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            switch draft.state {
            case .idle: EmptyView()
            case .saving: Text(SaveState.saving.text ?? "")
            case .saved: Text(SaveState.saved.text ?? "")
            case .followed: Text("在别处改过，已跟上").foregroundStyle(palette.ink2)
            case .failed: Text(SaveState.failed.text ?? "").foregroundStyle(palette.failure)
            case .conflict(let file):
                HStack(spacing: 8) {
                    Text("文件在别处改过了").foregroundStyle(palette.ink)
                    if file != nil {
                        Button("换成文件里的") { draft.takeFile() }.buttonStyle(PressStyle(.inline)).foregroundStyle(palette.ink)
                    }
                }
            }
        }
        .transition(.opacity)
        .animation(HandOff.quick, value: draft.state)
        .task(id: draft.state) {
            guard draft.state == .saved || draft.state == .followed else { return }
            try? await Task.sleep(for: SaveState.savedDisplay * 2)
            if !Task.isCancelled { draft.settle() }
        }
    }
}
#endif
