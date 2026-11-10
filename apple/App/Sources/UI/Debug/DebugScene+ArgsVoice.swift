#if DEBUG
import Foundation

/// 与 Cue 通话的参数（Mac 发起见 `DebugScene+Voice`，手机发起见 `DebugScene+PhoneVoiceCall`）。
/// 键 = `-CuePad` + 前缀「Voice」 + 字段名（大小写不论）；没给：Bool 为 false、数为 0、可选为 nil。
nonisolated struct VoiceArgs: Decodable, DebugArgGroup {
    static let prefix = "Voice"
    /// `-CuePadVoiceCloseSeconds <秒>`：通话多久后关闭
    let closeSeconds: Double
    /// `-CuePadVoiceCodex <可执行文件>`（Mac）：通话的凭证照正式路径向这个 Codex 要（`codexAccess`），不读令牌文件；用替身验取凭证卡住、失败
    let codex: String?
    /// `-CuePadVoiceDropRelay <在听后秒>,<断多久秒>`：像网络断了一样断掉这台的中转连接（`DebugRelayDrop`），核对通话等对端以新租约回来（`VoiceLink`）
    let dropRelay: String?
    /// `-CuePadVoiceFailProjection <在听后秒>,<多久秒>`（Mac）：这段时间里发给手机的投影一律当发送失败，核对 Mac 不因此当链路断
    let failProjection: String?
    /// `-CuePadVoiceHangUpAfterReply YES`：结果送出后观察到实际输出、模型回合结束且音轨安静才挂断
    let hangUpAfterReply: Bool
    /// `-CuePadVoiceHistory <条数>`：通话面板预置的历史条数
    let history: Int
    /// `-CuePadVoiceInterruptAfter <秒>`（手机）：在听后这么久发一条"会话被停用"的系统通知（来电、Siri 收走声音时系统发的那条）
    let interruptAfter: Double
    /// `-CuePadVoiceKeepOpen YES`：首轮挂断后保留窗口，供真实按钮重连与结果阅读验收
    let keepOpen: Bool
    /// `-CuePadVoiceLayout <布局>`：语音面板布局样例
    let layout: String?
    /// `-CuePadVoiceLightProbe YES`：语音面板亮度探针
    let lightProbe: Bool
    /// `-CuePadVoiceLog <文件>`：`<距起点秒> <节点>`
    let log: String?
    /// `-CuePadVoiceModel <模型>`：指定其他已在隔离目录登录的模型
    let model: String?
    /// `-CuePadVoiceMotion <名称|rapid>`：语音面板动效样例
    let motion: String?
    /// `-CuePadVoiceMotionTrace YES`：语音面板动效逐帧打点
    let motionTrace: Bool
    /// `-CuePadVoicePlayInBackground YES`（手机）：在听后等 App 进了后台再送声源文件；下行走真的扬声器（静音），不录
    let playInBackground: Bool
    /// `-CuePadVoiceRepeatOnReturn YES`（手机，配 `-CuePadVoiceDropRelay`）：中转以新租约连回来的当下就请 Cue 重说最近一条结果，
    /// 让这条命令赶在 resume 之前到 Mac（Mac 日志的 `relinked by command(…)`）
    let repeatOnReturn: Bool
    /// `-CuePadVoiceReadFixture <原文>`：把原文作为隔离库的主动消息请 GPT Live 朗读，录成后续验收的声源
    let readFixture: String?
    /// `-CuePadVoiceReadings YES`：通话读数打点
    let readings: Bool
    /// `-CuePadVoiceRecord <wav>`：声源是文件时把对方的声音录成文件（不外放，无人值守）
    let record: String?
    /// `-CuePadVoiceReplay YES`：Cue 结果送出后重放原 delegation 与用户 turn.done，核对请求没有重复落库
    let replay: Bool
    /// `-CuePadVoiceRuntime <pi|codex|claude>`：指定其他已在隔离目录登录的运行时
    let runtime: String?
    /// `-CuePadVoiceScenario <名称>`：通话布局场景
    let scenario: String?
    /// `-CuePadVoiceSeconds <秒>`（默认 60）：通话这么久后挂断；Mac 等手机来电时给了才挂（从接通算）
    let seconds: Double?
    /// `-CuePadVoiceToken <文件>` 读（`scripts/voice-token.py` 经本机 Codex app-server 获取，续期语义见 CodexAccess）：隔离目录里的 Codex 没登录
    let token: String?
    /// `-CuePadVoiceWireLog <文件>`：通话协议的收发日志
    let wireLog: String?
}

extension DebugScene {
    /// 照 `-CuePadVoiceDropRelay` 在通话进入"在听"后断这台的中转连接；没给就不起。
    static func dropRelay(note: @escaping (String) -> Void) -> Task<Void, Never>? {
        window(args.voiceOpts.dropRelay, "-CuePadVoiceDropRelay") { seconds in
            note("relay-drop \(seconds)")
            DebugRelayDrop.drop(for: .seconds(seconds))
        }
    }

    /// `DebugHooks.voiceProjectionSend` 读它。
    static var projectionFailsUntil: ContinuousClock.Instant?

    static func failProjection(note: @escaping (String) -> Void) -> Task<Void, Never>? {
        window(args.voiceOpts.failProjection, "-CuePadVoiceFailProjection") { seconds in
            note("projection-fail \(seconds)")
            projectionFailsUntil = .now + .seconds(seconds)
        }
    }

    /// `<在听后秒>,<多久秒>`：到点做 `start`（参数是多久）；没给就不起。
    private static func window(_ spec: String?, _ name: String, start: @escaping (Double) -> Void) -> Task<Void, Never>? {
        guard let spec else { return nil }
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { abandon("\(name) 要写成 <在听后秒>,<多久秒>", CocoaError(.formatting)) }
        return Task {
            guard await Task.wait(for: .seconds(parts[0])) else { return }
            start(parts[1])
        }
    }
}
#endif
