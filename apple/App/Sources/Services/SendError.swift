import CueStore
import Foundation

nonisolated enum SendError: Error, Equatable {
    case attachmentUnavailable(String)
    case sessionNotOnThisMac(String)
    case unsupportedTarget(String)
    case unsupportedMode(String)
    case notDelivered(String)
    case noAgent(here: Bool, String)
    case unanswerable
    case sessionFileMissing
    case noCodeDirectory(String)
    case projectNotHere
    case directoryMissing(String)
    case alreadyHanded
    case withdrawalPending
    case alreadyHeard
    case macOff(String)
    case noReply
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
        case .unanswerable: "CuePad 答不了这类提问"
        case .sessionFileMissing: "这台 Mac 上找不到这个会话（会话文件可能已被删除）"
        case .noCodeDirectory(let project): "项目「\(project)」还没有绑定文件夹，不知道目录在哪"
        case .projectNotHere: "这个项目还没同步到这台 Mac，稍后再开"
        case .directoryMissing(let folder): "目录不存在：\(folder)"
        case .alreadyHanded: "这句可能已经交出，不能安全撤回"
        case .withdrawalPending: "那台 Mac 还没回音：它收到撤回时这句还没发出就会撤掉"
        case .alreadyHeard: "Cue 已经收到这句了，撤不回"
        case .macOff(let mac): "「\(mac)」没开，没有发出"
        case .noReply: "那台 Mac 没有回音"
        }
    }
}
