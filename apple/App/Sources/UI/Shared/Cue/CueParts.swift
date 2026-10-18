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

/// 还没启用时 Cue 页输入框上方的那一块，两端同一个：一句说明，下面直接选一台 Mac 启用（Cue 能住的几台，`CueSettings.hosts`）——
/// 一台就是一颗"在那台上启用"的主按钮；几台是点开选哪台的菜单（`MenuButton`，每台下面写能当大脑的几家或为什么不能用），
/// Mac 上点按是住在这台、长按选别的。没写成的原因就地写在下面（`CueSettingsModel`）。手机上还没有哪台 Mac 写下过自己时，
/// 说先到 Mac 上打开 CuePad。没启用时输入框发出去是记下灵感。
struct CueEnableCard: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = CueSettingsModel()

    var body: some View {
        let hosts = (model.settings ?? .empty).hosts(here: here)
        VStack(alignment: .leading, spacing: 10) {
            Text("启用后 \(workspace.cue.name) 住在一台 Mac 上，替你派活、跟进，只在要你拿主意时找你")
                .font(Typography.secondary).foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if hosts.isEmpty {
                Label("先到 Mac 上打开 CuePad，它会出现在这里", icon: .mac)
                    .font(Typography.secondary).foregroundStyle(palette.ink3)
            } else {
                HStack(spacing: 8) {
                    enableButton(hosts)
                    if model.enabling != nil { Spinner(.small) }
                }
                .disabled(model.enabling != nil)
            }
            if let failure = model.failure {
                Text(failure).font(Typography.meta).foregroundStyle(palette.failure)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: .rect(cornerRadius: ComposerMetrics.radius, style: .continuous))
        .cueSettings(model)
        .animation(Motion.quick, value: model.failure)
    }

    /// 这台 Mac（手机没有）：Mac 上它排第一、点按就住这台。
    private var here: String? {
        #if os(macOS)
        services.hostID
        #else
        nil
        #endif
    }

    @ViewBuilder private func enableButton(_ hosts: [CueSettings.Host]) -> some View {
        if hosts.count == 1, let host = hosts.first {
            Button(title(host)) { model.enable(on: host.id, services) }
                .buttonStyle(ControlButtonStyle(kind: .primary))
        } else {
            MenuButton(
                sections: [ChoiceMenu.Section(choices: hosts.map { host in
                    ChoiceMenu.Choice(title: host.name, subtitle: host.note.isEmpty ? nil : host.note, image: .icon(.mac)) {
                        model.enable(on: host.id, services)
                    }
                })],
                primary: here.map { here in { model.enable(on: here, services) } },
                accessibilityLabel: here == nil ? "选一台 Mac 启用" : "在这台 Mac 上启用", hint: here == nil ? nil : "长按选别的 Mac"
            ) {
                HStack(spacing: 6) {
                    Text(here == nil ? "选一台 Mac 启用" : "在这台 Mac 上启用")
                    Image(.expand).font(.footnote.weight(.semibold))
                }
                .modifier(ControlSurface(kind: .primary))
            }
        }
    }

    private func title(_ host: CueSettings.Host) -> String {
        host.id == here ? "在这台 Mac 上启用" : "在「\(host.name)」上启用"
    }
}

/// 一件活收成一行（对话里 Cue 的话下面、"等你"里关联的那件）：任务圈、标题、步骤数，点它打开任务。
struct CueTaskLine: View {
    let ref: CueTaskRef
    @Environment(\.palette) private var palette

    var body: some View {
        CueTaskButton(task: ref.task.id) {
            HStack(spacing: 6) {
                TaskRingView(status: ref.task.status, done: ref.done, size: 13)
                Text(ref.task.title).lineLimit(1)
                if let progress = ref.progress, !ref.done {
                    Text("\(progress.done)/\(progress.total)").monospacedDigit().foregroundStyle(palette.ink3)
                }
                Image(.forward).font(.system(size: 9, weight: .semibold))
            }
            .font(Typography.meta).foregroundStyle(palette.ink2)
            .frame(minHeight: 24)
        }
        .accessibilityLabel("关于 \(ref.task.title)")
        .accessibilityHint("打开任务")
    }
}

