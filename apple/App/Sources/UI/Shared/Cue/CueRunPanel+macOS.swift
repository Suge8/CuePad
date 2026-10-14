#if os(macOS)
import CueAgent
import CueStore
import SwiftUI

/// Cue 页右侧的"运行情况"（给开发者看，默认关着，从"⋯"里打开，`CueWatch.showsRun`）：上面是上下文——用了多少、换新线在哪、还差多远、
/// 本班次几点起、上次几点换新（点开看交接备忘）；下面是最近几轮，新的在上：每轮一行为什么醒、几点、用时、调了几次工具，
/// 点开是交给大脑的话与工具清单（清单的行与会话里回答注脚的清单同一个 `ToolRow`），清单的一条再点开是参数与结果的全文。
/// 只读值班的管理器（`CueKeeper.rounds`、`context`）与库里的交接备忘；Cue 不在这台 Mac 值班时没有这一栏。
struct CueRunPanel: View {
    let keeper: CueKeeper
    let handoff: CueMessage?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    /// 点过的轮记下开合；没点过的只有最新的一轮开着
    @State private var opened: [Int: Bool] = [:]

    static let width: CGFloat = 360

    var body: some View {
        let rounds = keeper.rounds
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("运行情况").font(Typography.sectionTitle).foregroundStyle(palette.ink)
                Spacer()
                Button("收起", systemImage: "xmark") { workspace.cue.showsRun = false }
                    .labelStyle(.iconOnly).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink3)
                    .frame(width: 28, height: 28).contentShape(.rect)
                    .buttonStyle(PressStyle(.button))
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CueContextCard(context: keeper.context, shiftStartedAt: keeper.shiftStartedAt, handoff: handoff)
                    Text(Dotted("最近几轮", rounds.isEmpty ? nil : "\(rounds.count)"))
                        .font(Typography.label).foregroundStyle(palette.ink3)
                    if rounds.isEmpty {
                        Text("还没醒过").font(Typography.meta).foregroundStyle(palette.ink3)
                    }
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(rounds.reversed()) { round in
                            let newest = round.id == rounds.last?.id
                            CueRoundRow(round: round, expanded: Binding { opened[round.id] ?? newest } set: { opened[round.id] = $0 })
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .glass(in: .rect(cornerRadius: PiReplyBar.radius, style: .continuous))
    }
}

// MARK: 上下文

/// 上下文：大字写已用，一条刻度尺量到窗口（不知道窗口时量到换新线往后一截），换新线是尺上的一道刻线；
/// 用到换新线的七成、九成按会话上下文同一口径加深与转胭脂（`PiContextMeter.level`）。
private struct CueContextCard: View {
    let context: (used: Int, window: Int?)?
    let shiftStartedAt: Date?
    let handoff: CueMessage?
    @Environment(\.palette) private var palette
    @State private var showsHandoff = false

    private let renewAt = CueKeeper.renewAt

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("上下文").font(Typography.label).foregroundStyle(palette.ink3)
                Spacer()
                Text(context.map { CueEnvelope.tokens($0.used) } ?? "—")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(palette.ink)
                Text("/ \(CueEnvelope.tokens(renewAt))").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
            }
            RenewRuler(used: context?.used ?? 0, renewAt: renewAt, window: context?.window)
            Text(distance).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2)
            VStack(alignment: .leading, spacing: 6) {
                fact("本班次", shiftStartedAt.map { "\(CueRunFormat.clock($0)) 起" } ?? "没在跑")
                handoffLine
            }
        }
        .padding(14)
        .background(palette.fill, in: ChatBlock.shape)
        .animation(Motion.quick, value: context?.used)
    }

    private var distance: Dotted {
        guard let used = context?.used else { return "这个班次还没请求过模型" }
        let window = context?.window.map { "窗口 \(CueEnvelope.tokens($0))" }
        let left = used < renewAt
            ? "离换新线还差 \(CueEnvelope.tokens(renewAt - used))" : "过了换新线 \(CueEnvelope.tokens(used - renewAt))，下一次醒来先写交接"
        return Dotted(left, window)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(palette.ink3).frame(width: 56, alignment: .leading)
            Text(value).foregroundStyle(palette.ink2)
        }
        .font(Typography.meta.monospacedDigit())
    }

    @ViewBuilder private var handoffLine: some View {
        if let handoff {
            VStack(alignment: .leading, spacing: 6) {
                Button { withAnimation(Motion.quick) { showsHandoff.toggle() } } label: {
                    HStack(spacing: 8) {
                        Text("上次换新").foregroundStyle(palette.ink3).frame(width: 56, alignment: .leading)
                        Text(Dotted(CueRunFormat.clock(handoff.createdAt), handoff.createdAt.formatted(.relative(presentation: .named))))
                            .foregroundStyle(palette.ink2)
                        Spacer(minLength: 0)
                        DisclosureChevron(open: showsHandoff)
                    }
                    .font(Typography.meta.monospacedDigit())
                    .frame(minHeight: 20).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint(showsHandoff ? "收起交接备忘" : "看交接备忘")
                if showsHandoff { TraceText(text: handoff.text).transition(.opacity) }
            }
        } else {
            fact("上次换新", "还没换过")
        }
    }
}

