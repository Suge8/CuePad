#if os(macOS)
import CueAgent
import CueStore
import SwiftUI

/// 几轮只在值班的管理器的内存里（`CueKeeper.rounds`）；Cue 不在这台 Mac 值班时没有这一栏。
struct CueRunPanel: View {
    let keeper: CueKeeper
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var opened: [Int: Bool] = [:]

    static let width: CGFloat = 360

    var body: some View {
        let rounds = keeper.rounds
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("运行情况").font(Typography.sectionTitle).foregroundStyle(palette.ink)
                Spacer()
                Button("收起", icon: .close) { workspace.cue.showsRun = false }
                    .labelStyle(.iconOnly).font(Glyph.small).foregroundStyle(palette.ink3)
                    .frame(width: 28, height: 28).contentShape(.rect)
                    .buttonStyle(PressStyle(.button))
            }
            .padding(.leading, Spacing.block).padding(.trailing, Spacing.item).padding(.vertical, Spacing.item)
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.block) {
                    CueContextLine(context: workspace.cue.context)
                    Text(Dotted(String(localized: "最近几轮"), rounds.isEmpty ? nil : "\(rounds.count)"))
                        .font(Typography.label).foregroundStyle(palette.ink3)
                    if rounds.isEmpty {
                        Text("还没醒过").font(Typography.meta).foregroundStyle(palette.ink3)
                    }
                    LazyVStack(alignment: .leading, spacing: Spacing.item) {
                        ForEach(rounds.reversed()) { round in
                            let newest = round.id == rounds.last?.id
                            CueRoundRow(round: round, expanded: Binding { opened[round.id] ?? newest } set: { opened[round.id] = $0 })
                        }
                    }
                }
                .padding(.horizontal, Spacing.block).padding(.bottom, Spacing.block)
            }
            .scrollIndicators(.automatic)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .glass(in: .rect(cornerRadius: Radius.field))
    }
}

private struct CueRoundRow: View {
    let round: CueRound
    @Binding var expanded: Bool
    @State private var showsSent = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            Button { withAnimation(Motion.nudge) { expanded.toggle() } } label: { header }
                .buttonStyle(PressStyle())
                .accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded { detail.transition(.opacity) }
        }
        .padding(.horizontal, Spacing.item).padding(.vertical, Spacing.item)
        .background(expanded ? palette.fill : .clear, in: ChatBlock.shape)
    }

    private static let icon: CGFloat = 16
    private static let lead = icon + Spacing.item

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            HStack(spacing: Spacing.item) {
                Image(round.wake.icon).font(Typography.caption).foregroundStyle(palette.ink2)
                    .frame(width: Self.icon).accessibilityHidden(true)
                Text(CueRunFormat.reason(round.wake)).font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                if round.sent.count > 1 {
                    Text("插话 \(round.sent.count - 1)").font(Typography.caption2).foregroundStyle(palette.ink2)
                        .padding(.horizontal, Spacing.tight).padding(.vertical, Spacing.hair).background(palette.fill, in: .capsule)
                }
                Spacer(minLength: Spacing.tight)
                Text(CueRunFormat.clock(round.startedAt)).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3)
                DisclosureChevron(open: expanded)
            }
            HStack(spacing: Spacing.glyph) {
                if round.finishedAt == nil { Spinner(.mini) }
                Text(summary).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
                if round.failure != nil { Text("出错").font(Typography.caption).foregroundStyle(palette.failure) }
            }
            .padding(.leading, Self.lead)
        }
        .frame(minHeight: 36).contentShape(.rect)
    }

    private var summary: Dotted {
        Dotted(
            round.finishedAt.map { CueRunFormat.took($0.timeIntervalSince(round.startedAt)) } ?? String(localized: "进行中"),
            round.calls.isEmpty ? String(localized: "没调工具") : String(localized: "\(round.calls.count) 次工具"),
            round.context.map { String(localized: "上下文 \(CueContext.tokens($0))") })
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            if !round.sent.isEmpty {
                Button { withAnimation(Motion.fade) { showsSent.toggle() } } label: {
                    HStack(spacing: Spacing.glyph) {
                        Image(.mail).frame(width: 13).accessibilityHidden(true)
                        Text("交给 Cue 的话")
                        Text(CueRunFormat.preview(round.sent[0])).foregroundStyle(palette.ink3).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: Spacing.tight)
                        DisclosureChevron(open: showsSent)
                    }
                    .font(Typography.caption).foregroundStyle(palette.ink2)
                    .frame(minHeight: 22).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                if showsSent { TraceText(text: round.sent.joined(separator: String(localized: "\n\n— 插话 —\n\n"))).transition(.opacity) }
            }
            ForEach(round.calls) { CueCallRow(call: $0) }
            if let failure = round.failure {
                TraceText(text: failure, tint: palette.failure)
            }
        }
        .padding(.leading, Self.lead).padding(.bottom, Spacing.tight)
    }
}

private struct CueCallRow: View {
    let call: CueToolCall
    @State private var expanded = false
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Button { withAnimation(Motion.fade) { expanded.toggle() } } label: {
                ToolRow(icon: CueRunFormat.icon(tool: call.name), target: target, truncation: .tail) { status }
                    .frame(minHeight: 22).contentShape(.rect)
            }
            .buttonStyle(PressStyle())
            .accessibilityValue(expanded ? "已展开" : "已收起")
            if expanded {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    TraceText(label: "参数", text: CueRunFormat.pretty(call.arguments))
                    if let result = call.result {
                        TraceText(label: "结果", text: result.isEmpty ? String(localized: "（空）") : CueRunFormat.pretty(result), tint: call.failed ? palette.failure : nil)
                    }
                }
                .noteGlyph(.indent)
                .transition(.opacity)
            }
        }
    }

    private var target: Text {
        let detail = call.step.map(CueActivity.line) ?? call.detail ?? ""
        let action = detail.hasPrefix(call.name) ? String(detail.dropFirst(call.name.count)).trimmingPrefix(SessionState.detailSeparator) : Substring(detail)
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

private struct TraceText: View {
    var label: LocalizedStringResource?
    let text: String
    var tint: Color?
    @Environment(\.palette) private var palette

    private static let maxHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let label { Text(label).font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3) }
            ScrollView {
                Text(text).font(Typography.codeNote).foregroundStyle(tint ?? palette.ink2)
                    .lineSpacing(Typography.noteLineSpacing)
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

    static func took(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<1: String(localized: "\(Int((seconds * 1000).rounded())) 毫秒")
        case ..<10: String(localized: "\(seconds.formatted(.number.precision(.fractionLength(1)))) 秒")
        default: SessionClock.duration(seconds)
        }
    }

    static func reason(_ wake: CueWake) -> String {
        switch wake {
        case .sessionActivity(let stirs): String(localized: "\(wake.reason)（\(stirs.count) 处）")
        case .schedule(let fires): String(localized: "\(wake.reason)（\(fires.count) 条）")
        case .enabled, .message, .idle: wake.reason
        }
    }

    static func icon(tool: String) -> Icon {
        switch tool {
        case "task": .task
        case "tell": .said
        case "memory": .memory
        case "setup": .settings
        default: RoundProcess.icon(tool: tool)
        }
    }

    static func preview(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("<") } ?? ""
    }

    static func pretty(_ json: String) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return json }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
