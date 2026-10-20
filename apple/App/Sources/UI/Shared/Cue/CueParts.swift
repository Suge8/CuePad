import CueStore
import CueText
import SwiftUI

/// 打开一件任务（Cue 页里提到的那一行、"等你"关联的任务）：从点的地方长出任务气泡（`Workspace.openTask`）。
struct CueTaskButton<Label: View>: View {
    let task: UUID
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button(action: open) { label.contentShape(.rect) }
            .buttonStyle(PressStyle(.card))
    }

    private func open() { workspace.openTask(id: task) }
}

/// 还没启用时 Cue 页输入框上方的那一块，两端同一个：只放启用这一步，启用后怎么用由 Cue 页空态那一句说（同一屏不说两遍）。选一台 Mac 启用（能运行 Cue 的几台，`CueSettings.hosts`）——
/// 一台就是一颗"在那台上启用"的主按钮；几台是点开选哪台的菜单（`MenuButton`，每台下面写能当大脑的几家或为什么不能用），
/// Mac 上点按是在这台运行、长按选别的。在这台 Mac 上启用打开接入面板（`SetupPanel`：先检测、接入这台的 Agent，一家都没装时给装法，
/// 同一下启用），别的 Mac 直接启用，没写成的原因就地写在下面（`CueSettingsModel`）。手机上还没有哪台 Mac 写下过自己时，
/// 说先到 Mac 上打开 CuePad。没启用时输入框发出去是记下灵感。
struct CueEnableCard: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var model = CueSettingsModel()

    var body: some View {
        let hosts = (model.settings ?? .empty).hosts(here: workspace.localHost)
        VStack(alignment: .leading, spacing: 10) {
            if hosts.isEmpty {
                Label(CueSettings.noHost, icon: .mac)
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

    private func enable(on host: String) {
        #if os(macOS)
        guard host != workspace.localHost else {
            workspace.showsSetup = true
            return
        }
        #endif
        model.enable(on: host, services)
    }

    @ViewBuilder private func enableButton(_ hosts: [CueSettings.Host]) -> some View {
        let here = workspace.localHost
        if hosts.count == 1, let host = hosts.first {
            Button(title(host)) { enable(on: host.id) }
                .buttonStyle(ControlButtonStyle(kind: .primary))
        } else {
            MenuButton(
                sections: [ChoiceMenu.Section(choices: hosts.map { host in
                    ChoiceMenu.Choice(title: host.name, subtitle: host.note.isEmpty ? nil : host.note, image: .icon(.mac)) {
                        enable(on: host.id)
                    }
                })],
                primary: here.map { here in { enable(on: here) } },
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
        host.id == workspace.localHost ? "在这台 Mac 上启用" : "在「\(host.name)」上启用"
    }
}

/// 一件活收成一行（对话里 Cue 的话下面、"等你"里关联的那件）：任务圈、标题、步骤数，点它打开任务；行尾是这件活交给的会话的状态标
/// （`AgentDot`：正在开会话、在跑、等你……，点它看那个会话；没交出去不画）。Cue 交给会话时接力落在这一行（圈与状态标都挂着锚，`CueRelayStage`），
/// 落下后状态标自己换成会话的真实状态。
struct CueTaskLine: View {
    /// 平时可点的高（对话里、结果卡里）；Cue 页数格子时按它算那一行至少多高（`CuePage.floor`）。
    static let lineHeight: CGFloat = 24

    let ref: CueTaskRef
    /// 可点的高（"等你"卡的末行撑满 44）
    var height = CueTaskLine.lineHeight
    /// 标题至多几行（"等你"卡在辅助功能字号下两行）
    var lines = 1
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            CueTaskButton(task: ref.task.id) {
                HStack(spacing: 6) {
                    TaskRingView(status: ref.task.status, done: ref.done, size: 13).relaySpot(task: ref.task.id)
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
            if !ref.done { AgentDot(card: ref.task.id).padding(.vertical, -2) }
        }
    }
}

/// 连着的几轮 Cue 自己醒来（`CueThread.Row.notes`）：靠左的一颗虚线气泡，形状同 Cue 的气泡（`CueBubble.shape`），只描边不铺底——
/// 是它说的话，但没推给你，与纸做的实底气泡（对你说的）一眼分开。每轮一节（`CueNoteSection`）：第一行为什么醒与几点，下面是它说的话（小一档的次要墨色），
/// 调过工具的再一行经过（`RoundProcess`，设置里关了工具步骤时没有；在跑的那一轮总有，写此刻在做的）。做完了、只看了看、没说话的一轮只占一行"…… · 没动手"，
/// 连着几次并成一行"看了 N 次，都没动手"；在跑的那一轮还不算（它随时会动手、说话，算了就要在并起来与分开之间来回跳）。
/// 超过 `foldAfter` 节时只露最近 `shownWhenFolded` 节，上面一行"更早还醒过 N 次"，点它或点并起来的那一行原地全部展开（各节分开列）。
struct CueNoteBubble: View {
    let rounds: [CueNoteRound]
    /// 在跑的那一轮在这几节里时有（`CueLiveRound`）
    let live: CueLiveRound?
    @State private var expanded = DebugHooks.preset.toolsOpen
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 多于这么多节（并起来的没动手算一节）才折
    static let foldAfter = 4
    static let shownWhenFolded = 3

    /// 气泡里的一节：一轮，或连着几轮没动手的并成的一行。
    enum Unit: Identifiable {
        case round(CueNoteRound)
        case quiet([CueNoteRound])

        var id: UUID {
            switch self {
            case .round(let round): round.id
            case .quiet(let rounds): rounds[0].id
            }
        }

        var count: Int {
            switch self {
            case .round: 1
            case .quiet(let rounds): rounds.count
            }
        }
    }

    var body: some View {
        let units = expanded ? rounds.map(Unit.round) : Self.merged(rounds, live: live?.round)
        let folded = !expanded && units.count > Self.foldAfter
        let shown = folded ? Array(units.suffix(Self.shownWhenFolded)) : units
        BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
            VStack(alignment: .leading, spacing: Self.sectionGap) {
                if folded {
                    let earlier = units.dropLast(Self.shownWhenFolded).reduce(0) { $0 + $1.count }
                    Button { expanded = true } label: {
                        NoteLine(icon: .earlier) { Text("更早还醒过 \(earlier) 次") }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(shown) { unit in
                    switch unit {
                    case .round(let round): CueNoteSection(round: round, live: live)
                    case .quiet(let rounds):
                        // 图标与几点是最近那次的
                        Button { expanded = true } label: {
                            NoteLine(icon: rounds[rounds.count - 1].header?.wake.icon ?? .wakeIdle, open: false, time: rounds[rounds.count - 1].date) {
                                Text("看了 \(rounds.count) 次，都没动手")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(CueBubble.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { CueBubble.shape(.leading).strokeBorder(palette.noteEdge, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            .contentShape(CueBubble.shape(.leading))
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: expanded)
        .transition(.entry)
    }

    #if os(macOS)
    static let sectionGap: CGFloat = 12
    #else
    static let sectionGap: CGFloat = 14
    #endif

    /// 连着几轮没动手并成一节；只有一轮的照常一节。
    static func merged(_ rounds: [CueNoteRound], live: UUID?) -> [Unit] {
        var units: [Unit] = [], run: [CueNoteRound] = []
        func flush() {
            if run.count == 1 { units.append(.round(run[0])) } else if !run.isEmpty { units.append(.quiet(run)) }
            run = []
        }
        for round in rounds {
            if round.quiet(live: live) { run.append(round) } else {
                flush()
                units.append(.round(round))
            }
        }
        flush()
        return units
    }
}

/// 虚线气泡里的一轮：为什么醒（`CueWakeTitle`），它说的话，调过工具的一行经过。旧的动态没有醒来原因，只有说的话。
private struct CueNoteSection: View {
    let round: CueNoteRound
    let live: CueLiveRound?
    @Environment(\.palette) private var palette

    var body: some View {
        let indent = round.header == nil ? 0 : Note.glyphWidth + Note.spacing
        VStack(alignment: .leading, spacing: 3) {
            if let header = round.header { CueWakeTitle(header: header, at: round.date, quiet: round.quiet(live: live?.round)) }
            ForEach(round.said) { note in
                Text(CueFormat.plainText(note.text)).font(Typography.secondary).foregroundStyle(palette.ink2)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, indent)
            if let row = round.row, row.tools != nil || row.id == live?.round {
                RoundProcess(tools: row.tools, ending: CueLiveRound.ending(of: row, in: live)).padding(.leading, indent)
            }
        }
    }
}

/// 一节的第一行（`NoteLine`，同并起来的那一行）：醒来原因的图标（叫醒它的会话出错是出错的那个）、原因（叫醒它的会话、任务、提醒是墨色的名字，点了去那里；
/// 几处时点开列出来选），行末几点。只看了看的一轮在后面接"· 没动手"。
private struct CueWakeTitle: View {
    let header: CueWakeHeader
    let at: Date
    var quiet = false
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        NoteLine(time: at) {
            if header.failed { FailureMark() } else { Image(header.wake.icon) }
        } label: {
            reason
        }
    }

    /// 名字太长时只截名字，前后的话留全。
    private var words: some View {
        HStack(spacing: 4) {
            if let lead = header.lead { Text(lead).foregroundStyle(palette.ink2).fixedSize() }
            if header.lead != nil, header.name != nil { Dot().foregroundStyle(palette.ink3) }
            if let name = header.name { Text(name).fontWeight(.medium).foregroundStyle(palette.ink) }
            if let trail = header.trail { Text(trail).foregroundStyle(palette.ink2).fixedSize() }
            if !header.targets.isEmpty { Image(.forward).font(.system(size: 8, weight: .semibold)).foregroundStyle(palette.ink3) }
            if quiet {
                Dot().foregroundStyle(palette.ink3)
                Text("没动手").foregroundStyle(palette.ink3).fixedSize()
            }
        }
        .lineLimit(1)
    }

    @ViewBuilder private var reason: some View {
        let label = words.contentShape(.rect)
        switch header.targets.count {
        case 0: label
        case 1: Button { open(header.targets[0].target) } label: { label }.buttonStyle(.plain)
        default:
            Menu {
                ForEach(header.targets, id: \.title) { place in Button(place.title) { open(place.target) } }
            } label: { label }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        }
    }

    private func open(_ target: CueWakeHeader.Target) {
        switch target {
        case .session(let session):
            #if os(macOS)
            workspace.show(.session(session.sessionID))
            #else
            navigation.openSession(session.id, sessionID: session.sessionID, store: services.store)
            #endif
        case .task(let id):
            workspace.openTask(id: id)
        case .memory:
            workspace.cue.showsMemory = true
        }
    }
}

extension CueWake {
    /// 醒来原因的图标（Cue 页那一节的第一行、Mac 的运行情况）。
    var icon: Icon {
        switch self {
        case .enabled: .wakeEnabled
        case .message: .wakeMessage
        case .sessionActivity: .wakeActivity
        case .idle: .wakeIdle
        case .reminder: .wakeReminder
        case .renewed: .renew
        case .settingsChanged: .wakeSettings
        }
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


/// Cue 说的一句：靠左的一颗纸做的气泡（`cueBubble`），里面是 Markdown（同会话里 Agent 的回答），下面是它点名的图（`CueShots`：结束了回到问的位置的提问，
/// 你的回答在答的那一刻另成一格，见 `CueAnswer`、`CueThread.rows`）；它第一次提到一件活时底下一行这件活（`CueTaskLine`）。
/// `card`：结果卡（点名了图的做完，哪句算只在 `CueThread.rows` 定）——不是气泡而是一张纸（`paper`），不与上下的气泡连成一串；
/// 第一行是一句平常的话时（"「X」做完了"）单独加粗作标题，一眼先读到做完了什么，再看证据与图。
/// 长按（Mac 右键）是消息菜单（`MessageMenu.Kind.cue`），预览就是这颗气泡或这张纸。
struct CueSays: View {
    let message: CueMessage
    var task: CueTaskRef?
    /// Cue 点名的图（`CueThread.shots`）与点开一张：全屏左右翻的就是这几张，底栏是关于它对 Cue 说
    var shots: [CueShown] = []
    var open: (PreviewOpening) -> Void = { _ in }
    var card = false
    /// 上面紧挨着 Cue 的另一句（`CueBubble.shape`）。
    var joined = false
    /// 新到的从左下角长出来；原位换下正在说的话时（`CueEnding`）直接出现
    var arrives = true
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selecting = false

    var body: some View {
        BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
            VStack(alignment: .leading, spacing: card ? 12 : 8) {
                words
                if !shots.isEmpty { CueShots(shots: shots, group: message.id.uuidString, reply: .cue, open: open) }
                if let task { CueTaskLine(ref: task) }
            }
            .modifier(CueSaysSurface(card: card, joined: joined))
            .contextMenu { MessageActions(text: message.text, kind: .cue, selectText: { selecting = true }) }
        }
        #if os(iOS)
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
        #endif
        .transition(arrives ? CueBubble.arrival(.leading, reduceMotion: reduceMotion) : .identity)
    }

    @ViewBuilder private var words: some View {
        let parts: (title: String?, body: String) = card ? Self.headline(message.text) : (nil, message.text)
        if let title = parts.title {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.inline(title)).font(Typography.reading.weight(.semibold)).foregroundStyle(palette.ink)
                    .lineSpacing(Typography.readingLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                if !parts.body.isEmpty { MarkdownText(source: parts.body).equatable() }
            }
        } else {
            MarkdownText(source: parts.body).equatable()
        }
    }

    /// 第一行是平常的一句话（不是标题、列表、引用、代码、表格）时拆出来作标题，其余是正文。
    private static func headline(_ text: String) -> (title: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first.map(String.init), !first.isEmpty, !Self.isMarkup(first) else { return (nil, trimmed) }
        let rest = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (first, rest)
    }

    /// 标题行里的行内记号（粗体、代码、链接）照样认，不露出星号与反引号。
    private static func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
    }

    private static func isMarkup(_ line: String) -> Bool {
        if ["#", "-", "*", "+", ">", "`", "|", "!["].contains(where: line.hasPrefix) { return true }
        return line.prefix { $0.isNumber }.count > 0 && line.drop { $0.isNumber }.hasPrefix(".")
    }
}

/// `CueSays` 的底：气泡（`cueBubble`），或结果卡的一张纸；长按的预览照这个形状裁。
private struct CueSaysSurface: ViewModifier {
    let card: Bool
    let joined: Bool

    func body(content: Content) -> some View {
        if card {
            content.padding(CueBubble.padding).frame(maxWidth: .infinity, alignment: .leading).paper(radius: CueBubble.radius)
                #if os(iOS)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: CueBubble.radius, style: .continuous))
                #endif
        } else {
            content.cueBubble(joined: joined)
                #if os(iOS)
                .contentShape(.contextMenuPreview, CueBubble.shape(.leading, joined: joined))
                #endif
        }
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

/// "等你"的选项：只有第一项"可以"是实底主按钮（全卡唯一的靛青），其余（"以后……不用问"）是无底色的文字按钮。"等你"卡、任务看板的等你卡与全屏预览的底栏共用。
/// `stacks`（手机上一律，Mac 上任务看板的窄卡）：竖排——"可以"铺满一行在上，文字按钮在它下面居中、长了折行。摆法不随选项的字长变：
/// "以后「项目」里……不用问"带着项目名，长短不一，按放不放得下挑横竖时并排的两张卡会一横一竖；主按钮也总在同一处、最好按。
/// 不竖排时（Mac 的 Cue 页与预览底栏，地方宽）文字按钮在"可以"左边、排在一行尾端，"可以"不窄过 `onceWidth`；一行放不下或辅助功能字号时照样竖排、按字宽收着。
struct CueChoices: View {
    let options: [String]
    var disabled = false
    var stacks = Self.stacksByDefault
    let pick: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    #if os(macOS)
    static let onceWidth: CGFloat = 96
    private static let stacksByDefault = false
    private static let stackGap: CGFloat = 4
    #else
    static let onceWidth: CGFloat = 88
    private static let stacksByDefault = true
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
        // 不铺满时竖排也按字宽收着（"可以"与文字按钮同宽）
        .fixedSize(horizontal: !stacks, vertical: false)
        if others.isEmpty {
            button(once, kind: .primary, fill: stacks, minWidth: Self.onceWidth)
        } else if stacks || typeSize.isAccessibilitySize {
            stacked
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(others, id: \.self) { button($0, kind: .quiet).lineLimit(1).fixedSize() }
                    button(once, kind: .primary, minWidth: Self.onceWidth).lineLimit(1)
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

/// Cue 点名要你看的图（提问卡与结果卡，`CueShown`，至多 `CueShot.limit` 张），按 Cue 给的先后：一排靠左、一行排完不横滑，每张同样大的方形缩略图
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
    fileprivate static let gap = PreviewBatch.gap

    /// 在 `width` 宽里排 `count` 张时每张的边长（`ShotRow` 照它排）：放得下是 `side`，不然几张平分。
    static func cell(count: Int, width: CGFloat) -> CGFloat {
        let gaps = gap * CGFloat(count - 1)
        guard width.isFinite else { return side }
        return max(0, min(side, ((width - gaps) / CGFloat(count)).rounded(.down)))
    }

    /// 这一块至少多高（Cue 页数格子，`CuePage.floor`）：图的边长，不算下面那句说明，只能数少。
    static func floor(count: Int, width: CGFloat) -> CGFloat { count == 0 ? 0 : cell(count: count, width: width) }

    var body: some View {
        ShotRow {
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

/// 一排等宽的格，靠左、顶端对齐、一行排完不横滑：格宽是 `CueShots.cell`。
private struct ShotRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let cell = CueShots.cell(count: subviews.count, width: proposal.width ?? .infinity)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0
        return CGSize(width: cell * CGFloat(subviews.count) + CueShots.gap * CGFloat(subviews.count - 1), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = CueShots.cell(count: subviews.count, width: proposal.width ?? .infinity)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (cell + CueShots.gap), y: bounds.minY), proposal: ProposedViewSize(width: cell, height: nil))
        }
    }
}

/// "等你"：固定在输入框上方，最早的那一条，收得紧。第一句是要你定什么，由代码按 Cue 写的动作短语写出
/// （`CueAsking.question`），不靠 Cue 的措辞；Cue 的原话默认收起，点"原话"再看（长了在里面滚）。下面是 Cue 点名要你看的图与各看什么
/// （`CueShots`，没点名的没有图；点开全屏时底栏就是这几个选项，看完当场定）、选项（`CueChoices`），末行是关联的任务与原话的开关
/// （Mac 上连同选项；辅助功能字号下各占一行），Mac 与手机同一结构；还有几条在等由页头与侧栏的"等你 M"说。卡上只能选：别的话在 Cue 页底下的输入框说，
/// 一开口卡就收起（Cue 判断不是在答它会放回，见 `CueQuestionEnd`）。没有关掉。
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
    @State private var level: CGFloat

    /// 页打开时已经在等的那张随页一起排出来、不升起（同 `follow` 的头一次）：等 `onChange` 再放的话卡晚一次更新才排，
    /// 对话按它让出的高又要重排一遍。
    init(waiting: [CueMessage], tasks: [UUID: CueTaskRef], shots: [UUID: [CueShown]], open: @escaping (PreviewOpening) -> Void, moving: Binding<Bool>) {
        self.waiting = waiting
        self.tasks = tasks
        self.shots = shots
        self.open = open
        _moving = moving
        _shown = State(initialValue: waiting.first)
        _level = State(initialValue: waiting.isEmpty ? 0 : 1)
    }

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
    /// 卡的内边距：下边小，末行自带可点的高，字离卡底看着与上边距差不多。
    private static let padding = EdgeInsets(top: 16, leading: 16, bottom: 6, trailing: 16)

    #if os(macOS)
    /// 卡至少多高（Cue 页打开时数要排几格，`CuePage.covered`）：内边距与卡底的间距、问句（至少一行标题字）、带图时一排图
    /// （`CueShots.floor`，卡宽 `width` 去掉两边内边距）、末行（`footerHeight`）；原话收着。只能数少。
    static func floor(_ message: CueMessage, shots: [UUID: [CueShown]], width: CGFloat) -> CGFloat {
        let pictures = shots[message.id].map { 16 + CueShots.floor(count: $0.count, width: width - padding.leading - padding.trailing) } ?? 0
        return padding.top + Typography.titleSize + pictures + footerGap + footerHeight + padding.bottom + below
    }
    #endif

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

    /// 从上到下：问句（规矩那一类下面是规矩原话）、一排图、操作。卡至多占对话区可见高的一半，地方不够时只用剩下的（`RiseLayout`）。
    /// Mac 上放不下时上面那段在卡里滚、操作钉在卡底。手机上（键盘弹出、小屏、横屏）按能放下的挑（`ViewThatFits`，按各自的实际高）：
    /// 整张 → 紧凑（去掉那排图；问句与选项钉住，展开的原话在中间滚，末行放得下才露）→ 只剩问句一行（`folded`）。
    /// 紧凑那档的理想高只算问句与选项（原话与末行都是 `Yielding`），所以"问句加选项都放不下"才收成一行；哪一档都不会截出半截字或半张图。
    /// 放得下时不进滚动区：滚动区里的按钮按下要晚一下才有反馈。Mac 上不挑（挑的话几份都要建，第一次打开 Cue 页时卡多建一遍）。
    /// 手机上选项竖排（`CueChoices`）、下面任务与原话一行（辅助功能字号下各占一行）；Mac 上合成一行，右下角是"可以"。
    private func card(_ message: CueMessage) -> some View {
        let ref = message.taskID.flatMap { tasks[$0] }
        let choices = CueChoices(options: message.choices ?? [], disabled: ending == message.id) { answer(message, $0) }
        let side = Self.padding.leading
        #if os(macOS)
        let body = VStack(spacing: 0) {
            Yielding { ScrollView { upper(message, shots: true) }.scrollBounceBehavior(.basedOnSize) }
            footer(message, ref, choices).padding(.top, Self.footerGap)
                .padding(.horizontal, side).padding(.bottom, Self.padding.bottom).layoutPriority(1)
        }
        #else
        let choicesRow = choices.padding(.top, 16).padding(.horizontal, side)
        let footerRow = Group {
            if typeSize.isAccessibilitySize {
                // 任务至多两行、不截断
                VStack(alignment: .leading, spacing: 0) {
                    if let ref { CueTaskLine(ref: ref, height: Self.footerHeight, lines: 2) }
                    originalToggle(message)
                }
            } else {
                footer(message, ref, nil)
            }
        }
        .padding(.top, 4).padding(.horizontal, side)
        let body = ViewThatFits(in: .vertical) {
            VStack(spacing: 0) {
                upper(message, shots: true)
                choicesRow
                footerRow
            }
            .padding(.bottom, Self.padding.bottom)
            VStack(spacing: 0) {
                CueQuestionLine(message: message).padding(.top, Self.padding.top).padding(.horizontal, side)
                if reading == message.id {
                    Yielding { ScrollView { original(message.text).padding(.top, 12).padding(.horizontal, side) }.scrollBounceBehavior(.basedOnSize) }
                }
                choicesRow
                Yielding { ViewThatFits(in: .vertical) { footerRow; Color.clear.frame(height: 0) } }
            }
            .padding(.bottom, Self.padding.bottom)
            folded(message)
        }
        #endif
        return body
            .paper(radius: ComposerMetrics.radius, lifted: true)
            .animation(Motion.quick, value: reading)
            .padding(.bottom, Self.below)
    }

    #if os(iOS)
    /// 连紧凑的样子都放不下（横屏弹着键盘）：整张卡收成问句一行，放不下的用省略号。点它收起键盘，地方够了卡就按上面的挑法展开。
    private func folded(_ message: CueMessage) -> some View {
        Button {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } label: {
            HStack(spacing: 9) {
                PiStateGlyph(status: .asking).font(Typography.title)
                Text(message.headline ?? "").font(Typography.title).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Self.padding.leading)
            .frame(minHeight: Self.footerHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("收起键盘，展开这张卡")
    }
    #endif

    /// 卡里上面那段：问句、展开的原话、一排图（`shots` 为 false 是紧凑的样子，不带图）。
    private func upper(_ message: CueMessage, shots showsShots: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CueQuestionLine(message: message)
            if reading == message.id { original(message.text).padding(.top, 12).transition(.opacity) }
            if showsShots, let shots = shots[message.id] {
                CueShots(shots: shots, group: "waiting", reply: .answer(message), open: open).padding(.top, 16)
            }
        }
        .padding(.top, Self.padding.top).padding(.horizontal, Self.padding.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
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
    #if os(macOS)
    /// 末行离上面的问句与图。
    private static let footerGap: CGFloat = 12
    #endif

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
            try await workspace.services.answerCueQuestion(message.id, choice)
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
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: room(proposal.height)))
        // 宽照给的：卡拿掉的那一刻孩子没了，宽跟着塌成 0 的话，裁的窗口两边让出的影子位就成了一小块露在输入框上
        return CGSize(width: proposal.width ?? size.width, height: size.height * shown)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let fit = ProposedViewSize(width: bounds.width, height: room(proposal.height))
        let size = child.sizeThatFits(fit)
        let origin = floats ? CGPoint(x: bounds.minX, y: bounds.maxY - size.height) : bounds.origin
        child.place(at: origin, anchor: .topLeading, proposal: fit)
    }

    /// 孩子按整高排：至多 `limit`，外面给的不够时（输入框先拿走它的高，剩下的不到 `limit`）只到给的。给的是露出的那截，
    /// 除以露出的比例换回整高：升起时外面按缩了的高回头再排一次，照给的高直接排的话卡里那段就当成放不下、换成紧凑的。
    /// 向上取整：除回来的小数比整高少一点点也会被当成放不下。
    private func room(_ offered: CGFloat?) -> CGFloat {
        guard let offered, shown > 0 else { return limit }
        return min(limit, (offered / shown).rounded(.up))
    }
}

/// 地方不够时先让的一段：给了高时按里面的理想高（滚动区是它内容的高）、至多到给的高（滚动区本身会占满给的高，留下一截空白）；
/// 量理想高时（`ViewThatFits` 挑哪一档、外面不给高）不占高，所以它放不放得下不影响挑哪一档。
private struct Yielding: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: proposal.height.map { min(ideal.height, $0) } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
