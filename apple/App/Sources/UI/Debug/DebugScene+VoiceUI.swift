#if os(macOS) && DEBUG
import SwiftUI

/// 隔离原型：`-CuePadVoiceUI YES -CuePadVoiceState connecting|listening|processing|speaking|muted|failed|ended`。
/// `-CuePadVoiceWidth 360` 控制栏宽；`-CuePadVoiceLong YES` 压长文；`-CuePadVoiceIssue microphone|login|offline|quota`。
/// `-CuePadVoiceReplies 200 -CuePadVoiceUpdates YES`：多条历史与追加/加长按钮，从投影数据入口验贴底与上翻保位。
/// `-CuePadVoiceSignal YES` 显式注入模拟音频；`-CuePadVoiceSequence YES` 演示状态转场（含插话、静音和断线）。
/// 点击“播放模拟音频”才走时钟，之前停在夹具首帧；不连麦克风、不执行任务，默认仍是空样本。
/// `-CuePadVoiceMuted YES` 可独立组合远端讲话与麦克风静音；合成样本与核心一样每 50ms 更新一次。
/// `-CuePadVoiceShort YES` 用短请求与回复验首屏阅读边界。
/// `-CuePadReduceMotion YES` 验减弱动态；`-CuePadVoiceHidden YES` 验不可见门禁，不改系统偏好。
struct DebugVoiceStage: View {
    @Environment(\.palette) private var palette
    @State private var state = DebugScene.defaults.string(forKey: "CuePadVoiceState") ?? "listening"
    @State private var expanded = true
    @State private var muted = DebugScene.defaults.string(forKey: "CuePadVoiceState") == "muted" || DebugScene.defaults.bool(forKey: "CuePadVoiceMuted")
    @State private var stopped = false
    @State private var lastAction = ""
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
                    Button { replies.append(Self.reply(replies.count + 1)) } label: {
                        Text(String(localized: "演示：追加回复", table: "Demo"))
                    }
                    Button(action: extendReply) {
                        Text(String(localized: "演示：加长回复", table: "Demo"))
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
            Spacer(minLength: 0)
            TimelineView(.periodic(from: started ?? .distantFuture, by: DebugVoiceAudio.interval)) { clock in
                CueVoiceView(presentation: presentation(at: started.map { clock.date.timeIntervalSince($0) } ?? 0.35), expanded: expanded, action: receive)
            }
            .transformEnvironment(\.pageActive) { if DebugScene.defaults.bool(forKey: "CuePadVoiceHidden") { $0 = false } }
            Spacer(minLength: 0)
            Text(verbatim: lastAction)
                .font(Typography.meta).foregroundStyle(palette.ink2)
                .frame(height: ControlSize.compact.height)
                .accessibilityIdentifier("voice-prototype-action")
        }
        .frame(width: Self.width)
        .background(palette.desk)
    }

    private func presentation(at time: TimeInterval) -> CueVoicePresentation {
        let state = sequencing ? DebugVoiceAudio.state(at: time) : state
        let muted = muted || (sequencing && state == "muted")
        let activity: CueVoicePresentation.Activity = switch state {
        case "connecting": .connecting
        case "processing": .processing
        case "speaking": .speaking
        case "failed": .failed
        case "ended": .ended
        default: .listening
        }
        let long = DebugScene.defaults.bool(forKey: "CuePadVoiceLong")
        let request = DebugScene.defaults.bool(forKey: "CuePadVoiceShort") ? String(localized: "检查发布事项", table: "Demo") : String(localized: "把发布前的检查交给 Cue，保留需要我确认的事项", table: "Demo")
        return CueVoicePresentation(
            name: "Cue", activity: activity, muted: muted, samples: { simulated ? DebugVoiceAudio.samples(at: time) : [] },
            request: activity == .connecting ? nil : .init(text: long ? String(repeating: request + "\n", count: 8) : request,
                delivery: activity == .processing ? .sending : .delivered),
            replies: activity == .connecting ? [] : replies.map {
                .init(id: $0.id, text: $0.text, canRequestRepeat: activity.isLive)
            },
            issue: activity == .failed ? issue : nil,
            canStopExecution: !stopped && activity != .connecting)
    }

    private static func seedReplies() -> [CueVoicePresentation.Reply] {
        let count = max(1, DebugScene.defaults.integer(forKey: "CuePadVoiceReplies"))
        return (1...count).map(reply)
    }

    private static func reply(_ index: Int) -> CueVoicePresentation.Reply {
        let text = String(localized: "我已经整理好发布检查，正在核对 Mac 上的通话体验。需要你确认的事项会留在任务里。", table: "Demo")
        if DebugScene.defaults.bool(forKey: "CuePadVoiceShort") {
            return .init(id: UUID(), text: String(localized: "正在检查，需要确认的事项会留在任务里。", table: "Demo"), canRequestRepeat: true)
        }
        let long = DebugScene.defaults.bool(forKey: "CuePadVoiceLong")
        let marker = String(localized: "演示回复 \(index)", table: "Demo")
        return .init(id: UUID(), text: (long ? String(repeating: text + "\n", count: 12) : text) + "\n" + marker, canRequestRepeat: true)
    }

    private func extendReply() {
        guard let last = replies.last else { return }
        let addition = Self.reply(replies.count).text
        replies[replies.count - 1] = .init(id: last.id, text: last.text + "\n" + addition, canRequestRepeat: last.canRequestRepeat)
    }

    private var issue: CueVoicePresentation.Issue {
        switch DebugScene.defaults.string(forKey: "CuePadVoiceIssue") {
        case "microphone": .init(message: "麦克风访问未开启", recovery: "打开麦克风设置")
        case "login": .init(message: "登录已失效", recovery: "重新登录")
        case "quota": .init(message: "通话额度已用完", recovery: "查看额度")
        default: .init(message: "网络连接已断开", recovery: "重新连接")
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
        muted = muted || state == "muted"
        sequencing = false
    }

    private func receive(_ action: CueVoiceAction) {
        switch action {
        case .start:
            interruptSequence()
            state = "connecting"
        case .toggleMute:
            interruptSequence()
            muted.toggle()
        case .hangUp:
            interruptSequence()
            state = "ended"
        case .stopExecution:
            stopped = true
            lastAction = String(localized: "演示：已收到停止执行操作", table: "Demo")
        case .recover:
            lastAction = String(localized: "演示：已收到恢复操作", table: "Demo")
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
            HStack(spacing: 0) {
                content
                DebugVoiceStage().modifier(PaletteProvider())
            }
        } else {
            content
        }
    }
}
#endif
