import CueStore
import Foundation

/// 会话计时怎么读（Mac 与手机同一条）：工作中"已运行"从这段连续处理开始算（思考、工具、等子代理之间切换不重置），
/// 等你确认"已等"从进入等待算，空闲、出错、已结束是"多久前"。
enum PiClock: Equatable {
    case running(since: Date)
    case waiting(since: Date)
    case ago(Date)

    static func reading(_ state: Open<PiWorkState>, stateSince: Date, busySince: Date?) -> PiClock {
        if state == .known(.waitingForUser) { return .waiting(since: stateSince) }
        // 旧版本写的记录没有 busySince：退回进入当前状态的时间
        if state.isWorking { return .running(since: busySince ?? stateSince) }
        return .ago(stateSince)
    }
}
