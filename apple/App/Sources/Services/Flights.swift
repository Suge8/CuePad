/// 在跑的一趟一趟的事：同一类事同一时刻只做一件。
final class Flights {
    var captureDrain: Task<Void, Never>?
    var captureDrainAgain = false
    var snapshotTicket = 0
    var snapshotTurn: Task<Bool, any Error>?
}
