import Foundation

nonisolated enum SendError: Error, Equatable {
    /// 正文引用的图片找不到或读不出来。
    case imageUnavailable(String)
    /// 目标只收文字，而正文含图片。
    case imagesNotSupported
    /// Pi 会话正在工作，且调用方没有指定插话或排队。
    case piSessionBusy
}

extension SendError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .imageUnavailable: "正文里有图片找不到了，无法发送"
        case .imagesNotSupported: "这个目标只能接收文字，请先移除图片"
        case .piSessionBusy: "Pi 会话正在工作，请选择插话或排队"
        }
    }
}
