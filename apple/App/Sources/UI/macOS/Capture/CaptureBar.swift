#if os(macOS)
import CueText
import SwiftUI

/// 主窗口底部浮着的随手记：平时一行，占位写明落到哪；聚焦或有内容时展开（左上落点、图片）。
struct CaptureBar: View {
    let project: UUID?

    private static let width: CGFloat = 620

    var body: some View {
        CaptureComposer(defaultProject: project, pinnedOpen: false)
            // 浮在卡片墙上：背后的字不透到输入框里
            .environment(\.composerInk, .solid)
            .frame(maxWidth: Self.width)
            .padding(.horizontal, 24)
    }
}

/// Mac 的随手记（底部输入栏与菜单栏面板共用）：共用的 `Composer`，头部是落点，提交钮是"记下"；结构与文案同手机（`CaptureCopy`、`CaptureDraft`）。
/// ⌘↩ 记成灵感（同回复框，↩ 换行），记下后提示落点、点提示去那里（菜单栏面板里提示就在头部右边）。记下的是灵感：它要交给 Agent 先挂到任务，所以这里没有发送。
struct CaptureComposer: View {
    /// 没手动换过落点时落在哪（主窗口是正在看的项目，菜单栏面板是当前项目）。
    let defaultProject: UUID?
    /// 一直展开（菜单栏面板）。
    let pinnedOpen: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var draft = ComposerDraft()
    /// 手动换过的落点；nil 时用 `defaultProject`。
    @State private var chosen: UUID??
    @State private var saving = false
    @FocusState private var focused: Bool

    private var project: UUID? { chosen ?? defaultProject }
    private var destination: String { CaptureCopy.destination(workspace.catalog?.project(project)) }
    /// 收成一行（`Composer` 同一条规则）：没有头部的落点胶囊，占位要带上落点。
    private var collapsed: Bool { !pinnedOpen && !focused && draft.isEmpty(accepting: .images) }

    var body: some View {
        Composer(
            draft: $draft, prompt: collapsed ? CaptureCopy.placeholder(to: destination) : CaptureCopy.prompt, label: "随手记", focus: $focused,
            accepts: .images, pinnedOpen: pinnedOpen, shortcuts: [.send: save],
            header: { header }, tools: { EmptyView() }, send: { saveButton }
        )
        .onAppear { if pinnedOpen { focused = true } }
        .onChange(of: workspace.captureFocusRequests) { focused = true }
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
        }
        .animation(Motion.quick, value: workspace.notice)
        .padding(.horizontal, 12).padding(.top, 10)
    }

    private var saveButton: some View {
        Button(action: save) { SubmitGlyph(.save, enabled: !saving) }
            .buttonStyle(.plain)
            .disabled(saving)
            .accessibilityLabel("记下")
            .help("记下（⌘↩）")
    }

    private var destinationMenu: some View {
        Menu {
            Button(CaptureCopy.inbox) { chosen = .some(nil) }
            Divider()
            ForEach(workspace.catalog?.projects ?? []) { item in Button(item.name) { chosen = .some(item.id) } }
        } label: {
            HStack(spacing: 5) {
                Text("→").foregroundStyle(palette.ink3)
                ProjectGlyph(project: workspace.catalog?.project(project), size: 12)
                Text(destination).foregroundStyle(palette.ink).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(palette.ink3)
                    .accessibilityHidden(true)
            }
            .font(Typography.meta)
            .padding(.horizontal, 8).frame(height: 24)
            .background(palette.fill.opacity(2), in: .capsule)
            .contentShape(.capsule)
        }
        .menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("记到 \(destination)")
    }

    private func save() {
        let note = CaptureDraft(text: draft.text, images: draft.images.map(\.data)), project = project
        guard !note.isEmpty, !saving else { return }
        saving = true
        workspace.attempt {
            defer { saving = false }
            try await note.save(in: project, workspace: workspace)
            draft = ComposerDraft()
        }
    }
}
#endif
