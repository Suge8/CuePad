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

/// 还没启用时 Cue 页输入框上方的那一块，两端同一个：一句说明，下面直接选一台 Mac 启用（能运行 Cue 的几台，`CueSettings.hosts`）——
/// 一台就是一颗"在那台上启用"的主按钮；几台是点开选哪台的菜单（`MenuButton`，每台下面写能当大脑的几家或为什么不能用），
/// Mac 上点按是在这台运行、长按选别的。没写成的原因就地写在下面（`CueSettingsModel`）。手机上还没有哪台 Mac 写下过自己时，
/// 说先到 Mac 上打开 CuePad。没启用时输入框发出去是记下灵感。
struct CueEnableCard: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = CueSettingsModel()

    var body: some View {
        let hosts = (model.settings ?? .empty).hosts(here: here)
        VStack(alignment: .leading, spacing: 10) {
            Text("启用后 \(workspace.cue.name) 在你选的一台 Mac 上运行，替你派活、跟进，只在要你拿主意时找你")
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

    /// 这台 Mac（手机没有）：Mac 上它排第一、点按就在这台运行。
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
    /// 可点的高（"等你"卡的末行撑满 44）
    var height: CGFloat = 24
    /// 标题至多几行（"等你"卡在辅助功能字号下两行）
    var lines = 1
    @Environment(\.palette) private var palette

    var body: some View {
        CueTaskButton(task: ref.task.id) {
            HStack(spacing: 6) {
                TaskRingView(status: ref.task.status, done: ref.done, size: 13)
                Text(ref.task.title).lineLimit(lines).fixedSize(horizontal: false, vertical: lines > 1)
                if let progress = ref.progress, !ref.done {
                    Text("\(progress.done)/\(progress.total)").monospacedDigit().foregroundStyle(palette.ink3)
                }
                Image(.forward).font(.system(size: 9, weight: .semibold))
            }
            .font(Typography.meta).foregroundStyle(palette.ink2)
            .frame(minHeight: height).contentShape(.rect)
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

/// Cue 页的对话气泡（你的话、Cue 的话）：只有 Cue 页是两边对说，会话页你的话是另一种（`BubbleLook.session`）。
/// 说话的那一边下角收成小角，像从那一边递过来的一张纸条：一眼分得出谁说的，不画尾巴；
/// 同一边连着说的几颗收紧成一串（`joinedGap`），后面几颗那一边的上角也收小，连成一列。圆角、内边距只在这里定。
enum CueBubble {
    static let radius: CGFloat = 22
    static let corner: CGFloat = 6
    #if os(macOS)
    static let padding = EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
    #else
    static let padding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    #endif
    /// 同一边连着说的两颗之间。
    static let joinedGap: CGFloat = 4
    /// 气泡旁的旁注（经过、动态，`NoteLine`）离那一边的距离：图标对着气泡里的字。
    static let noteInset: CGFloat = padding.leading
    /// Cue 的话最宽占所在一栏的比例：回答常带列表与代码，比你的话（`UserBubble.widthFraction`）宽（手机上窄，再宽一点）。
    #if os(macOS)
    static let cueWidth: CGFloat = 0.86
    #else
    static let cueWidth: CGFloat = 0.9
    #endif

    /// `joined`：上面紧挨着同一边的一颗。
    static func shape(_ edge: HorizontalEdge, joined: Bool = false) -> UnevenRoundedRectangle {
        let top = joined ? corner : radius
        return switch edge {
        case .trailing: UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: corner, topTrailingRadius: top, style: .continuous)
        case .leading: UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: corner, bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous)
        }
    }

    /// 新说出的一颗从说话那一边的下角长出来（淡入并从 92% 放大到位）：你发出的从输入框那一角冒出，与对话上滑是同一段；只动变换，不改排版。
    /// 消失只淡出。减弱动态效果时只淡入淡出。
    static func arrival(_ edge: HorizontalEdge, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .entry }
        let grow = AnyTransition.opacity.combined(with: .scale(scale: 0.92, anchor: edge == .trailing ? .bottomTrailing : .bottomLeading))
        return .asymmetric(insertion: grow.animation(Motion.snappy), removal: .entry)
    }
}


/// Cue 说的一句：靠左的一颗纸做的气泡（`cueBubble`），里面是 Markdown（同会话里 Agent 的回答）；它第一次提到一件活时气泡底下一行这件活（`CueTaskLine`）。
/// 问过你的，答完或撤回后回到问的位置，这句话下面是它点名的图（`CueShots`）；你的回答在答的那一刻另成一格（`CueAnswer`，还在等的不在对话里，见 `CueThread.rows`）。
/// 长按（Mac 右键）是消息菜单（`MessageMenu.Kind.cue`），预览就是这颗气泡。
struct CueSays: View {
    let message: CueMessage
    var task: CueTaskRef?
    /// 提问点名的图（`CueThread.shots`）与点开一张
    var shots: [CueShown] = []
    var open: (PreviewOpening) -> Void = { _ in }
    /// 上面紧挨着 Cue 的另一句（`CueBubble.shape`）。
    var joined = false
    /// 新到的从左下角长出来；原位换下正在说的话时（`CueEnding`）直接出现
    var arrives = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selecting = false

    var body: some View {
        let shape = CueBubble.shape(.leading, joined: joined)
        VStack(alignment: .leading, spacing: 4) {
            BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownText(source: message.text).equatable()
                    if !shots.isEmpty { CueShots(shots: shots, group: message.id.uuidString, reply: .cue, open: open) }
                    if let task { CueTaskLine(ref: task) }
                }
                .cueBubble(joined: joined)
                #if os(iOS)
                .contentShape(.contextMenuPreview, shape)
                #endif
                .contextMenu { MessageActions(text: message.text, kind: .cue, selectText: { selecting = true }) }
            }
        }
        #if os(iOS)
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
        #endif
        .transition(arrives ? CueBubble.arrival(.leading, reduceMotion: reduceMotion) : .identity)
    }
}

