#if os(macOS)
import CueAgent
import CueStore
import SwiftUI

/// Cue 页右侧的"运行情况"（给开发者看，默认关着，从"⋯"里打开，`CueWatch.showsRun`）：上面是上下文（`CueContextCard`，与手机 Cue 面板同一个，
/// 读同步来的那份）；下面是最近几轮，新的在上：每轮一行为什么醒、几点、用时、调了几次工具，
/// 点开是交给大脑的话与工具清单（清单的行与会话里回答注脚的清单同一个 `ToolRow`），清单的一条再点开是参数与结果的全文。
/// 几轮只在值班的管理器的内存里（`CueKeeper.rounds`）；Cue 不在这台 Mac 值班时没有这一栏。
struct CueRunPanel: View {
    let keeper: CueKeeper
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
                Button("收起", icon: .close) { workspace.cue.showsRun = false }
                    .labelStyle(.iconOnly).font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink3)
                    .frame(width: 28, height: 28).contentShape(.rect)
                    .buttonStyle(PressStyle(.button))
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CueContextCard(context: workspace.cue.context)
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
                .buttonStyle(PressStyle())
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
                Image(round.wake.icon).font(Typography.caption).foregroundStyle(palette.ink2)
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
            round.context.map { "上下文 \(CueContext.tokens($0))" })
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !round.sent.isEmpty {
                Button { withAnimation(Motion.quick) { showsSent.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(.mail).frame(width: 13).accessibilityHidden(true)
                        Text("交给 Cue 的话")
                        Text(CueRunFormat.preview(round.sent[0])).foregroundStyle(palette.ink3).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        DisclosureChevron(open: showsSent)
                    }
                    .font(Typography.caption).foregroundStyle(palette.ink2)
                    .frame(minHeight: 22).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
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
                ToolRow(icon: CueRunFormat.icon(tool: call.name), target: target, truncation: .tail) { status }
                    .frame(minHeight: 22).contentShape(.rect)
            }
            .buttonStyle(PressStyle())
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
        case .sessionActivity(let stirs): "会话有动静（\(stirs.count) 处）"
        case .idle: "空闲巡视"
        case .tidy: "整理记忆"
        case .reminder(let lines): "提醒到点（\(lines.count) 条）"
        case .renewed: "换新后接着做"
        case .settingsChanged: "换班次前写交接"
        }
    }

    /// Cue 自己的三个工具各一个图标，读文件类与会话里的工具清单同一套（`RoundProcess.icon`）。
    static func icon(tool: String) -> Icon {
        switch tool {
        case "task": .task
        case "tell": .said
        case "memory": .memory
        default: RoundProcess.icon(tool: tool)
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