/// 连着的几条动态（Cue 自己醒来的那几轮：每轮先是它的经过，再是它说的那句；没推给你）：一行旁注（`NoteLine`），
/// 图标是一颗收着的话（与气泡里对你说的话分开：没有纸、不靠气泡、字小一档），写最新一条的首行（没有正文的写它的经过）与条数；
/// 点开在细线下按先后列全（`NoteThread`）——经过与回答注脚同一个样子（`RoundProcess`），说的话是小字。展开后那一行只写条数，最新一条就在列表末尾，不写两遍。
struct CueNotes: View {
    let notes: [CueMessage]
    /// 在跑的那一轮在这几条里时有（`CueLiveRound`）
    let live: CueLiveRound?
    @State private var expanded = DebugHooks.preset.toolsOpen
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                NoteLine(icon: .thinking, open: expanded) {
                    Text(expanded ? "\(notes.count) 条动态" : Dotted(notes.last.flatMap(Self.line), notes.count > 1 ? "\(notes.count) 条" : nil))
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "收起" : "展开")
            if expanded {
                NoteThread {
                    ForEach(notes) { note in
                        if note.tools != nil {
                            RoundProcess(tools: note.tools, ending: CueLiveRound.ending(of: note, in: live))
                        } else {
                            SaidRow(text: CueFormat.plainText(note.text))
                        }
                    }
                }
            }
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: expanded)
        .transition(.entry)
    }

    /// 一条动态收成一行：它说的那句的首行；经过那一行写经过那一句。
    private static func line(_ note: CueMessage) -> String? {
        PiProgress.firstLine(CueFormat.plainText(note.text)) ?? PiChat.processLine(note.tools)?.visible
    }
}

/// Cue 说的一句：靠左的一颗纸做的气泡（`cueBubble`），里面是 Markdown（同会话里 Agent 的回答）；它第一次提到一件活时气泡底下一行这件活（`CueTaskLine`）。
/// 问过你、你回答了的，下面靠右一颗你的小气泡写你的回答（`AnswerChip`；还在等的不在对话里，见 `CueThread.rows`；撤回的只剩这句话）。
/// 长按（Mac 右键）是消息菜单（`MessageMenu.Kind.cue`），预览就是这颗气泡。
struct CueSays: View {
    let message: CueMessage
    var task: CueTaskRef?
    /// 上面紧挨着 Cue 的另一句（`Bubble.shape`）。
    var joined = false
    /// 新到的从左下角长出来；原位换下正在说的话时（`CueEnding`）直接出现
    var arrives = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selecting = false

    var body: some View {
        let shape = Bubble.shape(.leading, joined: joined)
        VStack(alignment: .leading, spacing: 4) {
            BubbleWidth(fraction: Bubble.cueWidth, edge: .leading) {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownText(source: message.text).equatable()
                    if let task { CueTaskLine(ref: task) }
                }
                .cueBubble(joined: joined)
                #if os(iOS)
                .contentShape(.contextMenuPreview, shape)
                #endif
                .contextMenu { MessageActions(text: message.text, kind: .cue, selectText: { selecting = true }) }
            }
            if let answer = message.answer { AnswerChip(answer: answer) }
        }
        #if os(iOS)
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
        #endif
        .transition(arrives ? Bubble.arrival(.leading, reduceMotion: reduceMotion) : .identity)
    }
}

