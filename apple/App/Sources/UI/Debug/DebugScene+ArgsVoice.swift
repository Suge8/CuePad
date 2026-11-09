#if DEBUG

/// Mac 端与 Cue 通话的参数（`DebugScene+Voice.swift`）。
/// 键 = `-CuePad` + 前缀「Voice」 + 字段名（大小写不论）；没给：Bool 为 false、数为 0、可选为 nil。
nonisolated struct VoiceArgs: Decodable, DebugArgGroup {
    static let prefix = "Voice"
    /// `-CuePadVoiceCloseSeconds <秒>`：通话多久后关闭
    let closeSeconds: Double
    /// `-CuePadVoiceDevice <设备名片段>`：指定麦克风设备（不改变系统默认输入）
    let device: String?
    /// `-CuePadVoiceHangUpAfterReply YES`：结果送出后观察到实际输出、模型回合结束且音轨安静才挂断
    let hangUpAfterReply: Bool
    /// `-CuePadVoiceHistory <条数>`：通话面板预置的历史条数
    let history: Int
    /// `-CuePadVoiceKeepOpen YES`：首轮挂断后保留窗口，供真实按钮重连与结果阅读验收
    let keepOpen: Bool
    /// `-CuePadVoiceLayout <布局>`：语音面板布局样例
    let layout: String?
    /// `-CuePadVoiceLightProbe YES`：语音面板亮度探针
    let lightProbe: Bool
    /// `-CuePadVoiceLog <文件>`：`<距起点秒> <节点>`
    let log: String?
    /// `-CuePadVoiceLoopback <目录>`：以本进程 tap 做临时麦克风（`VoiceLoopback`），按节点播 first.wav、interrupt.wav、stop.wav
    let loopback: String?
    /// `-CuePadVoiceMeter YES`：只测本地 getUserMedia，不建实时通话、不调用 Cue
    let meter: Bool
    /// `-CuePadVoiceModel <模型>`：指定其他已在隔离目录登录的模型
    let model: String?
    /// `-CuePadVoiceMotion <名称|rapid>`：语音面板动效样例
    let motion: String?
    /// `-CuePadVoiceMotionTrace YES`：语音面板动效逐帧打点
    let motionTrace: Bool
    /// `-CuePadVoiceProcessing <echo|noise|gain|all>`：将指定处理约束设为 false
    let processing: String?
    /// `-CuePadVoiceReadFixture <原文>`：把原文作为隔离库的主动消息请 GPT Live 朗读，录成后续验收的声源
    let readFixture: String?
    /// `-CuePadVoiceReadings YES`：通话读数打点
    let readings: Bool
    /// `-CuePadVoiceRecord <wav>`：把通话声音录成文件（不外放，无人值守）
    let record: String?
    /// `-CuePadVoiceReplay YES`：Cue 结果送出后重放原 delegation 与用户 turn.done，核对请求没有重复落库
    let replay: Bool
    /// `-CuePadVoiceRuntime <pi|codex|claude>`：指定其他已在隔离目录登录的运行时
    let runtime: String?
    /// `-CuePadVoiceScenario <名称>`：通话布局场景（`DebugVoiceLayoutScenario`）
    let scenario: String?
    /// `-CuePadVoiceSeconds <秒>`（默认 60）：通话这么久后挂断
    let seconds: Double?
    /// `-CuePadVoiceToken <文件>` 读（`scripts/voice-token.py` 经本机 Codex app-server 获取，续期语义见 CodexAccess）：隔离目录里的 Codex 没登录
    let token: String?
    /// `-CuePadVoiceWireLog <文件>`：通话协议的收发日志
    let wireLog: String?
}
#endif
