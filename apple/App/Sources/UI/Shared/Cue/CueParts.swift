import CueStore
import CueText
import SwiftUI

/// 打开一件任务（Cue 页里提到的那一行、"等你"关联的任务）：Mac 是任务浮窗，iOS 推入任务的纸页。
struct CueTaskButton<Label: View>: View {
    let task: UUID
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        Button(action: open) { label.contentShape(.rect) }
            .buttonStyle(PressStyle(.card))
    }

    private func open() {
        #if os(iOS)
        navigation.push(.card(task))
        #else
        let store = workspace.services.store, id = task
        workspace.attempt { if let card = try await store.card(id) { workspace.open(card) } }
        #endif
    }
}

/// 还没启用时 Cue 页输入框上方的那一块：Mac 上主按钮直接是"在这台 Mac 上启用"（经管理器，挑这台装好并登录了的 Agent；
/// 一家都没有时就地说明）；手机上说明去哪台 Mac 启用（之前住过的那台写出名字）。没启用时输入框发不出去。
struct CueEnableCard: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var enabling = false
    @State private var failure: String?

    var body: some View {
        let cue = workspace.cue
        VStack(alignment: .leading, spacing: 10) {
            #if os(macOS)
            Text("启用后 \(cue.name) 住在这台 Mac 上，替你派活、跟进，只在要你拿主意时找你").font(Typography.secondary).foregroundStyle(palette.ink2)
            HStack(spacing: 10) {
                Button(action: enable) {
                    HStack(spacing: 6) {
                        if enabling { Spinner(.mini) }
                        Text("在这台 Mac 上启用")
                    }
                }
                .buttonStyle(ControlButtonStyle(kind: .primary))
                .disabled(enabling)
                if let failure { Text(failure).font(Typography.meta).foregroundStyle(palette.failure).lineLimit(2) }
            }
            #else
            Label {
                Text(cue.digest.hostName.map { "到「\($0)」上打开 CuePad，在设置里启用 \(cue.name)" } ?? "到你的 Mac 上打开 CuePad，在设置里启用 \(cue.name)")
            } icon: {
                Image(systemName: "desktopcomputer")
            }
            .font(Typography.secondary).foregroundStyle(palette.ink2)
            #endif
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: .rect(cornerRadius: ComposerMetrics.radius, style: .continuous))
    }

    #if os(macOS)
    private func enable() {
        enabling = true
        failure = nil
        let cue = services.cue
        Task {
            defer { enabling = false }
            do {
                try await cue.enable()
            } catch {
                failure = error.localizedDescription
            }
        }
    }
    #endif
}

/// 一件活收成一行（对话里 Cue 的话下面、"等你"里关联的那件）：任务圈、标题、步骤数，点它打开任务。
struct CueTaskLine: View {
    let ref: CueTaskRef
    @Environment(\.palette) private var palette

    var body: some View {
        CueTaskButton(task: ref.task.id) {
            HStack(spacing: 6) {
                TaskRingView(status: ref.task.status, ring: TaskRing(ref.progress), done: ref.done, size: 13)
                Text(ref.task.title).lineLimit(1)
                if let progress = ref.progress, !ref.done {
                    Text("\(progress.done)/\(progress.total)").monospacedDigit().foregroundStyle(palette.ink3)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
            }
            .font(Typography.meta).foregroundStyle(palette.ink2)
            .frame(minHeight: 24)
        }
        .accessibilityLabel("关于 \(ref.task.title)")
        .accessibilityHint("打开任务")
    }
}

/// 一份预览的缩略图（"等你"里的证据）：图片是图本身，其余是类型图标；点它全屏看（`previewPresenter`）。
struct CuePreviewThumb: View {
    let preview: PiPreview
    let open: (PiPreview) -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button { open(preview) } label: {
            Group {
                if preview.kind == .image {
                    Thumbnail(hash: preview.hash, height: Self.side, radius: 8)
                } else {
                    Image(systemName: PreviewCard.symbol(preview.kind)).font(.title3).foregroundStyle(palette.ink3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(palette.fill, in: .rect(cornerRadius: 8, style: .continuous))
                }
            }
            .frame(width: Self.side, height: Self.side)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel("预览：\(preview.title)")
        #if os(macOS)
        .help(preview.title)
        #endif
    }

    private static let side: CGFloat = 44
}

/// 连着的几条动态（Cue 自己醒来那一轮的经过）：折成一行灰字，点开看全。
struct CueNotes: View {
    let notes: [CueMessage]
    @State private var expanded = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(Motion.quick) { expanded.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(Dotted(PiProgress.firstLine(CueFormat.plainText(notes.last?.text ?? "")), notes.count > 1 ? "\(notes.count) 条" : nil))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .font(Typography.meta).foregroundStyle(palette.ink3)
                .frame(minHeight: 24).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "收起" : "展开")
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notes) { note in
                        Text(CueFormat.plainText(note.text)).font(Typography.meta).foregroundStyle(palette.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                            .selectable()
                    }
                }
                .padding(.leading, 15)
                .transition(.opacity)
            }
        }
        .transition(.entry)
    }
}

