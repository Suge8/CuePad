#if os(macOS)
import AppKit
import CueText
import SwiftUI
import UniformTypeIdentifiers

/// 主窗口底部浮着的随手记：平时一行，占位写明落到哪；聚焦或有内容时展开（左上落点、图片）。
struct CaptureBar: View {
    let project: UUID?

    private static let width: CGFloat = 620

    var body: some View {
        CaptureComposer(defaultProject: project, pinnedOpen: false)
            .frame(maxWidth: Self.width)
            .padding(.horizontal, 24)
    }
}

/// Mac 的随手记（底部输入栏与菜单栏面板共用），结构与文案同手机（`CaptureCopy`、`CaptureDraft`）：
/// 落点项目、附图；↩ 记成灵感（⌥↩ 换行），记下后提示落点、点提示去那里；另可 ⌘↩ 发到应用或复制（不存卡，没有 Agent 会话）。
struct CaptureComposer: View {
    /// 没手动换过落点时落在哪（主窗口是正在看的项目，菜单栏面板是当前项目）。
    let defaultProject: UUID?
    /// 一直展开（菜单栏面板）。
    let pinnedOpen: Bool
    var minHeight: CGFloat = 0
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var images: [Data] = []
    /// 手动换过的落点；nil 时用 `defaultProject`。
    @State private var chosen: UUID??
    @State private var saving = false
    @FocusState private var focused: Bool

    private var draft: CaptureDraft { CaptureDraft(text: text, images: images) }
    private var project: UUID? { chosen ?? defaultProject }
    private var destination: String { CaptureCopy.destination(workspace.catalog?.project(project)) }
    private var expanded: Bool { pinnedOpen || focused || !text.isEmpty || !images.isEmpty }
    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 有字、没有图时才能发出去（发图走纸页）：发到应用或复制，是次要动作；记下（↩）是主动作。随手记记下的是灵感，
    /// 发给 Agent 只经任务的提示词，所以这里的目标里没有 Agent 会话。
    private var showsSend: Bool { !trimmed.isEmpty && images.isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                if expanded {
                    HStack(spacing: 8) {
                        destinationMenu
                        Spacer(minLength: 8)
                    }
                    .transition(.opacity)
                    if !images.isEmpty { imageStrip }
                }
                field
            }
            .padding(expanded && !pinnedOpen ? 8 : 0)
            .modifier(CaptureSurface(pinned: pinnedOpen))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(palette.ink3.opacity(focused && !pinnedOpen ? 0.5 : 0), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            // 主窗口里发送钮浮在输入栏右边；菜单栏面板窄，它在稿纸里的工具排（见 `field`）
            if showsSend, !pinnedOpen {
                sendControl.transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .animation(Motion.quick, value: expanded)
        .animation(Motion.snappy, value: trimmed.isEmpty)
        .onAppear { if pinnedOpen { focused = true } }
        .onChange(of: workspace.captureFocusRequests) { focused = true }
    }

    /// 主窗口：一行（展开后右下是图片与记下）；菜单栏面板：文字在上，下面一排工具——图片、发送、记下，与稿纸同一边距。
    @ViewBuilder private var field: some View {
        Group {
            if pinnedOpen {
                VStack(alignment: .leading, spacing: 0) {
                    textField
                    HStack(spacing: 4) {
                        imageButton
                        Spacer(minLength: 0)
                        if showsSend { sendControl.transition(.opacity) }
                        saveButton
                    }
                    .padding([.horizontal, .bottom], 6)
                }
            } else {
                HStack(alignment: .bottom, spacing: 4) {
                    if !expanded {
                        Image(systemName: "square.and.pencil").foregroundStyle(palette.ink2).padding(.leading, 16).padding(.bottom, 13)
                            .accessibilityHidden(true)
                    }
                    textField
                    if expanded {
                        imageButton
                        saveButton
                    }
                }
            }
        }
        // 圆角 = 外框 22 − 内边距 8，与外框同心（菜单栏面板同样内边距 8）
        .background(expanded ? palette.paper : .clear, in: .rect(cornerRadius: 14, style: .continuous))
        // 收起时整条都是输入区：点到图标或留白也进入输入
        .contentShape(.rect(cornerRadius: 22))
        .onTapGesture { focused = true }
    }

    private var textField: some View {
        // 展开后落点在胶囊上，占位不再写一遍
        TextField(expanded ? CaptureCopy.prompt : CaptureCopy.placeholder(to: destination), text: $text, axis: .vertical)
            .accessibilityLabel("随手记")
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(expanded ? 1...8 : 1...1)
            .focused($focused)
            .onSubmit(save)
            .padding(.leading, expanded ? 12 : 4).padding(.vertical, 12)
            .frame(minHeight: expanded ? minHeight : 0, alignment: .topLeading)
    }

    private var imageButton: some View {
        Button("添加图片", systemImage: "photo.on.rectangle") { pickImages() }
            .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(palette.ink2)
            .frame(width: 32, height: 40)
    }

    private var saveButton: some View {
        Button(action: save) { SubmitGlyph(.save, enabled: !draft.isEmpty && !saving, size: .small) }
            .buttonStyle(.plain)
            .disabled(draft.isEmpty || saving)
            .accessibilityLabel("记下")
            .help("记下（↩）")
    }

    private var sendControl: some View {
        SendControl(project: project, agents: false, compact: pinnedOpen) { send($0) }
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
            .font(.system(size: 12))
            .padding(.horizontal, 8).frame(height: 24)
            .background(palette.fill.opacity(2), in: .capsule)
            .contentShape(.capsule)
        }
        .menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("记到 \(destination)")
    }

    private var imageStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                    ZStack(alignment: .topTrailing) {
                        Image(nsImage: NSImage(data: data) ?? NSImage()).resizable().scaledToFill()
                            .frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 8))
                        Button("移除", systemImage: "xmark.circle.fill") { images.remove(at: index) }
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(palette.ink2).padding(2)
                    }
                }
            }
        }
        .transition(.opacity)
    }

    private func pickImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        images += panel.urls.compactMap { try? Data(contentsOf: $0) }
    }

    private func save() {
        let draft = draft, project = project
        guard !draft.isEmpty, !saving else { return }
        saving = true
        workspace.attempt {
            defer { saving = false }
            try await draft.save(in: project, workspace: workspace)
            text = ""
            images = []
        }
        focused = true
    }

    private func send(_ choice: AppServices.Destination) {
        let body = trimmed
        guard !body.isEmpty else { return }
        Task { if await workspace.send(body, via: choice) { text = "" } }
    }
}

/// 随手记的外层：主窗口里是一块玻璃；菜单栏面板本身就是玻璃，里面不再叠一层。
private struct CaptureSurface: ViewModifier {
    let pinned: Bool

    func body(content: Content) -> some View {
        if pinned { content } else { content.glass(in: .rect(cornerRadius: 22), interactive: true) }
    }
}
#endif
