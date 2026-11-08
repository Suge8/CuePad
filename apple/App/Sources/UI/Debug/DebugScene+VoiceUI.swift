#if os(macOS) && DEBUG
import CueStore
import SwiftUI

/// 隔离原型：`-CuePadVoiceUI YES -CuePadVoiceState connecting|listening|processing|speaking|muted|failed|ended`。
/// `-CuePadVoiceWidth 360` 控制栏宽；`-CuePadVoiceLong YES` 压长文；`-CuePadVoiceIssue microphone|login|offline|quota`。
/// `-CuePadVoiceReplies 200 -CuePadVoiceUpdates YES`：多条历史与追加/加长按钮，从投影数据入口验贴底与上翻保位。
/// `-CuePadVoiceSignal YES` 显式注入模拟音频；`-CuePadVoiceSequence YES` 演示状态转场（含插话、静音和断线）。
/// 点击“播放模拟音频”才走时钟；录屏可显式给 `-CuePadVoiceAutoPlay YES`，留三秒首帧后播放。不连麦克风、不执行任务。
/// `-CuePadVoiceMuted YES` 可独立组合远端讲话与麦克风静音；合成样本与核心一样每 50ms 更新一次。
/// `-CuePadVoiceRequestFailed YES` 独立叠加请求失败，可与通话中、结束态组合；重试只清除这份演示失败。
/// `-CuePadVoiceEarlierFailure YES`：请求 A 失败、最新请求 B 已送达，恢复只重试 A。
/// `-CuePadVoiceShort YES` 用短请求与回复验首屏阅读边界；`-CuePadVoiceCompact YES` 从收起的通话开始。
/// `-CuePadReduceMotion YES` 验减弱动态；`-CuePadVoiceHidden YES` 验不可见门禁，不改系统偏好。
struct DebugVoiceStage: View {
    @Environment(\.palette) private var palette
    @State private var state = DebugScene.defaults.bool(forKey: "CuePadVoiceSequence") ? "connecting" : (DebugScene.defaults.string(forKey: "CuePadVoiceState") ?? "listening")
    @State private var audio = DebugVoiceSamples()
    @State private var replyReady = !DebugScene.defaults.bool(forKey: "CuePadVoiceSequence")
    @State private var expanded = !DebugScene.defaults.bool(forKey: "CuePadVoiceCompact")
    @State private var muted = DebugScene.defaults.string(forKey: "CuePadVoiceState") == "muted" || DebugScene.defaults.bool(forKey: "CuePadVoiceMuted")
    @State private var earlierFailure = DebugScene.defaults.bool(forKey: "CuePadVoiceEarlierFailure")
    @State private var requestFailed = DebugScene.defaults.bool(forKey: "CuePadVoiceRequestFailed")
    @State private var lastAction = ""
    @State private var reducedSpace = false
    @State private var replies = Self.seedReplies()
    @State private var started: Date?
    @State private var sequencing = DebugScene.defaults.bool(forKey: "CuePadVoiceSequence")
    private let simulated = DebugScene.defaults.bool(forKey: "CuePadVoiceSignal") || DebugScene.defaults.bool(forKey: "CuePadVoiceSequence")

    static var width: CGFloat {
        let asked = DebugScene.defaults.double(forKey: "CuePadVoiceWidth")
        return asked > 0 ? asked : 380
    }

