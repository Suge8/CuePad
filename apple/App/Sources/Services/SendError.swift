import CueStore
import Foundation

nonisolated enum SendError: Error, Equatable {
    case attachmentUnavailable(String)
    /// 手机指定的 Pi 会话已结束，或不在这台 Mac 上。
    case sessionNotOnThisMac(String)
    /// 这台 Mac 不支持的投送目标（来自更新版本或缺少必要信息）。
    case unsupportedTarget(String)
    /// 本版本不认识的发送方式（来自更新版本的手机）。
    case unsupportedMode(String)
    /// 发给 Pi 的投送请求没能送达（附执行器写回的原因）。
    case notDelivered(String)
    /// 这台（`here`）或那台 Mac 上一家能开会话的 Agent 都没有（附原因，`MacAgents.whyNone`）。
    case noAgent(here: Bool, String)
    /// 问题只能在 Pi 里回答（多行编辑、自定义界面）。
    case unanswerable
    /// 这台 Mac 上找不到这个会话的会话文件（被删了，或不是这台 Mac 上的会话）。
    case sessionFileMissing
    /// 手机请这台 Mac 绑成另一个项目的目录，而那个项目还没有绑定文件夹。
    case noCodeDirectory(String)
    case projectNotHere
    /// 要在里面启动 Pi 的目录不在了（被删或改名），附目录末段名。
    case directoryMissing(String)
    /// 已领取、已进入同步发送，或本机快照不足以证明尚未交出，不能安全撤回。
    case alreadyHanded
    case alreadyHeard
    /// 要它做事的那台 Mac 已知不在线（参数是它的名字），请求没有写下。
    case macOff(String)
}

extension SendError: ShownError {
    var shown: String.LocalizationValue {
        switch self {
        case .attachmentUnavailable: "正文里有附件找不到了，无法发送"
        case .sessionNotOnThisMac(let name): "Agent 会话「\(name)」已经结束，或不在这台 Mac 上"
        case .unsupportedTarget(let name): "这台 Mac 不支持发送到「\(name)」"
        case .unsupportedMode(let raw): "这台 Mac 上的 CuePad 不认识这种发送方式（\(raw)），请更新"
        case .notDelivered(let reason): "没能送达：\(reason)"
        case .noAgent(true, let why): "这台 Mac 上开不了会话：\(why)"
        case .noAgent(false, let why): "那台 Mac 上开不了会话：\(why)"
        case .unanswerable: "这个问题只能在 Mac 终端里的 Agent 那边回答"
        case .sessionFileMissing: "这台 Mac 上找不到这个会话（会话文件可能已被删除）"
        case .noCodeDirectory(let project): "项目「\(project)」还没有绑定文件夹，不知道目录在哪"
        case .projectNotHere: "这个项目还没同步到这台 Mac，稍后再开"
        case .directoryMissing(let folder): "目录不存在：\(folder)"
        case .alreadyHanded: "这句可能已经交出，不能安全撤回"
        case .alreadyHeard: "Cue 已经收到这句了，撤不回"
        case .macOff(let mac): "「\(mac)」没开，没有发出"
        }
    }
}
