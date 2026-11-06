/// 在跑的一趟一趟的事：同一类事同一时刻只做一件。
final class Flights {
    /// 分享队列入库（`AppServices.drainCaptures`）在跑的那一趟，与跑的时候又被要过一次。
    var captureDrain: Task<Void, Never>?
    var captureDrainAgain = false
    /// 快照发布（`AppServices.present`）排队的队尾：一份发完才轮到下一份，先进先出。
    var snapshotTurn: Task<Void, any Error>?
}
