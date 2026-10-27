import CueStore
import Foundation

nonisolated enum SendError: Error, Equatable {
    /// 正文里的附件（图片或文件）不在这台 Mac 上、也没取到。
    case attachmentUnavailable(String)
    /// 手机指定的 Pi 会话已结束，或不在这台 Mac 上。
    case sessionNotOnThisMac(String)
    /// 这台 Mac 不支持的投送目标（来自更新版本或缺少必要信息）。
    case unsupportedTarget(String)
    /// 本版本不认识的发送方式（来自更新版本的手机）。
    case unsupportedMode(String)
    /// 发给 Pi 的投送请求没能送达（附执行器写回的原因）。
    case notDelivered(String)
    /// 开新会话没开成（附原因）。
    case notLaunched(String)
    /// 这台（`here`）或那台 Mac 上一家能开会话的 Agent 都没有（附原因，`MacAgents.whyNone`）。
    case noAgent(here: Bool, String)
    /// 问题只能在 Pi 里回答（多行编辑、自定义界面）。
    case unanswerable
    /// 这台 Mac 上找不到这个会话的会话文件（被删了，或不是这台 Mac 上的会话）。
    case piSessionNotOnThisMac
    /// 手机请这台 Mac 绑成另一个项目的目录，而那个项目还没有绑定文件夹。
    case noCodeDirectory(String)
    /// 要开会话的项目还没同步到这台 Mac（不知道工作区叫什么）。
    case projectNotHere
    /// 要在里面启动 Pi 的目录不在了（被删或改名），附目录末段名。
    case directoryMissing(String)
    /// 话已被 Mac 领取、交给了 Agent，撤不回。
    case alreadyHanded
    /// 对 Cue 说的话已交给了它，撤不回。
    case alreadyHeard
    /// 查订阅额度要经在线 Agent 会话里的扩展，这台 Mac 上此刻没有。
    case noLiveSession
}

extension SendError: ShownError {
    var shown: String.LocalizationValue {
        switch self {
        case .attachmentUnavailable: "正文里有附件找不到了，无法发送"
        case .sessionNotOnThisMac(let name): "Agent 会话「\(name)」已经结束，或不在这台 Mac 上"
        case .unsupportedTarget(let name): "这台 Mac 不支持发送到「\(name)」"
        case .unsupportedMode(let raw): "这台 Mac 上的 CuePad 不认识这种发送方式（\(raw)），请更新"
        case .notDelivered(let reason): "没能送达：\(reason)"
        case .notLaunched(let reason): "没开成会话：\(reason)"
        case .noAgent(true, let why): "这台 Mac 上开不了会话：\(why)"
        case .noAgent(false, let why): "那台 Mac 上开不了会话：\(why)"
        case .unanswerable: "这个问题只能在 Mac 终端里的 Agent 那边回答"
        case .piSessionNotOnThisMac: "这台 Mac 上找不到这个会话（会话文件可能已被删除）"
        case .noCodeDirectory(let project): "项目「\(project)」还没有绑定文件夹，不知道目录在哪"
        case .projectNotHere: "这个项目还没同步到这台 Mac，稍后再开"
        case .directoryMissing(let folder): "目录不存在：\(folder)"
        case .alreadyHanded: "Mac 已经把它发给 Agent，撤不回了"
        case .alreadyHeard: "Cue 已经收到这句了，撤不回"
        case .noLiveSession: "这台 Mac 上没有在线的 Agent 会话，查不了额度"
        }
    }
}
