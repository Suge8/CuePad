/// 在跑的一趟一趟的事：同一类事同一时刻只做一件。
final class Flights {
    /// 分享队列入库（`AppServices.drainCaptures`）在跑的那一趟，与跑的时候又被要过一次。
    var captureDrain: Task<Void, Never>?
    var captureDrainAgain = false
    /// 快照更新（`AppServices.writeSnapshots`）：最新一个请求的序号，与排队的队尾（一份做完才轮到下一份）。
    var snapshotTicket = 0
    var snapshotTurn: Task<Bool, any Error>?
}