/// 上下文的刻度尺：底是整把尺，铺色到已用，换新线一道刻线、上面标"换新"。
private struct RenewRuler: View {
    let used: Int
    let renewAt: Int
    let window: Int?
    @Environment(\.palette) private var palette

    /// 尺的全长：窗口；不知道窗口时让换新线落在八成处
    private var scale: Double { Double(max(window ?? Int(Double(renewAt) / 0.8), used, renewAt)) }

    private var fill: Color {
        switch PiContextMeter.level(of: Double(used) / Double(renewAt)) {
        case .critical: palette.failure
        case .tight: palette.ink.opacity(0.7)
        case .roomy: palette.ink.opacity(0.4)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let mark = width * Double(renewAt) / scale
            ZStack(alignment: .bottomLeading) {
                Capsule().fill(palette.hair).frame(height: 6)
                Capsule().fill(fill).frame(width: max(6, width * Double(used) / scale), height: 6)
                    .opacity(used > 0 ? 1 : 0)
                Rectangle().fill(palette.ink2).frame(width: 2, height: 12).offset(x: mark - 1, y: 3)
                Text("换新").font(Typography.caption2).foregroundStyle(palette.ink3).fixedSize()
                    .offset(x: mark - 12, y: -12)
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel("上下文")
        .accessibilityValue("已用 \(CueEnvelope.tokens(used))，换新线 \(CueEnvelope.tokens(renewAt))")
    }
}

// MARK: 一轮

/// 一轮：一行为什么醒、几点、用时、工具次数；在跑的一轮转圈，出错的写胭脂"出错"。点开是交给大脑的话、工具清单、错误与做完时的上下文。
private struct CueRoundRow: View {
    let round: CueRound
    @Binding var expanded: Bool
    @State private var showsSent = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(Motion.snappy) { expanded.toggle() } } label: { header }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded { detail.transition(.opacity) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(expanded ? palette.fill : .clear, in: ChatBlock.shape)
    }

    /// 第一行为什么醒与几点，第二行用时、工具次数、做完时的上下文。
    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: CueRunFormat.symbol(round.wake)).font(Typography.caption).foregroundStyle(palette.ink2)
                    .frame(width: 16).accessibilityHidden(true)
                Text(CueRunFormat.reason(round.wake)).font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                if round.sent.count > 1 {
                    Text("插话 \(round.sent.count - 1)").font(Typography.caption2).foregroundStyle(palette.ink2)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(palette.fill, in: .capsule)
                }
                Spacer(minLength: 4)
                Text(CueRunFormat.clock(round.startedAt)).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3)
                DisclosureChevron(open: expanded)
            }
            HStack(spacing: 6) {
                if round.finishedAt == nil { Spinner(.mini) }
                Text(summary).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
                if round.failure != nil { Text("出错").font(Typography.caption).foregroundStyle(palette.failure) }
            }
            .padding(.leading, 24)
        }
        .frame(minHeight: 36).contentShape(.rect)
    }

    private var summary: Dotted {
        Dotted(
            round.finishedAt.map { CueRunFormat.took($0.timeIntervalSince(round.startedAt)) } ?? "进行中",
            round.calls.isEmpty ? "没调工具" : "\(round.calls.count) 次工具",
            round.context.map { "上下文 \(CueEnvelope.tokens($0))" })
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !round.sent.isEmpty {
                Button { withAnimation(Motion.quick) { showsSent.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "envelope").frame(width: 13).accessibilityHidden(true)
                        Text("交给 Cue 的话")
                        Text(CueRunFormat.preview(round.sent[0])).foregroundStyle(palette.ink3).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        DisclosureChevron(open: showsSent)
                    }
                    .font(Typography.caption).foregroundStyle(palette.ink2)
                    .frame(minHeight: 22).contentShape(.rect)
                }
                .buttonStyle(.plain)
                if showsSent { TraceText(text: round.sent.joined(separator: "\n\n— 插话 —\n\n")).transition(.opacity) }
            }
            ForEach(round.calls) { CueCallRow(call: $0) }
            if let failure = round.failure {
                TraceText(text: failure, tint: palette.failure)
            }
        }
        .padding(.leading, 24).padding(.bottom, 4)
    }
}

