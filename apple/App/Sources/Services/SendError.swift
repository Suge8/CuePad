import Foundation

nonisolated enum SendError: Error, Equatable {
    /// 正文引用的图片找不到或读不出来。
    case imageUnavailable(String)
    /// 目标只收文字，而正文含图片。
    case imagesNotSupported
    /// Pi 会话正在工作，且调用方没有指定插话或排队。
    case piSessionBusy
    /// 手机指定的 Pi 会话已结束，或不在这台 Mac 上。
    case sessionNotOnThisMac(String)
    /// 这台 Mac 不支持的投送目标（来自更新版本或缺少必要信息）。
    case unsupportedTarget(String)
    /// 本版本不认识的发送方式（来自更新版本的手机）。
    case unsupportedMode(String)
}

extension SendError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .imageUnavailable: "正文里有图片找不到了，无法发送"
        case .imagesNotSupported: "这个目标只能接收文字，请先移除图片"
        case .piSessionBusy: "Pi 会话正在工作，请选择插话或排队"
        case .sessionNotOnThisMac(let name): "Pi 会话「\(name)」已经结束，或不在这台 Mac 上"
        case .unsupportedTarget(let name): "这台 Mac 不支持发送到「\(name)」"
        case .unsupportedMode(let raw): "这台 Mac 上的 CuePad 不认识这种发送方式（\(raw)），请更新"
        }
    }
}