/// Cue 说的一句：左侧全宽 Markdown（同会话里 Agent 的回答）；问过你的、你选了的下面一行写你选的那一项（还在等的不在对话里，见 `CueThread.rows`；
/// 关掉或撤回的只剩这句话）。
struct CueSays: View {
    let message: CueMessage
    /// 新到的淡入；原位换下正在说的话时（见 `DraftReply`）直接出现
    var fadesIn = true
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownText(source: message.text).equatable()
            if let answer = message.answer {
                Label(answer, systemImage: "arrowshape.turn.up.left").font(Typography.meta).foregroundStyle(palette.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(fadesIn ? .entry : .identity)
    }
}

/// "等你"：固定在输入框上方，最早的那一条，收得紧（iPhone 上约三分之一屏以内）。第一句是要你定什么，由代码按类别与关联任务写出
/// （`CueAsk.question`），不靠 Cue 的措辞；Cue 的原话默认收起，点"原话"再看（长了在里面滚）。下面是关联任务发来看的文件
/// （小缩略图，验收的证据）、推荐的答案（第一个选项）作主按钮与其余选项，末行是关联的任务、还有几条在等、原话的开关；右上角关掉。
/// 列表与数量只来自 `cueMessagesWaitingForYou()`：选了或关掉后等库里那条结束才换下一条，写的时候按钮停用；没写成就报错、按钮恢复，可以再点。
struct CueWaitingDock: View {
    let waiting: [CueMessage]
    let tasks: [UUID: CueTaskRef]
    let open: (PiPreview) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    /// 正在结束的那条（写成后它从 `waiting` 里消失，写不成就清掉）。
    @State private var ending: UUID?
    /// 展开了原话的那条：换下一条时自动收起。
    @State private var reading: UUID?

    #if os(macOS)
    private static let originalHeight: CGFloat = 240
    #else
    private static let originalHeight: CGFloat = 160
    #endif

    var body: some View {
        if let message = waiting.first {
            let ref = message.taskID.flatMap { tasks[$0] }
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PiStateGlyph(status: .asking)
                    Text((message.ask ?? .rule).question(task: ref?.task.heading))
                        .font(Typography.bodyStrong).foregroundStyle(palette.ink)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("关掉", systemImage: "xmark") { end(message, .dismissed) }
                        .labelStyle(.iconOnly).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink3)
                        .frame(width: 28, height: 28).contentShape(.rect)
                        .buttonStyle(PressStyle(.button))
                        .disabled(ending == message.id)
                        .help("不选，关掉这条")
                }
                if reading == message.id { original(message.text).transition(.opacity) }
                // 关联任务发来看的文件就是证据：在手机上看完图再决定允不允许
                if let previews = ref?.previews, !previews.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) { ForEach(previews) { CuePreviewThumb(preview: $0, open: open) } }
                    }
                }
                choices(message)
                HStack(spacing: 10) {
                    if let ref { CueTaskLine(ref: ref) }
                    Spacer(minLength: 0)
                    let others = waiting.count - 1
                    if others > 0 { Text("还有 \(others) 条").font(Typography.meta).foregroundStyle(palette.ink3) }
                    originalToggle(message)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glass(in: .rect(cornerRadius: PiReplyBar.radius, style: .continuous))
            .animation(Motion.quick, value: reading)
            .id(message.id)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    /// Cue 的原话：放得下就整段，放不下在 `originalHeight` 里滚。
    private func original(_ text: String) -> some View {
        let body = MarkdownText(source: text).equatable().font(Typography.secondary).foregroundStyle(palette.ink2)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        return ViewThatFits(in: .vertical) {
            body
            ScrollView { body }
        }
        .frame(maxHeight: Self.originalHeight)
    }

    private func originalToggle(_ message: CueMessage) -> some View {
        let open = reading == message.id
        return Button { reading = open ? nil : message.id } label: {
            HStack(spacing: 4) {
                Text("原话")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
            .frame(minHeight: 24).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "收起原话" : "看 Cue 的原话")
    }

    private func choices(_ message: CueMessage) -> some View {
        let options = message.choices ?? []
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons(message, options) }
            VStack(alignment: .leading, spacing: 8) { buttons(message, options) }
        }
    }

    @ViewBuilder private func buttons(_ message: CueMessage, _ options: [String]) -> some View {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            Button(option) { end(message, .answered(option)) }
                .buttonStyle(ControlButtonStyle(kind: index == 0 ? .primary : .secondary, compact: true))
                .lineLimit(2)
                .disabled(ending == message.id)
        }
    }

    private func end(_ message: CueMessage, _ end: CueQuestionEnd) {
        ending = message.id
        workspace.attempt {
            defer { ending = nil }
            try await workspace.endCueQuestion(message, end)
        }
    }
}