extension View {
    /// Cue 的话的气泡：纸色实底（`Palette.paper`，比桌面亮一级），你的话是比桌面深一级的牛皮纸色（`Palette.bubble`）。正在说的话（Mac）与说完落库的那句同一颗。
    /// 只铺一层底：不用卡片那套渐变、一线高光与描边（`paper()`）——气泡小，看不出差别，长对话滚动时每颗多出的层逐帧都要更新；
    /// 增强对比度时才描边（`Palette.bubbleEdge`）。
    func cueBubble(joined: Bool) -> some View { modifier(CueBubbleSurface(shape: Bubble.shape(.leading, joined: joined))) }
}

private struct CueBubbleSurface: ViewModifier {
    let shape: UnevenRoundedRectangle
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.padding(Bubble.padding).background(palette.paper, in: shape).overlay { if let edge = palette.bubbleEdge { shape.strokeBorder(edge) } }
    }
}

/// 你对 Cue 问的那一句的回答（选的那一项或另外说的话）：靠右一颗你的颜色的小气泡，前面一个回复的箭头。
private struct AnswerChip: View {
    let answer: String
    @Environment(\.palette) private var palette

    var body: some View {
        Label { Text(answer).lineLimit(2) } icon: { Image(.yourAnswer).imageScale(.small) }
            .font(Typography.secondary).foregroundStyle(palette.ink)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(palette.bubble, in: .capsule)
            .overlay { if let edge = palette.bubbleEdge { Capsule().strokeBorder(edge) } }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel("你回答：\(answer)")
    }
}

/// "等你"那一句要你定什么：赭黄问号与代码写出的问题（`CueAsk.question`）。"等你"卡与全屏预览的底栏共用。
struct CueQuestionLine: View {
    let question: String
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            PiStateGlyph(status: .asking)
            Text(question)
                .font(Typography.title).foregroundStyle(palette.ink)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// "等你"的选项：推荐的答案（第一个）作主按钮、其余次按钮，一行放不下就竖排。"等你"卡与全屏预览的底栏共用。
struct CueChoices: View {
    let options: [String]
    /// 其余选项的样子：铺在淡底的纸上（"等你"卡）用纸底，免得墨色的浅底叠在暖黄上发灰。
    var secondary = ControlButtonStyle.Kind.secondary
    var disabled = false
    let pick: (String) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
    }

    @ViewBuilder private var buttons: some View {
        ForEach(Array(options.enumerated()), id: \.offset) { index, option in
            Button(option) { pick(option) }
                .buttonStyle(ControlButtonStyle(kind: index == 0 ? .primary : secondary))
                .lineLimit(2)
                .disabled(disabled)
        }
    }
}

/// "等你"：固定在输入框上方，最早的那一条，收得紧（iPhone 上约三分之一屏以内）。第一句是要你定什么，由代码按类别与关联任务写出
/// （`CueAsk.question`），不靠 Cue 的措辞；Cue 的原话默认收起，点"原话"再看（长了在里面滚）。下面是关联任务的全部交付物
/// （迷你一排，新的在前；点开全屏时底栏就是这几个选项，看完当场定）、推荐的答案（第一个选项）作主按钮与其余选项、不允许时另外说的输入框（`CueAsk.otherwise`，回车交给 Cue），
/// 末行是关联的任务、还有几条在等、原话的开关。没有关掉：卡片一直挂着，直到你回答或 Cue 撤回。
/// 列表与数量只来自 `cueMessagesWaitingForYou()`：回答后等库里那条结束才换下一条，写的时候按钮停用；没写成就报错、按钮恢复，可以再点。
struct CueWaitingDock: View {
    let waiting: [CueMessage]
    let tasks: [UUID: CueTaskRef]
    let open: (PreviewOpening) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 正在结束的那条（写成后它从 `waiting` 里消失，写不成就清掉）。
    @State private var ending: UUID?
    /// 展开了原话的那条：换下一条时自动收起。
    @State private var reading: UUID?
    /// 不允许时另外说的话（换下一条时随视图身份清空）。
    @State private var otherwise = ""

