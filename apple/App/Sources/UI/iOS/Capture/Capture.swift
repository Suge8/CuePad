#if os(iOS)
import CueStore
import SwiftUI

/// 随手记：共用的 `Composer`，去处是存成卡片或任务；头部是 想法 | 任务 与落点。草稿是 `Navigation.capture`，
/// 收起后留着。记下后收起并提示落点（点提示去那里）。文案与存法见 `CaptureCopy`、`CaptureDraft`。
private struct CaptureComposer: View {
    let focus: FocusState<Bool>.Binding
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var saving = false

    private var kind: CaptureKind { navigation.capture.kind }
    private var project: UUID? { navigation.capture.project ?? navigation.captureProject }
    private var destination: String { CaptureCopy.destination(workspace.catalog?.project(project), kind: kind) }

    var body: some View {
        @Bindable var navigation = navigation
        Composer(
            draft: $navigation.capture.draft, prompt: CaptureCopy.placeholder(kind, to: destination), label: "随手记", focus: focus,
            accepts: kind == .idea ? .images : [], pinnedOpen: true,
            header: { header }, send: { sendButton }
        )
        .animation(Motion.quick, value: kind)
        // 浮起的同一刻聚焦：键盘与输入框一起上来
        .onAppear { focus.wrappedValue = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Picker("记成", selection: Bindable(navigation).capture.kind) {
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
            Button(kind == .idea ? CaptureCopy.inbox : "不归项目") { navigation.capture.project = .some(nil) }
            Divider()
            ForEach(workspace.catalog?.projects ?? []) { item in Button(item.name) { navigation.capture.project = .some(item.id) } }
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
        let draft = navigation.capture.draft
        let note = CaptureDraft(text: draft.text, images: draft.images.map(\.data), kind: kind), project = project
        workspace.attempt {
            defer { saving = false }
            try await note.save(in: project, workspace: workspace)
            focus.wrappedValue = false
            navigation.finishCapture()
        }
    }
}

/// "写"（浮起随手记）的名字与图标：iPhone 标签栏右边的圆钮与 iPad 工具栏共用。图标不用 square.and.pencil：
/// 项目页的"新建卡片"是它，两个按钮会同时在屏上。
enum WriteEntry {
    static let title = "记一笔"
    static let symbol = "pencil.line"
}

/// 浮起的随手记（"写"、⌘⇧N、小组件都打开它）：只有输入框贴在键盘上方，不铺底、不弹面板。
/// 点空白处或往下拖收起（`Navigation.endCapture`）；输入框跟手往下走，没拖够就回位。
struct CaptureLayer: View {
    @Environment(Navigation.self) private var navigation
    /// 没拖够松手时弹回原位。
    @GestureState(resetTransaction: Transaction(animation: Motion.snappy)) private var drag: CGFloat = 0
    /// 收起时先放下键盘再移走输入框：要是等它移走后才失去焦点，键盘在它淡出之后才开始下落。
    @FocusState private var focused: Bool

    /// 往下拖过这么多（或甩出去会过）就收起。
    private static let dismissDistance: CGFloat = 60
    private static let maxWidth: CGFloat = 600

    var body: some View {
        ZStack(alignment: .bottom) {
            if navigation.capturing {
                Color.clear.contentShape(.rect).ignoresSafeArea()
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in close() })
                    .accessibilityHidden(true)
                CaptureComposer(focus: $focused)
                    .frame(maxWidth: Self.maxWidth)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .offset(y: drag)
                    .gesture(swipeDown)
                    .transition(.opacity)
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape, close)
            }
        }
        // 只淡入淡出：位置跟着键盘走（浮起时随键盘升上来），自己不再加位移
        .animation(Motion.quick, value: navigation.capturing)
    }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($drag) { value, drag, _ in drag = max(0, value.translation.height) }
            .onEnded { value in
                if max(value.translation.height, value.predictedEndTranslation.height) > Self.dismissDistance { close() }
            }
    }

    private func close() {
        focused = false
        navigation.endCapture()
    }
}
#endif