/// 一次工具调用：工具清单同一行（图标、名字与动作、右侧用时或"失败"），点开是参数与结果的全文。
private struct CueCallRow: View {
    let call: CueToolCall
    @State private var expanded = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(Motion.quick) { expanded.toggle() } } label: {
                ToolRow(symbol: CueRunFormat.symbol(tool: call.name), target: target, truncation: .tail) { status }
                    .frame(minHeight: 22).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    TraceText(label: "参数", text: CueRunFormat.pretty(call.arguments))
                    if let result = call.result {
                        TraceText(label: "结果", text: result.isEmpty ? "（空）" : CueRunFormat.pretty(result), tint: call.failed ? palette.failure : nil)
                    }
                }
                .padding(.leading, 19)
                .transition(.opacity)
            }
        }
    }

    private var target: Text {
        let detail = CueActivity.detail(tool: call.name, arguments: call.arguments)
        let action = detail.hasPrefix(call.name) ? String(detail.dropFirst(call.name.count)).trimmingPrefix(PiSessionState.detailSeparator) : Substring(detail)
        return Text("\(Text(call.name).fontWeight(.semibold).foregroundStyle(palette.ink2))  \(String(action))")
    }

    @ViewBuilder private var status: some View {
        if call.finishedAt == nil {
            Spinner(.mini)
        } else if call.failed {
            Text("失败").font(Typography.caption).foregroundStyle(palette.failure)
        } else if let finished = call.finishedAt {
            Text(CueRunFormat.took(finished.timeIntervalSince(call.startedAt))).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3)
        }
    }
}

// MARK: 零件

/// 全文：等宽小字垫代码块同一种底（`ChatBlock`），可选；太长在里面滚。
private struct TraceText: View {
    var label: String?
    let text: String
    var tint: Color?
    @Environment(\.palette) private var palette

    private static let maxHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let label { Text(label).font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3) }
            ScrollView {
                Text(text).font(Typography.codeNote).foregroundStyle(tint ?? palette.ink2)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .selectable()
                    .padding(ChatBlock.inset / 1.5)
            }
            .frame(maxHeight: Self.maxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(palette.fill, in: ChatBlock.shape)
        }
    }
}

/// 运行情况里的写法。
private enum CueRunFormat {
    /// 24 小时制到秒：排查时要对得上日志。
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }

    /// 用时：一秒内写毫秒，十秒内到十分之一秒，往上同会话里的写法。
    static func took(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<1: "\(Int((seconds * 1000).rounded())) 毫秒"
        case ..<10: String(format: "%.1f 秒", seconds)
        default: PiClock.duration(seconds)
        }
    }

    static func reason(_ wake: CueWake) -> String {
        switch wake {
        case .enabled: "刚启用"
        case .message: "你发来消息"
        case .sessionActivity: "跟进的事有动静"
        case .idle: "空闲巡视"
        case .reminder(let lines): "提醒到点（\(lines.count) 条）"
        case .renewed: "换新后接着做"
        }
    }

    static func symbol(_ wake: CueWake) -> String {
        switch wake {
        case .enabled: "power"
        case .message: "bubble.left"
        case .sessionActivity: "bolt"
        case .idle: "eye"
        case .reminder: "alarm"
        case .renewed: "arrow.triangle.2.circlepath"
        }
    }

    /// Cue 自己的三个工具各一个图标，读文件类与会话里的工具清单同一套（`ToolActivityLine.symbol`）。
    static func symbol(tool: String) -> String {
        switch tool {
        case "task": "checklist"
        case "tell": "text.bubble"
        case "memory": "brain"
        case "bash": ToolActivityLine.symbol(.command)
        case "read": ToolActivityLine.symbol(.read)
        case "grep", "find", "glob", "ls": ToolActivityLine.symbol(.search)
        default: ToolActivityLine.symbol(.other)
        }
    }

    /// 交给大脑的话的预览：信封的标签行（`<cue>`）跳过，取第一行正文。
    static func preview(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("<") } ?? ""
    }

    /// 参数与结果排成缩进的 JSON；不是 JSON 就原样。
    static func pretty(_ json: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return json }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
