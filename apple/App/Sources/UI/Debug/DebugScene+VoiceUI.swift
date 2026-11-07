#if os(macOS) && DEBUG
import SwiftUI

/// 隔离原型：`-CuePadVoiceUI YES -CuePadVoiceState connecting|listening|processing|speaking|muted|failed|ended`。
/// `-CuePadVoiceWidth 360` 控制栏宽；`-CuePadVoiceLong YES` 压长文；`-CuePadVoiceIssue microphone|login|offline|quota`。
/// 不连音频、不执行任务；动作只改此演示投影。声波保持空样本，不拿合成波形冒充实际声音。
struct DebugVoiceStage: View {
    @Environment(\.palette) private var palette
    @State private var state = DebugScene.defaults.string(forKey: "CuePadVoiceState") ?? "listening"
    @State private var expanded = true
    @State private var muted = DebugScene.defaults.string(forKey: "CuePadVoiceState") == "muted"
    @State private var stopped = false
    @State private var lastAction = ""
    private let replyID = UUID()

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
            Spacer(minLength: 0)
            CueVoiceView(presentation: presentation, expanded: expanded, action: receive)
            Spacer(minLength: 0)
            Text(verbatim: lastAction)
                .font(Typography.meta).foregroundStyle(palette.ink2)
                .frame(height: ControlSize.compact.height)
                .accessibilityIdentifier("voice-prototype-action")
        }
        .frame(width: Self.width)
        .background(palette.desk)
    }

    private var presentation: CueVoicePresentation {
        let activity: CueVoicePresentation.Activity = switch state {
        case "connecting": .connecting
        case "processing": .processing
        case "speaking": .speaking
        case "failed": .failed
        case "ended": .ended
        default: .listening
        }
        let long = DebugScene.defaults.bool(forKey: "CuePadVoiceLong")
        let request = String(localized: "把发布前的检查交给 Cue，保留需要我确认的事项", table: "Demo")
        let reply = String(localized: "我已经整理好发布检查，正在核对 Mac 上的通话体验。需要你确认的事项会留在任务里。", table: "Demo")
        return CueVoicePresentation(
            name: "Cue", activity: activity, muted: muted, samples: [],
            request: activity == .connecting ? nil : .init(text: long ? String(repeating: request + "\n", count: 8) : request,
                delivery: activity == .processing ? .submitting : .accepted),
            replies: activity == .connecting ? [] : [.init(id: replyID,
                text: long ? String(repeating: reply + "\n", count: 12) : reply,
                canRequestRepeat: activity.isLive && activity != .connecting)],
            issue: activity == .failed ? issue : nil,
            canStopExecution: !stopped && activity != .connecting)
    }

    private var issue: CueVoicePresentation.Issue {
        switch DebugScene.defaults.string(forKey: "CuePadVoiceIssue") {
        case "microphone": .init(message: "麦克风访问未开启", recovery: "打开麦克风设置")
        case "login": .init(message: "登录已失效", recovery: "重新登录")
        case "quota": .init(message: "通话额度已用完", recovery: "查看额度")
        default: .init(message: "网络连接已断开", recovery: "重新连接")
        }
    }

    private func receive(_ action: CueVoiceAction) {
        switch action {
        case .start: state = "connecting"
        case .toggleMute: muted.toggle()
        case .hangUp: state = "ended"
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