/// 你对 Cue 一条提问的回答（`CueThread.Row.answer`）：你那一边的一颗气泡（`AnswerBubble`，同会话里的作答），字上面一行答的是哪张卡（`CueMessage.headline`，
/// 点它跳回问的那句），下面是选的那一项（更旧版本存下的另外一句照原文）。从刻度滑条跳过来时描一圈。
struct CueAnswer: View {
    let question: CueMessage
    var joined = false
    @Environment(\.chatHighlight) private var highlight

    var body: some View {
        let id = CueThread.Row.answerID(of: question.id), answer = question.answer ?? ""
        AnswerBubble(
            answer: answer, quote: question.headline.map { BubbleQuote(text: $0, target: question.id) }, look: .cue(joined: joined),
            highlighted: highlight == id
        ) {
            MessageActions(text: answer, kind: .cue)
        }
    }
}

extension View {
    /// Cue 的话的气泡：纸色实底（`Palette.paper`，比桌面亮一级），你的话是比桌面深一级的牛皮纸色（`Palette.bubble`）。正在说的话（Mac）与说完落库的那句同一颗。
    /// 只铺一层底：不用卡片那套渐变、一线高光与描边（`paper()`）——气泡小，看不出差别，长对话滚动时每颗多出的层逐帧都要更新；
    /// 增强对比度时才描边（`Palette.bubbleEdge`）。
    func cueBubble(joined: Bool) -> some View { modifier(CueBubbleSurface(shape: CueBubble.shape(.leading, joined: joined))) }
}

private struct CueBubbleSurface: ViewModifier {
    let shape: UnevenRoundedRectangle
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.padding(CueBubble.padding).background(palette.paper, in: shape).overlay { if let edge = palette.bubbleEdge { shape.strokeBorder(edge) } }
    }
}

