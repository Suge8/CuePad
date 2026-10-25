import CueStore
import Foundation
import Observation

/// 说的话到哪了（`Speech`）的外部输入，全 App 一份：此刻与本机同步从什么时候起通着（`moment`）。
/// 到点翻状态只靠这里：资料库里还在等的话（`track`，`AppServices.startSpeechClock` 跟着库给，服务器收下时也重给）最早到时限的那一刻把"此刻"刷一次
/// （一个可取消的睡眠，不轮询），同步断开、恢复时也刷。气泡、会话行与"N 句没送到"、提示词、Cue 在不在与值班都读 `moment`，不各自计时。
@Observable
final class SpeechClock {
    private(set) var moment: Speech.Moment
    @ObservationIgnored private var waiting: [Awaiting] = []
    @ObservationIgnored private var alarm: Task<Void, Never>?
    /// 同步一直算通（演示 Mac 在本机库里接手，`DebugHooks.Preset.alwaysReachable`）。
    @ObservationIgnored private let alwaysReachable: Bool
    @ObservationIgnored private let timing: Timing

    /// 一句还没被接收方领取、交出的话：写下的时刻、服务器收下过没有与接收它的那台 Mac。
    nonisolated struct Awaiting: Equatable, Sendable {
        var said: Date
        var reachedServer: Bool
        var host: String?
    }

    init(localHost: String?, reachable: Bool, alwaysReachable: Bool, timing: Timing) {
        self.alwaysReachable = alwaysReachable
        self.timing = timing
        let now = timing.now()
        moment = Speech.Moment(now: now, reachableSince: reachable || alwaysReachable ? now : nil, localHost: localHost)
    }

    /// 本机同步此刻通不通（`SyncStatus.reachesMac`）：恢复的那一刻起重新算时限；断开时已发出的话不计时，没发出的从写下算。
    func setReachable(_ reachable: Bool) {
        guard !alwaysReachable, reachable != (moment.reachableSince != nil) else { return }
        let now = timing.now()
        moment = Speech.Moment(now: now, reachableSince: reachable ? now : nil, localHost: moment.localHost)
        schedule()
    }

    /// 此刻还在等回执的话（库一变就给一次）。
    func track(_ waiting: [Awaiting]) {
        guard waiting != self.waiting else { return }
        self.waiting = waiting
        schedule()
    }

    /// 已经过了的时限立即刷"此刻"，再睡到下一个。
    private func schedule() {
        alarm?.cancel()
        let deadlines = waiting.compactMap { Speech.deadline(said: $0.said, delivered: nil, reachedServer: $0.reachedServer, host: $0.host, at: moment) }
        let now = timing.now()
        if deadlines.contains(where: { $0 > moment.now && $0 <= now }) { moment.now = now }
        guard let next = deadlines.filter({ $0 > now }).min() else { return }
        alarm = Task { [weak self, timing] in
            guard (try? await timing.sleepUntil(next)) != nil else { return }
            self?.schedule()
        }
    }
}

extension AppServices {
    /// 跟着资料库给出还在等回执的话（`SpeechClock.track`）与有没有还没结果的请求（`hasOpenDeliveries`，主动拉取的条件）：
    /// 还没被领取的投送请求，与你对 Cue 说了、还没交给它的话。一个订阅读一次。读失败时报告并停止（到点不再翻、不再主动拉）。
    func startSpeechClock() {
        follow(reporting: { .syncUnavailable("读取在等回执的话失败，到点不再翻状态、不再主动拉取：\($0)") }) {
            for try await open in self.store.observe({ store in
                let requests = try store.deliveryRequests().filter(\.isOpen)
                let cueHost = try store.cueProfile()?.hostID
                let toCue = try store.cueMessagesToDeliver().filter { $0.author == .known(.you) }
                let waiting = requests.filter(\.isWithdrawable).map { SpeechClock.Awaiting(said: $0.createdAt, reachedServer: $0.reachedServer, host: $0.hostID) }
                    + toCue.map { SpeechClock.Awaiting(said: $0.createdAt, reachedServer: $0.reachedServer, host: cueHost) }
                return OpenSpeech(open: !requests.isEmpty || !toCue.isEmpty, waiting: waiting)
            }) {
                self.hasOpenDeliveries = open.open
                self.speechClock.track(open.waiting)
            }
        }
    }

    /// 等在路上的那些话（`startSpeechClock` 一次读到的）。
    private nonisolated struct OpenSpeech: Equatable, Sendable {
        var open: Bool
        var waiting: [SpeechClock.Awaiting]
    }

    /// 此刻（`SpeechClock.moment`）：读它的视图到点、同步通断时随之重算。
    var speech: Speech.Moment { speechClock.moment }

    /// 读库并配上此刻：库变了重读，此刻变了（到点、同步通断）把手里那份连同新的此刻再给一次——读的东西不随此刻变，
    /// 说的话到哪了（时限、Cue 在不在值班）在读到之后按此刻推，不各自计时。给了 `snapshot` 就从它接着订阅，不重读。读失败时流以错误结束。
    func observeTimed<T: Sendable & Equatable>(
        from snapshot: Snapshot<T>? = nil, _ read: @escaping @Sendable (isolated CueStore) throws -> T
    ) -> AsyncThrowingStream<(T, Speech.Moment), any Error> {
        let values = snapshot.map { store.observe(from: $0, read) } ?? store.observe(read)
        let clock = speechClock
        return AsyncThrowingStream { continuation in
            let latest = Latest(value: snapshot?.value)
            let reading = Task {
                do {
                    for try await value in values {
                        latest.value = value
                        continuation.yield((value, clock.moment))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let ticking = Task {
                for await moment in Observations({ clock.moment }) {
                    if let value = latest.value { continuation.yield((value, moment)) }
                }
            }
            continuation.onTermination = { _ in
                reading.cancel()
                ticking.cancel()
            }
        }
    }
}

extension AppServices {
    /// 同 `observeTimed`，再配上 Cue 此刻要的本机事实（`cueLocal`）：它变了（这台和 iCloud 对过了、断网了）也把手里那份再给一次，
    /// 库没变也换得掉"正在从 iCloud 同步…"。Cue 的现状（`CueFeed`，Cue 那一行与小组件快照共用）经它。
    func observeCue<T: Sendable & Equatable>(
        from snapshot: Snapshot<T>? = nil, _ read: @escaping @Sendable (isolated CueStore) throws -> T
    ) -> AsyncThrowingStream<(T, Speech.Moment, CueNow.Local), any Error> {
        let timed = observeTimed(from: snapshot, read)
        return AsyncThrowingStream { continuation in
            let latest = Latest<(T, Speech.Moment)>(value: nil)
            let reading = Task {
                do {
                    for try await (value, moment) in timed {
                        latest.value = (value, moment)
                        continuation.yield((value, moment, self.cueLocal))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            let watching = Task {
                for await local in Observations({ self.cueLocal }) {
                    if let (value, moment) = latest.value { continuation.yield((value, moment, local)) }
                }
            }
            continuation.onTermination = { _ in
                reading.cancel()
                watching.cancel()
            }
        }
    }
}

/// `observeTimed` 手里最近读到的那份：此刻变了时配上它再给一次。
private final class Latest<T> {
    var value: T?
    init(value: T?) { self.value = value }
}
