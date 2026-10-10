import CueStore
import SwiftUI

/// 随手记正在写的这一条：草稿与手动换过的落点（`.some(nil)` 是未分类；nil 时落在调用方给的默认落点）。
/// iOS 存在 `Navigation.capture`（输入框收起后留着），Mac 的底部输入栏与菜单栏面板各留一份。
struct CaptureState {
    var draft = ComposerDraft()
    var project: UUID??
}

/// 随手记（iOS 浮起的输入框、Mac 底部输入栏与菜单栏面板共用）：共用的 `Composer`，头部左上是落点菜单（先看去哪、再写），
/// 提交钮是"记下"（⌘↩，↩ 换行）。记下的是灵感：它要交给 Agent 先挂到任务，所以这里没有发送；记下后提示落点、点提示去那里。
/// 文案与存法见 `CaptureCopy`、`CaptureDraft`。两端只差：Mac 底部输入栏平时收成一行、占位带上落点（`pinnedOpen` 为 false），
/// 菜单栏面板的提示写在头部右边。
struct CaptureComposer: View {
    @Binding var state: CaptureState
    /// 没手动换过落点时落在哪（iOS 与 Mac 主窗口是正在看的项目，菜单栏面板是上次打开的项目）。
    let defaultProject: UUID?
    /// 一直展开、出现即聚焦（iOS 浮起的输入框、Mac 菜单栏面板）；否则聚焦或有内容时才展开。
    let pinnedOpen: Bool
    /// 记下之后（iOS 收起输入框）；草稿在这之前已清空。
    var saved: () -> Void = {}
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var saving = false
    @FocusState private var focused: Bool

    private var project: UUID? { state.project ?? defaultProject }
    private var destination: String { CaptureCopy.destination(workspace.catalog?.project(project)) }
    /// 收成一行（`Composer` 同一条规则）：没有头部的落点胶囊，占位要带上落点。
    private var collapsed: Bool { !pinnedOpen && !focused && state.draft.isEmpty(accepting: .images) }

    var body: some View {
        Composer(
            draft: $state.draft, prompt: collapsed ? CaptureCopy.placeholder(to: destination) : CaptureCopy.prompt, label: "随手记",
            focus: $focused, accepts: .images, pinnedOpen: pinnedOpen, shortcuts: [.send: save],
            header: { header }, tools: { EmptyView() }, send: { saveButton }
        )
        // 一直展开的浮起的同一刻聚焦：键盘与输入框一起上来
        .onAppear { if pinnedOpen { focused = true } }
        #if os(macOS)
        .onChange(of: workspace.captureFocusRequests) { focused = true }
        #endif
    }

    private var header: some View {
        HStack(spacing: 8) {
            destinationMenu
            Spacer(minLength: 8)
            #if os(macOS)
            if pinnedOpen, let notice = workspace.notice {
                Text(notice.text).font(Typography.meta)
                    .foregroundStyle(notice.isError ? palette.failure : palette.ink3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            #endif
        }
        .animation(Motion.quick, value: workspace.notice)
        .padding(.horizontal, 12).padding(.top, 10)
    }

    private var destinationMenu: some View {
        Menu {
            Button(CaptureCopy.inbox) { state.project = .some(nil) }
            Divider()
            ForEach(workspace.catalog?.projects ?? []) { item in Button(item.name) { state.project = .some(item.id) } }
        } label: {
            DestinationChip(project: workspace.catalog?.project(project))
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize()
        #endif
        .accessibilityLabel("记到 \(destination)")
    }

    private var saveButton: some View {
        Button(action: save) { SubmitGlyph(.save, enabled: !saving) }
            .buttonStyle(.plain)
            .disabled(saving)
            .accessibilityLabel("记下")
            .help("记下（⌘↩）")
    }

    private func save() {
        let note = CaptureDraft(text: state.draft.text, images: state.draft.images.map(\.data)), project = project
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

/// 落点胶囊："→ 项目图标 项目名 ⌃⌄"（随手记的头部、iOS 任务页的快速添加）。
struct DestinationChip: View {
    let project: Project?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text("→").foregroundStyle(palette.ink3)
            ProjectGlyph(project: project, size: Self.glyph)
            Text(CaptureCopy.destination(project)).foregroundStyle(palette.ink).lineLimit(1)
            Image(systemName: "chevron.up.chevron.down").font(Self.chevron).foregroundStyle(palette.ink3).accessibilityHidden(true)
        }
        .font(Self.font)
        .padding(.horizontal, Self.inset).frame(height: Self.height)
        .background(palette.fill.opacity(Self.fill), in: .capsule)
        .contentShape(.capsule)
    }

    #if os(macOS)
    private static let spacing: CGFloat = 5, glyph: CGFloat = 12, inset: CGFloat = 8, height: CGFloat = 24, fill = 2.0
    private static let font = Typography.meta
    private static let chevron = Font.system(size: 9, weight: .semibold)
    #else
    private static let spacing: CGFloat = 6, glyph: CGFloat = 13, inset: CGFloat = 12, height: CGFloat = 32, fill = 1.0
    private static let font = Font.subheadline.weight(.medium)
    private static let chevron = Font.caption2
    #endif
}