/// "等你"那一句要你定什么：两列，左边赭黄问号（全卡唯一的状态色）、右边代码写出的问题（`CueMessage.headline`），规矩那一类下面再一行
/// 引的规矩（`CueAsking.why`），两行同一条左缘、都不限行。"等你"卡与全屏预览的底栏共用。
struct CueQuestionLine: View {
    let message: CueMessage
    @Environment(\.palette) private var palette

    var body: some View {
        let headline = message.headline ?? "", why = message.asking?.why
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            PiStateGlyph(status: .asking).font(Typography.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.keepingTail(headline)).font(Typography.title).foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let why {
                    Text(Self.keepingTail(why)).font(Typography.secondary).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([headline, why].compactMap(\.self).joined(separator: "，"))
    }

    /// 只给显示：句尾最后 4 个字（汉字一个算一个，英文单词、数字一整段算一个，不算标点）连同其间与其后的标点粘成一块，
    /// 换行时不会只剩"我选」。"这样的尾巴挂在下一行。块与块之间插字连接符（U+2060，不占宽、不显示）；不插进单词里面：
    /// 插在字母之间时排版反倒在那里断开（"ma / in"）。存储、通知、读屏、复制都用原文。
    static func keepingTail(_ text: String) -> String {
        func latin(_ character: Character) -> Bool { character.isASCII && (character.isLetter || character.isNumber) }
        var rest = Substring(text), pieces: [Substring] = [], counted = 0
        while counted < tailLength, let last = rest.last {
            let length = latin(last) ? rest.reversed().prefix(while: latin).count : 1
            pieces.insert(rest.suffix(length), at: 0)
            rest = rest.dropLast(length)
            if last.isLetter || last.isNumber { counted += 1 }
        }
        guard counted == tailLength else { return text }
        return rest + pieces.joined(separator: "\u{2060}")
    }

    private static let tailLength = 4
}

/// "等你"的选项：只有第一项"可以"是实底主按钮（全卡唯一的靛青）；第二项（"以后……不用问"）是无底色的文字按钮、宽按文字，在"可以"左边，
/// 一行放不下（项目名长）或辅助功能字号时竖排在"可以"下面、居中。"等你"卡与全屏预览的底栏共用。
/// 手机上"可以"伸满剩下的宽（只有它时占满一行）；Mac 上排在一行尾端，"可以"不窄过 `onceWidth`。
struct CueChoices: View {
    let options: [String]
    var disabled = false
    let pick: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    #if os(macOS)
    static let onceWidth: CGFloat = 96
    private static let fills = false
    private static let stackGap: CGFloat = 4
    #else
    static let onceWidth: CGFloat = 88
    private static let fills = true
    /// 文字按钮自带可点的高，竖排时与"可以"不另留间距
    private static let stackGap: CGFloat = 0
    #endif
    /// 按钮左右的内边距（`ControlSurface`）：最小宽要扣掉它才是字的宽
    private static let inset: CGFloat = 32

    var body: some View {
        let once = options.first ?? CueAsk.once, others = Array(options.dropFirst())
        let stacked = VStack(spacing: Self.stackGap) {
            button(once, kind: .primary, fill: true)
            ForEach(others, id: \.self) { button($0, kind: .quiet) }
        }
        // Mac 上竖排也按字宽收着（"可以"与文字按钮同宽），不铺满整行
        .fixedSize(horizontal: !Self.fills, vertical: false)
        if others.isEmpty {
            button(once, kind: .primary, fill: Self.fills, minWidth: Self.onceWidth)
        } else if typeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(others, id: \.self) { button($0, kind: .quiet).lineLimit(1).fixedSize() }
                    button(once, kind: .primary, fill: Self.fills, minWidth: Self.onceWidth).lineLimit(1)
                }
                stacked
            }
        }
    }

    private func button(_ option: String, kind: ControlButtonStyle.Kind, fill: Bool = false, minWidth: CGFloat = 0) -> some View {
        Button { pick(option) } label: {
            Text(option).multilineTextAlignment(.center)
                .frame(minWidth: max(0, minWidth - Self.inset), maxWidth: fill ? .infinity : nil)
        }
        .buttonStyle(ControlButtonStyle(kind: kind))
        .disabled(disabled)
    }
}

