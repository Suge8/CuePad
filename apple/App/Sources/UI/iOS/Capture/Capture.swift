#if os(iOS)
import CueStore
import SwiftUI

/// 随手记：共用的 `Composer`，去处是存成一条灵感；头部是落点。草稿是 `Navigation.capture`，
/// 收起后留着。记下后收起并提示落点（点提示去那里）。文案与存法见 `CaptureCopy`、`CaptureDraft`。浮在 `FloatingInput` 里。
struct CaptureComposer: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var saving = false
    @FocusState private var focused: Bool

    private var project: UUID? { navigation.capture.project ?? navigation.captureProject }
    private var destination: String { CaptureCopy.destination(workspace.catalog?.project(project)) }

    var body: some View {
        @Bindable var navigation = navigation
        Composer(
            draft: $navigation.capture.draft, prompt: CaptureCopy.prompt, label: "随手记", focus: $focused,
            accepts: .images, pinnedOpen: true,
            header: { header }, send: { sendButton }
        )
        // 浮起的同一刻聚焦：键盘与输入框一起上来
        .onAppear { focused = true }
    }

    private var header: some View {
        // 先看去哪、再写：落点在左上
        HStack(spacing: 8) {
            destinationMenu
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12).padding(.top, 10)
    }

    private var destinationMenu: some View {
        Menu {
            Button(CaptureCopy.inbox) { navigation.capture.project = .some(nil) }
            Divider()
            ForEach(workspace.catalog?.projects ?? []) { item in Button(item.name) { navigation.capture.project = .some(item.id) } }
        } label: {
            DestinationChip(project: workspace.catalog?.project(project))
        }
        .accessibilityLabel("记到 \(destination)")
    }

    private var sendButton: some View {
        Button(action: save) { SubmitGlyph(.save, enabled: !saving) }
            .buttonStyle(.plain)
            .disabled(saving)
            .keyboardShortcut(.return, modifiers: .command)
            .accessibilityLabel("记下")
    }

    private func save() {
        guard !saving else { return }
        saving = true
        let draft = navigation.capture.draft
        let note = CaptureDraft(text: draft.text, images: draft.images.map(\.data)), project = project
        workspace.attempt {
            defer { saving = false }
            try await note.save(in: project, workspace: workspace)
            focused = false
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

/// 浮在键盘上方的输入框（随手记、新会话、交给 Agent 共用）：不弹面板，背后薄薄压一层桌面色（玻璃底下的卡片不透出来抢字），浮起时随键盘升上来。
/// 点空白处或往下拖收起（输入框跟手往下走，没拖够就回位）；里面在忙时（内容标了 `floatingInputLocked`）不收起。
struct FloatingInput<Content: View>: View {
    let isPresented: Bool
    let close: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var locked = false
    @Environment(\.palette) private var palette
    /// 没拖够松手时弹回原位。
    @GestureState(resetTransaction: Transaction(animation: Motion.snappy)) private var drag: CGFloat = 0

    /// 往下拖过这么多（或甩出去会过）就收起。
    private static var dismissDistance: CGFloat { 60 }
    private static var maxWidth: CGFloat { 600 }

    var body: some View {
        ZStack(alignment: .bottom) {
            if isPresented {
                // 背后的页面虚化再压一层桌面色：只压色的话，Agent 列表这类带彩色状态标的页面还读得清，和输入框抢眼
                Rectangle().fill(.ultraThinMaterial).overlay(palette.desk.opacity(0.45)).contentShape(.rect).ignoresSafeArea()
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in dismiss() })
                    .accessibilityHidden(true)
                content()
                    .frame(maxWidth: Self.maxWidth)
                    .padding(.horizontal, 12).padding(.bottom, 8)
                    .offset(y: drag)
                    .gesture(swipeDown)
                    .transition(.opacity)
                    .onPreferenceChange(FloatingInputLock.self) { locked = $0 }
                    .accessibilityAddTraits(.isModal)
                    .accessibilityAction(.escape, dismiss)
            }
        }
        // 只淡入淡出：位置跟着键盘走，自己不再加位移
        .animation(Motion.quick, value: isPresented)
    }

    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($drag) { value, drag, _ in if !locked { drag = max(0, value.translation.height) } }
            .onEnded { value in
                if max(value.translation.height, value.predictedEndTranslation.height) > Self.dismissDistance { dismiss() }
            }
    }

    private func dismiss() {
        guard !locked else { return }
        // 先放下键盘再移走输入框：等它移走后才失去焦点的话，键盘在它淡出之后才开始下落
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        close()
    }
}

private struct FloatingInputLock: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension View {
    /// 浮起的输入框里在忙（如新会话已发出、等 Mac 开好）：点空白处与下拖不收起。
    func floatingInputLocked(_ locked: Bool) -> some View { preference(key: FloatingInputLock.self, value: locked) }
}
#endif
