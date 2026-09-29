import Foundation
import Observation
import CueStore
import CueEditor
#if os(macOS)
import CueDispatch
import CuePi
#endif

/// 组合根与界面动作的唯一入口：持有各模块的唯一实例。
/// 界面读数据直接 `store.observe(...)`；一切副作用（投送、复制、Pi 命令、终端跳转、导入、扩展安装）只经这里，
/// 发送记录也只在这里写。本文件的公开形状由主会话冻结：界面 Worker 与服务 Worker 并行开发，需要增改成员先找主会话。
@MainActor @Observable
final class AppServices {
    let store: CueStore
    let images: any CueImageStore
    #if os(macOS)
    let pi: PiBridge
    #endif

    /// 发往哪里。正文一律是存储格式（变量已填、编号已排），图片引用由这里解析成真实图片。
    enum Destination: Equatable {
        #if os(macOS)
        /// 直接发进 Pi 会话；`whenBusy` 为 nil 时会话忙则报错，否则插话或排队。
        case pi(PiSession.ID, whenBusy: PiQueueMode?)
        /// 只把文字放进 Pi 输入框（含图片时由调用方禁用此项）。
        case piInput(PiSession.ID)
        /// 通用投送：剪贴板 + 激活目标 + 定向粘贴，可选回车。
        case app(TargetSelector, submit: Bool)
        #endif
        /// 只复制到剪贴板。
        case clipboard
    }

    /// 发送并写一条发送记录；失败不写记录，错误原样抛给界面展示。
    func send(_ storedText: String, to destination: Destination, card: UUID? = nil, task: UUID? = nil) async throws {
        fatalError("服务 Worker 实现")
    }

    init() {
        fatalError("服务 Worker 实现")
    }
}