    var body: some View {
        VStack(spacing: Spacing.block) {
            HStack(spacing: Spacing.item) {
                Text(verbatim: "Cue").font(Typography.toolbarTitle)
                Spacer(minLength: 0)
                CueVoiceEntry(inCall: state != "ended") { receive(state == "ended" ? .start : .expand) }
            }
            .padding(.horizontal, Spacing.page)
            .frame(height: Chrome.band)
            if DebugScene.defaults.bool(forKey: "CuePadVoiceUpdates") {
                HStack(spacing: Spacing.item) {
                    Button { appendReply() } label: {
                        Text(String(localized: "演示：追加回复", table: "Demo"))
                    }
                    Button(action: extendReply) {
                        Text(String(localized: "演示：加长回复", table: "Demo"))
                    }
                }
                .buttonStyle(ControlButtonStyle(size: .compact))
                HStack(spacing: Spacing.item) {
                    Button {
                        interruptSequence()
                        state = "failed"
                    } label: { Text(String(localized: "演示：断线", table: "Demo")) }
                    Button { reducedSpace.toggle() } label: {
                        Text(reducedSpace ? String(localized: "演示：恢复空间", table: "Demo") : String(localized: "演示：缩小空间", table: "Demo"))
                    }
                }
                .buttonStyle(ControlButtonStyle(size: .compact))
            }
            if simulated {
                VStack(spacing: Spacing.tight) {
                    Text(String(localized: "模拟音频 · 未连接麦克风", table: "Demo"))
                        .font(Typography.meta).foregroundStyle(palette.ink2)
                    Button(action: play) { Text(String(localized: "播放模拟音频", table: "Demo")) }
                        .buttonStyle(ControlButtonStyle(size: .compact))
                }
            }
            GeometryReader { box in
                let height = reducedSpace ? min(300, box.size.height) : box.size.height
                CueVoiceView(presentation: presentation, expanded: expanded, availableHeight: height, action: receive)
                    .frame(height: height, alignment: .top)
                    .transformEnvironment(\.pageActive) { if DebugScene.defaults.bool(forKey: "CuePadVoiceHidden") { $0 = false } }
            }
            Text(verbatim: lastAction)
                .font(Typography.meta).foregroundStyle(palette.ink2)
                .frame(height: ControlSize.compact.height)
                .accessibilityIdentifier("voice-prototype-action")
        }
        .frame(width: Self.width)
        .background(palette.desk)
        .task {
            guard DebugScene.defaults.bool(forKey: "CuePadVoiceAutoPlay") else { return }
            await Task.wait(for: .seconds(3))
            play()
        }
        .task(id: started) {
            guard let started else { return }
            // 明示的 Debug 信号源；只发布样本。外层只在脚本换状态时更新，不由 20Hz 驱动历史排版。
            while !Task.isCancelled {
                let time = Date().timeIntervalSince(started)
                audio.samples = DebugVoiceAudio.samples(at: time)
                if sequencing {
                    let next = DebugVoiceAudio.state(at: time)
                    if state != next { state = next }
                    if !replyReady, time >= 7 { replyReady = true }
                }
                do { try await Task.sleep(for: .seconds(DebugVoiceAudio.interval)) }
                catch { return }
            }
        }
    }

    private var presentation: CueVoicePresentation {
        let muted = muted || (sequencing && ["muted", "speaking-muted"].contains(state))
        let activity: CueVoicePresentation.Activity = switch state {
        case "connecting": .connecting
        case "processing": .processing
        case "speaking", "speaking-muted": .speaking
        case "failed": .failed
        case "ended": .ended
        default: .listening
        }
        let latestID = replies.last { $0.text.isEmpty && $0.request != nil }?.id
        let rows = activity == .connecting && !replyReady ? [] : replies.compactMap { row -> CueVoicePresentation.Reply? in
            if !replyReady && row.request == nil { return nil }
            var row = row
            if earlierFailure, row.id == replies.first?.id, let request = row.request {
                row.request = .init(text: request.text, delivery: .failed(.reported(String(localized: Self.earlierIssue))))
            }
            if row.id == latestID, let request = row.request {
                let delivery: Speech.Trip = if requestFailed { .failed(.reported(String(localized: "未交给 Cue"))) }
                    else if !replyReady { .sending } else { .delivered }
                row.request = .init(text: request.text, delivery: delivery)
            }
            return .init(id: row.id, text: row.text, canRequestRepeat: activity.isLive && !row.text.isEmpty,
                         request: row.request, note: row.note)
        }
        let issue: CueVoicePresentation.Issue? = if earlierFailure { .init(message: Self.earlierIssue, recovery: .retryRequest("earlier")) }
            else if requestFailed { .init(message: "未交给 Cue", recovery: .retryRequest("latest")) }
            else if activity == .failed { self.issue } else { nil }
        return CueVoicePresentation(
            name: "Cue", activity: activity, muted: muted, samples: { [audio, simulated] in simulated ? audio.samples : [] },
            request: rows.first { $0.id == latestID }?.request, replies: rows, issue: issue,
            canStopExecution: activity != .connecting, executions: executions)
    }

    private static var earlierIssue: LocalizedStringResource {
        .init("请求 A「检查发布事项」未交给 Cue：等待回执超时", table: "Demo")
    }

    private static func seedReplies() -> [CueVoicePresentation.Reply] {
        if DebugScene.defaults.bool(forKey: "CuePadVoiceEarlierFailure") {
            return [
                .init(id: UUID(), text: "", canRequestRepeat: false,
                      request: .init(text: String(localized: "请求 A：检查发布事项", table: "Demo"), delivery: .sending)),
                .init(id: UUID(), text: "", canRequestRepeat: false,
                      request: .init(text: String(localized: "请求 B：整理会议记录", table: "Demo"), delivery: .delivered)),
            ]
        }
        let long = DebugScene.defaults.bool(forKey: "CuePadVoiceLong")
        return (1...max(1, DebugScene.defaults.integer(forKey: "CuePadVoiceReplies"))).flatMap { [requestRow($0), reply($0, long: long)] }
    }

    private static func requestRow(_ index: Int) -> CueVoicePresentation.Reply {
        let text = DebugScene.defaults.bool(forKey: "CuePadVoiceShort")
            ? String(localized: "检查发布事项", table: "Demo")
            : String(localized: "把发布前的检查交给 Cue，保留需要我确认的事项", table: "Demo")
        let marker = String(localized: "演示请求 \(index)", table: "Demo")
        return .init(id: UUID(), text: "", canRequestRepeat: false,
                     request: .init(text: text + "\n" + marker, delivery: .delivered))
    }

