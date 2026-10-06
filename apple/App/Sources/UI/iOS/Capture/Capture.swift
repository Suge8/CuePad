#if os(iOS)
import CueStore
import SwiftUI

/// 随手记输入框（书架、项目、今天页底部浮着的那一个）：共用的 `Composer`，去处是存成卡片或任务。
/// 平时一行，占位写明记成什么、落到哪；聚焦或有内容时展开头部：想法 | 任务、落点项目。
/// 记下后收起并提示落点（点提示去那里）。文案与存法见 `CaptureCopy`、`CaptureDraft`。
struct CaptureComposer: View {
    /// 从外面打开随手记的请求（小组件、快捷键）：接住后定落点、聚焦或拍照选图，再交回 `consume` 清掉。
    var request: Navigation.Capture?
    var consume: () -> Void = {}
    /// 一直展开（随手记面板里）。
    var pinnedOpen = false
    var onSaved: () -> Void = {}
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var draft = ComposerDraft()
    @State private var kind = CaptureKind.idea
    /// 手动换过的落点；nil 时落在正在看的页面（项目页是该项目，其余未归档）。
    @State private var chosen: UUID??
    @State private var source: ComposerSource?
    @State private var saving = false
    @FocusState private var focused: Bool

    private var project: UUID? { chosen ?? navigation.captureProject }
    private var destination: String { CaptureCopy.destination(workspace.catalog?.project(project), kind: kind) }

    var body: some View {
        Composer(
            draft: $draft, prompt: CaptureCopy.placeholder(kind, to: destination), label: "随手记", focus: $focused,
            accepts: kind == .idea ? .images : [], pinnedOpen: pinnedOpen, source: $source,
            header: { header }, send: { sendButton }
        )
        .animation(Motion.quick, value: kind)
        .onChange(of: request?.id, initial: true) {
            guard let request else { return }
            begin(request)
            consume()
        }
    }

    /// 从外面打开（小组件、快捷键、相机或相册入口）：定落点，聚焦或直接拍照、选图。
    private func begin(_ capture: Navigation.Capture) {
        chosen = .some(capture.project)
        kind = .idea
        switch capture.start {
        // 接住请求时输入框可能还没进视图层级，下一轮再聚焦
        case .text: Task { focused = true }
        case .camera: source = CameraPicker.isAvailable ? .camera : nil
        case .photos: source = .photos
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("记成", selection: $kind) {
                ForEach(CaptureKind.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer(minLength: 8)
            destinationMenu
        }
        .padding([.horizontal, .top], 8)
    }

    private var destinationMenu: some View {
        Menu {
            Button(kind == .idea ? CaptureCopy.inbox : "不归项目") { chosen = .some(nil) }
            Divider()
            ForEach(workspace.catalog?.projects ?? []) { item in Button(item.name) { chosen = .some(item.id) } }
        } label: {
            HStack(spacing: 6) {
                Text("→").foregroundStyle(palette.ink3)
                ProjectGlyph(project: workspace.catalog?.project(project), size: 13)
                Text(destination).foregroundStyle(palette.ink).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(palette.ink3).accessibilityHidden(true)
            }
            .font(.subheadline)
            .padding(.horizontal, 10).frame(minHeight: 36)
            .background(palette.fill, in: .capsule)
        }
        .accessibilityLabel("记到 \(destination)")
    }

    private var sendButton: some View {
        Button(action: save) { SendGlyph(enabled: !saving) }
            .buttonStyle(.plain)
            .disabled(saving)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("记下")
    }

    private func save() {
        guard !saving else { return }
        saving = true
        let note = CaptureDraft(text: draft.text, images: draft.images.map(\.data), kind: kind), project = project
        workspace.attempt {
            defer { saving = false }
            try await note.save(in: project, workspace: workspace)
            draft = ComposerDraft()
            chosen = nil
            focused = false
            onSaved()
        }
    }
}

extension View {
    /// iPad 内容页（书架、项目、今天、未归档）底部浮着的随手记入口；iPhone 的入口是标签栏的底部附件（见 `TabsRoot`），这里不挂。
    func captureBar() -> some View { modifier(SplitCaptureBar()) }
}

private struct SplitCaptureBar: ViewModifier {
    @Environment(Navigation.self) private var navigation

    @ViewBuilder func body(content: Content) -> some View {
        if navigation.layout == .split {
            content.safeAreaBar(edge: .bottom, spacing: 0) {
                CaptureEntry()
                    .frame(height: 50)
                    .glass(in: .capsule, interactive: true)
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
        } else {
            content
        }
    }
}

/// 随手记的入口：一行"记下想法 → 落点"，点开是随手记面板。不常驻输入框，底部只留一行玻璃，内容多露出来。
/// iPhone 放在标签栏的底部附件里：下滑时标签栏收小、它并进同一行（这时只写"记一笔"）。
struct CaptureEntry: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        let destination = CaptureCopy.destination(workspace.catalog?.project(navigation.captureProject), kind: .idea)
        Button { navigation.startCapture() } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil").foregroundStyle(palette.ink2).accessibilityHidden(true)
                Text(placement == .inline ? "记一笔" : CaptureCopy.placeholder(.idea, to: destination))
                    .foregroundStyle(palette.ink3).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("随手记")
        .accessibilityValue(destination)
    }
}

/// 随手记面板（底部入口、小组件、快捷键都打开它），里面是共用的输入框。
struct CaptureSheet: View {
    let capture: Navigation.Capture
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        VStack {
            Spacer(minLength: 0)
            CaptureComposer(request: capture, pinnedOpen: true) { dismiss() }.padding(16)
        }
        .presentationDetents([.medium])
        .presentationBackground(palette.desk)
    }
}
#endif