/// 提问点名要你看的图（`CueShown`，至多 `CueShot.limit` 张），按 Cue 给的先后：一排靠左、一行排完不横滑，每张同样大的方形缩略图
/// （边长 `ShotRow`：放得下就是 `side`，不然几张平分可用宽），按显著区域裁切填满（`LookBox.salient`）。缩略图本来看不全、都要点开，它只管认出是哪张、邀请点开；
/// 要看什么由每张正下方那一句说（与图同宽、向下换行；含"："的拆两行，前半加粗是名字、后半是说明），辅助功能字号下也一样。
/// 点一张全屏看整张，左右翻的就是这几张，页顶写看什么；底栏按 `reply`（"等你"里是那几个选项）。
struct CueShots: View {
    let shots: [CueShown]
    let group: String
    let reply: PreviewReply
    let open: (PreviewOpening) -> Void
    @Environment(\.palette) private var palette

    #if os(macOS)
    static let side: CGFloat = 140
    #else
    static let side: CGFloat = 120
    #endif
    private static let gap = DeliverableStrip.gap

    var body: some View {
        ShotRow(side: Self.side, gap: Self.gap) {
            ForEach(shots) { shot in
                VStack(alignment: .leading, spacing: 8) {
                    tile(shot)
                    caption(shot.look)
                }
            }
        }
    }

    private func tile(_ shot: CueShown) -> some View {
        let batch = shots.map(\.preview), looks = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0.look) })
        return DeliverableTile(
            preview: shot.preview, label: shot.look, shape: .shot(side: Self.side), captioned: false, zoom: PreviewZoomKey(group: group, preview: shot.id)
        ) { open(PreviewOpening(preview: $0, batch: batch, group: group, reply: reply, looks: looks)) }
    }

    /// 看什么：读屏读图的标签（`DeliverableTile` 的 label），这里只给眼睛看。
    private func caption(_ look: String) -> some View {
        let parts = look.split(separator: "：", maxSplits: 1).map(String.init)
        return VStack(alignment: .leading, spacing: 1) {
            Text(parts.first ?? look).fontWeight(.semibold).foregroundStyle(palette.ink)
            if parts.count > 1 { Text(parts[1]).foregroundStyle(palette.ink2) }
        }
        .font(Typography.meta)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }
}

/// 一排等宽的格，靠左、顶端对齐：格宽 = min(`side`, (给的宽 − 间距) / 张数)，一行排完，不横滑。
private struct ShotRow: Layout {
    let side: CGFloat
    let gap: CGFloat

    private func width(_ proposal: ProposedViewSize, _ count: Int) -> CGFloat {
        let gaps = gap * CGFloat(count - 1)
        guard let width = proposal.width, width.isFinite else { return side }
        return max(0, min(side, ((width - gaps) / CGFloat(count)).rounded(.down)))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let cell = width(proposal, subviews.count)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0
        return CGSize(width: cell * CGFloat(subviews.count) + gap * CGFloat(subviews.count - 1), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = width(proposal, subviews.count)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (cell + gap), y: bounds.minY), proposal: ProposedViewSize(width: cell, height: nil))
        }
    }
}