    private static func reply(_ index: Int, long: Bool) -> CueVoicePresentation.Reply {
        let text = String(localized: "我已经整理好发布检查，正在核对 Mac 上的通话体验。需要你确认的事项会留在任务里。", table: "Demo")
        let short = DebugScene.defaults.bool(forKey: "CuePadVoiceShort")
        let body = short ? String(localized: "正在检查，需要确认的事项会留在任务里。", table: "Demo") : text
        let marker = String(localized: "演示回复 \(index)", table: "Demo")
        let textBody = long ? (1...12).map { "\(marker) · \($0)\n\(body)" }.joined(separator: "\n") : body
        return .init(id: UUID(), text: textBody + "\n" + marker, canRequestRepeat: true)
    }

    private func appendReply() {
        let index = replies.count / 2 + 1
        replies += [Self.requestRow(index), Self.reply(index, long: index.isMultiple(of: 2))]
    }

    private var executions: [CueVoicePresentation.Execution] {
        let count = max(0, DebugScene.defaults.integer(forKey: "CuePadVoiceExecutions"))
        let tasks: [CueVoicePresentation.Execution] = (0..<count).map { index in
            .init(id: "demo-execution-\(index)", title: String(localized: "演示任务 \(index + 1)", table: "Demo"),
                  status: String(localized: "正在处理"))
        }
        let stops: [CueVoicePresentation.Execution] = (0..<count).map { index in
            let failure = index == 0
            let unconfirmed = index == 1
            let status = if failure { String(localized: "演示：停止失败，连接中断；执行可能仍在继续，请查看目标任务后重试", table: "Demo") }
                else if unconfirmed { String(localized: "演示：停止结果未确认，请勿视为已停止", table: "Demo") }
                else { String(localized: "停止请求已受理") }
            return .init(id: "demo-stop-\(index)", title: String(localized: "停止演示任务 \(index + 1)", table: "Demo"),
                         status: status, needsAttention: failure || unconfirmed)
        }
        return tasks + stops
    }

    private func extendReply() {
        guard let last = replies.last else { return }
        let addition = Self.reply(replies.count, long: true).text
        replies[replies.count - 1] = .init(id: last.id, text: last.text + "\n" + addition, canRequestRepeat: last.canRequestRepeat, request: last.request, note: last.note)
    }

    private var issue: CueVoicePresentation.Issue {
        switch DebugScene.defaults.string(forKey: "CuePadVoiceIssue") {
        case "microphone": .init(message: "麦克风访问未开启", recovery: .reconnect)
        case "login": .init(message: "登录已失效", recovery: .reconnect)
        case "quota": .init(message: "通话额度已用完", recovery: .reconnect)
        default: .init(message: "网络连接已断开", recovery: .reconnect)
        }
    }

    private func play() {
        sequencing = DebugScene.defaults.bool(forKey: "CuePadVoiceSequence")
        started = Date()
    }

    /// 实际按钮优先于演示脚本；接过当前投影再停脚本，不让下一帧把挂断或取消静音覆盖掉。
    private func interruptSequence() {
        guard sequencing else { return }
        state = DebugVoiceAudio.state(at: started.map { Date().timeIntervalSince($0) } ?? 0.35)
        muted = muted || ["muted", "speaking-muted"].contains(state)
        sequencing = false
    }

    private func receive(_ action: CueVoiceAction) {
        switch action {
        case .start:
            interruptSequence()
            state = "connecting"
            if simulated { sequencing = true; started = Date() }
        case .toggleMute:
            interruptSequence()
            muted.toggle()
        case .hangUp:
            interruptSequence()
            state = "ended"
        case .stopExecution:
            lastAction = String(localized: "演示：已收到停止执行操作", table: "Demo")
        case .recover(.retryRequest(let id)):
            if id == "earlier", earlierFailure {
                earlierFailure = false
                lastAction = String(localized: "演示：已重试请求 A", table: "Demo")
                return
            }
            if id == "latest" { requestFailed = false }
            lastAction = String(localized: "演示：已收到恢复操作", table: "Demo")
        case .recover(.reconnect):
            receive(.start)
        case .requestRepeat:
            lastAction = String(localized: "演示：已收到再说一遍请求", table: "Demo")
        case .expand: expanded = true
        case .collapse: expanded = false
        }
    }
}

struct DebugVoicePrototype: ViewModifier {
    func body(content: Content) -> some View {
        if DebugScene.defaults.bool(forKey: "CuePadVoiceUI") {
            content.overlay(alignment: .trailing) {
                DebugVoiceStage().modifier(PaletteProvider())
            }
            .panelHost()
        } else {
            content
        }
    }
}
#endif