    #if os(macOS)
    private static let originalHeight: CGFloat = 240
    private static let fieldHeight: CGFloat = 36
    #else
    private static let originalHeight: CGFloat = 160
    private static let fieldHeight: CGFloat = 40
    #endif

    /// 一条换下一条时新卡压在沉下的旧卡上原地交替（底边对齐叠放）：竖排的话两张同时占位，底栏一下高一倍、对话跟着跳。
    /// 卡与下面输入框的间距在卡里（`below`）：没有在等的时候这一层不占位，也不留出间距。
    var body: some View {
        ZStack(alignment: .bottom) { card }
    }

    private static let below: CGFloat = 8

    @ViewBuilder private var card: some View {
        if let message = waiting.first {
            let ref = message.taskID.flatMap { tasks[$0] }
            let question = (message.ask ?? .rule).question(task: ref?.task.heading)
            VStack(alignment: .leading, spacing: 12) {
                CueQuestionLine(question: question)
                if reading == message.id { original(message.text).transition(.opacity) }
                if let deliverables = ref?.deliverables.reversed(), !deliverables.isEmpty {
                    let batch = Array(deliverables)
                    DeliverableStrip(previews: batch, size: .mini, group: "waiting", bleed: 16) {
                        open(PreviewOpening(preview: $0, batch: batch, group: "waiting", reply: .answer(message, question: question)))
                    }
                }
                CueChoices(options: message.choices ?? [], secondary: .paper, disabled: ending == message.id) { answer(message, $0) }
                otherwiseField(message)
                HStack(spacing: 10) {
                    if let ref { CueTaskLine(ref: ref) }
                    Spacer(minLength: 0)
                    let others = waiting.count - 1
                    if others > 0 { Text("还有 \(others) 条").font(Typography.meta).foregroundStyle(palette.ink3) }
                    originalToggle(message)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: ComposerMetrics.radius, lifted: true, wash: PiShown(status: .asking).wash(palette))
            .animation(Motion.quick, value: reading)
            .id(message.id)
            .padding(.bottom, Self.below)
            .transition(Self.arrival(reduceMotion: reduceMotion))
        }
    }

    /// 从输入框那边升起（淡入、从 96% 放大、上移一小段），答完沉回去淡出；减弱动态效果时只淡入淡出。
    private static func arrival(reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .entry }
        let rise = AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)).combined(with: .offset(y: 12))
        let sink = AnyTransition.opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
        return .asymmetric(insertion: rise.animation(Motion.snappy), removal: sink.animation(Motion.quick))
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
                Image(.expand).font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
            .frame(minHeight: 24).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "收起原话" : "看 Cue 的原话")
    }

    /// 不允许时另外说：回车或点发送交给 Cue。
    private func otherwiseField(_ message: CueMessage) -> some View {
        let empty = otherwise.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(spacing: 6) {
            TextField(CueAsk.otherwise, text: $otherwise)
                .textFieldStyle(.plain).font(Typography.secondary)
                .submitLabel(.send)
                .onSubmit { sayOtherwise(message) }
            if !empty {
                Button("发送", icon: .sendAnswer) { sayOtherwise(message) }
                    .labelStyle(.iconOnly).font(.system(size: 18)).foregroundStyle(palette.signature)
                    .buttonStyle(PressStyle(.button))
            }
        }
        .padding(.horizontal, 12).frame(minHeight: Self.fieldHeight)
        // 与卡的圆角同心（卡的内边距 16）
        .background(palette.paper, in: .rect(cornerRadius: ComposerMetrics.radius - 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: ComposerMetrics.radius - 16, style: .continuous).strokeBorder(palette.hair) }
        .disabled(ending == message.id)
    }

    private func sayOtherwise(_ message: CueMessage) {
        let text = otherwise.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        answer(message, text)
    }

    private func answer(_ message: CueMessage, _ text: String) {
        ending = message.id
        workspace.attempt {
            defer { ending = nil }
            try await workspace.answerCueQuestion(message, text)
        }
    }
}