/// "等你"：固定在输入框上方，最早的那一条，收得紧。第一句是要你定什么，由代码按 Cue 写的动作短语写出
/// （`CueAsking.question`），不靠 Cue 的措辞；Cue 的原话默认收起，点"原话"再看（长了在里面滚）。下面是 Cue 点名要你看的图与各看什么
/// （`CueShots`，没点名的没有图；点开全屏时底栏就是这几个选项，看完当场定）、选项（`CueChoices`），末行是关联的任务与原话的开关
/// （Mac 上连同选项；辅助功能字号下各占一行），Mac 与手机同一结构；还有几条在等由页头与侧栏的"等你 N"说。卡上只能选：别的话在 Cue 页底下的输入框说，Cue 判断是在答这张就照办并撤回它。
/// 没有关掉：卡片一直挂着，直到你选一项或 Cue 撤回。
/// 列表与数量只来自 `cueMessagesWaitingForYou()`：回答后等库里那条结束才换下一条，写的时候按钮停用；没写成就报错、按钮恢复，可以再点。
struct CueWaitingDock: View {
    let waiting: [CueMessage]
    let tasks: [UUID: CueTaskRef]
    /// 提问点名的图（`CueThread.shots`）
    let shots: [UUID: [CueShown]]
    let open: (PreviewOpening) -> Void
    /// 卡正在升起、沉下或淡入淡出：这期间对话不另外往上滑（`ChatColumn` 的 `holding`），只跟着它让出的高挪，停了再滑一次。
    @Binding var moving: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.chatHeight) private var chatHeight
    /// 正在结束的那条（写成后它从 `waiting` 里消失，写不成就清掉）。
    @State private var ending: UUID?
    /// 展开了原话的那条：换下一条时自动收起。
    @State private var reading: UUID?
    /// 露出的那条：在等的第一条；答完沉下去的这一段里还是它（那时它已不在 `waiting` 里）。
    @State private var shown: CueMessage?
    /// 露出了多少，0…1：升起的比例（`RiseBehind`，0 是全藏在输入框后面）；减弱动态效果时是不透明度。
    @State private var level: CGFloat = 0

    /// 来了从输入框后面升起、答完沉回去（`RiseBehind`，露出的比例是状态、随曲线变：做成移除的过渡的话，沉回去那一下不动画，卡一帧就没了）；
    /// 一条换下一条时新卡在原地与旧卡交叉淡（底边对齐叠放，竖排的话两张同时占位、底栏一下高一倍）。减弱动态效果时只淡入淡出：
    /// 占的高跟着有没有在等的一下到位、卡浮着淡，对话只定位一次。占的高由对话让出（卡在浮着的回复框里，`FloatingReply`）。
    /// 卡与下面输入框的间距在卡里（`below`）：没有在等的时候这一层不占位，也不留出间距。
    var body: some View {
        ZStack(alignment: .bottom) {
            if let message = shown {
                // 只有换下一条时带动画（交叉淡）；头一张出现与沉完拿掉都不带，过渡不播
                card(waiting.first { $0.id == message.id } ?? message)
                    .id(message.id)
                    .transition(.opacity)
            }
        }
        .opacity(reduceMotion ? level : 1)
        .modifier(RiseBehind(shown: reduceMotion ? (waiting.isEmpty ? 0 : 1) : level, floats: reduceMotion, limit: chatHeight / 2))
        .onChange(of: waiting.first?.id, initial: true) { old, new in follow(animated: old != new) }
    }

    private static let below: CGFloat = 8

    /// 跟上在等的第一条：来了升起，没了沉下去、沉完再拿掉，换了一条原地交替；减弱动态效果时来去都只淡。
    /// 升起用无回弹弹簧、从卡排进去的下一帧起播：卡插进来那一帧排版重，从这一帧起算的话前几十毫秒被吃掉，看着是冒一点、停一下、窜一大截。
    /// 沉下用定长曲线（`Motion.move`）：弹簧最后那段一两点的尾巴要再画上百毫秒，沉到底前卡剩一道细线停在输入框上（升起的尾巴停在整高处，看不见）。
    /// 减弱动态效果时淡入稍慢、淡出要快：淡出时对话已在终位，卡叠在字上的那几帧越短越好。
    private func follow(animated: Bool) {
        guard let next = waiting.first else {
            guard shown != nil else { return }
            guard animated else { return leave() }
            move(to: 0, reduceMotion ? .easeOut(duration: Motion.handOff) : Motion.move) { if waiting.isEmpty { leave() } }
            return
        }
        let swapping = shown != nil
        withAnimation(swapping && animated ? Motion.quick : nil) { shown = next }
        guard animated, level < 1 else { return level = 1 }
        moving = true
        Task {
            await NextFrame.wait()
            guard shown?.id == next.id else { return moving = false }
            move(to: 1, reduceMotion ? Motion.quick : Motion.snappy)
        }
    }

    /// 播一段卡的来去，播着的时候 `moving`；动画走完再收尾。沉到一半又来了一条时前一段被接走，它的收尾不算数（目标已经变了）。
    private func move(to target: CGFloat, _ animation: Animation, then done: @escaping () -> Void = {}) {
        moving = true
        withAnimation(animation, completionCriteria: .removed) { level = target } completion: {
            guard level == target else { return }
            moving = false
            done()
        }
    }

    /// 拿掉：沉到底或淡没了，这时已看不见，不再播过渡。
    private func leave() {
        shown = nil
        level = 0
    }

    /// 从上到下：问句（规矩那一类下面是规矩原话）、一排图、操作。卡至多占对话区可见高的一半（`RiseLayout`），放不下时上面那段在卡里滚，
    /// 操作钉在卡底、一直露着。手机上选项一行、任务与原话一行（辅助功能字号下各占一行）；Mac 上合成一行，右下角是"可以"。
    private func card(_ message: CueMessage) -> some View {
        let ref = message.taskID.flatMap { tasks[$0] }
        let choices = CueChoices(options: message.choices ?? [], disabled: ending == message.id) { answer(message, $0) }
        let upper = VStack(alignment: .leading, spacing: 0) {
            CueQuestionLine(message: message)
            if reading == message.id { original(message.text).padding(.top, 12).transition(.opacity) }
            if let shots = shots[message.id] {
                CueShots(shots: shots, group: "waiting", reply: .answer(message), open: open).padding(.top, 16)
            }
        }
        .padding([.top, .horizontal], 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        let actions = footer(message, ref, choices).padding(.top, 12)
        #else
        let actions = VStack(alignment: .leading, spacing: 0) {
            choices.padding(.top, 16)
            if typeSize.isAccessibilitySize {
                // 任务至多两行、不截断
                VStack(alignment: .leading, spacing: 0) {
                    if let ref { CueTaskLine(ref: ref, height: Self.footerHeight, lines: 2) }
                    originalToggle(message)
                }
                .padding(.top, 4)
            } else {
                footer(message, ref, nil).padding(.top, 4)
            }
        }
        #endif
        return VStack(spacing: 0) {
            ViewThatFits(in: .vertical) {
                upper
                ScrollView { upper }.scrollBounceBehavior(.basedOnSize)
            }
            // 下边距小：末行自带可点的高，字离卡底看着与上边距差不多
            actions.padding(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16)).layoutPriority(1)
        }
        .paper(radius: ComposerMetrics.radius, lifted: true)
        .animation(Motion.quick, value: reading)
        .padding(.bottom, Self.below)
    }

    /// 末行（任务、原话；Mac 上连同选项）可点的高。
    private static let footerHeight: CGFloat = 44

    /// 末行：任务在左；带选项时（Mac）原话紧跟任务（间距 20）、选项在尾端，不带时原话在右端。
    private func footer(_ message: CueMessage, _ ref: CueTaskRef?, _ choices: CueChoices?) -> some View {
        HStack(spacing: 0) {
            if let ref {
                CueTaskLine(ref: ref, height: Self.footerHeight).accessibilitySortPriority(1).padding(.trailing, choices == nil ? 10 : 20)
            }
            if let choices {
                originalToggle(message)
                Spacer(minLength: 16)
                choices.accessibilitySortPriority(2)
            } else {
                Spacer(minLength: 0)
                originalToggle(message)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Cue 的原话：整段排在问句下面，长了随卡里那段一起滚。
    private func original(_ text: String) -> some View {
        MarkdownText(source: text).equatable().font(Typography.secondary).foregroundStyle(palette.ink2)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func originalToggle(_ message: CueMessage) -> some View {
        let open = reading == message.id
        return Button { reading = open ? nil : message.id } label: {
            HStack(spacing: 4) {
                Text("原话")
                Image(.expand).font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
            .frame(minHeight: Self.footerHeight).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(open ? "收起原话" : "看 Cue 的原话")
    }

    private func answer(_ message: CueMessage, _ choice: String) {
        ending = message.id
        workspace.attempt {
            defer { ending = nil }
            try await workspace.answerCueQuestion(message, choice)
        }
    }
}

/// "等你"卡从输入框后面升起、沉回去：占的高随曲线从 0 长到整高（沉回去反过来），卡不透明、顶边跟着上来，没露出的下半截裁在输入框后面。
/// 占的高本身在变，底栏、对话让出的地方（手机是安全区，Mac 是浮着的回复框）与卡每一帧都是同一个高：
/// 只动卡（淡入、平移）的话底栏当帧就是整高，对话先一下被顶开、空着等卡补进来，沉下时对话又从半透明的卡底下穿过。
/// 代价是这 0.25 秒里底栏每帧排一次，对话只跟着挪偏移。
private struct RiseBehind: ViewModifier, Animatable {
    /// 露出的比例，0 是全藏在输入框后面。
    var shown: CGFloat
    /// 浮着（减弱动态效果）：不裁，占的高为 0 时卡往上浮在对话上（淡入淡出时用）。
    let floats: Bool
    /// 卡至多这么高（对话区可见高的一半），再高在卡里滚。
    let limit: CGFloat

    var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }

    func body(content: Content) -> some View {
        if floats {
            RiseLayout(shown: shown, floats: true, limit: limit) { content }
        } else {
            RiseLayout(shown: shown, floats: false, limit: limit) { content }
                // 两边与上面让出卡的影子（随露出的比例收，藏到底时一点不留）；下沿一直往输入框里伸进一个圆角那么深：输入框（实底玻璃，
                // 排在卡上面）圆角外那一小块里看得到卡沉到它后面，不被一条直线齐齐切断，停稳时影子也连着。卡与输入框同一个圆角、
                // 只窄一点，藏到底时卡的上沿整个在输入框的轮廓里
                .mask {
                    Rectangle()
                        .padding([.horizontal, .top], -RiseBehind.shadowRoom * shown)
                        .padding(.bottom, -ComposerMetrics.radius)
                }
        }
    }

    private static let shadowRoom: CGFloat = 24
}

/// 按露出的比例占高，孩子按整高顶对齐排：顶边随占的高上下，下半截在外面；浮着时底对齐，多出的往上浮。
private struct RiseLayout: Layout {
    let shown: CGFloat
    let floats: Bool
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        // 孩子只按 `limit` 排，不看给的高：升起时外面按缩了的高（整高 × 露出的比例）回头再排一次，
        // 照给的高排的话卡里那段就当成放不下、换成滚动的，尾段停下前截掉一截
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: limit))
        // 宽照给的：卡拿掉的那一刻孩子没了，宽跟着塌成 0 的话，裁的窗口两边让出的影子位就成了一小块露在输入框上
        return CGSize(width: proposal.width ?? size.width, height: size.height * shown)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width, height: limit))
        let origin = floats ? CGPoint(x: bounds.minX, y: bounds.maxY - size.height) : bounds.origin
        child.place(at: origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: limit))
    }
}

