import Foundation

/// ActivityKit 的线上信封：内容用系统默认 Codable 策略，只有 aps 的时间戳是 Unix 秒。
/// 同一份内容也给本地 ActivityKit；4 KB 预算包含信封，绝不把超限的更新交给系统后误报成功。
nonisolated struct ActivityPush: Encodable, Sendable {
    var token: String
    var environment: String
    var priority: Int
    var expiration: Int
    var payload: Payload

    struct Payload: Encodable, Sendable {
        var aps: APS

        init(_ state: CueActivityState) {
            let now = state.now
            aps = APS(
                timestamp: Int(now.at.timeIntervalSince1970), event: now.isLive ? "update" : "end", state: state,
                staleDate: now.isLive ? Int((now.nextShownChange(after: now.at) ?? now.staleAt).timeIntervalSince1970) : nil,
                dismissalDate: now.isLive ? nil : Int((now.nextChange(after: now.at) ?? now.at).timeIntervalSince1970))
        }

        static func clearing(_ state: CueActivityState) -> Payload {
            var payload = Payload(state)
            payload.aps.event = "end"
            payload.aps.staleDate = nil
            payload.aps.dismissalDate = payload.aps.timestamp
            return payload
        }

        /// 远程开一只：系统要求带提醒（不带的苹果照收、岛不出现），不带声音——该响的那一下归通知。
        /// `startedAt` 进活动的属性，手机接住时按它认最新的一只。
        static func starting(_ state: CueActivityState, startedAt: Date, title: String, body: String) -> Payload {
            var payload = Payload(state)
            payload.aps.event = "start"
            payload.aps.attributesType = "CueActivityAttributes"
            payload.aps.attributes = Attributes(startedAt: startedAt)
            payload.aps.alert = Alert(title: clipped(title, bytes: 120), body: Alert.Key(key: body))
            payload.aps.inputPushToken = 1
            return payload
        }
    }

    /// 同手机上的 `CueActivityAttributes`（系统按默认 Codable 策略解，日期是 2001 年起的秒）。
    struct Attributes: Encodable, Sendable {
        var startedAt: Date
        var remoteUpdates = true
    }

    struct Alert: Encodable, Sendable {
        var title: String
        var body: Key

        struct Key: Encodable, Sendable {
            var key: String
            enum CodingKeys: String, CodingKey { case key = "loc-key" }
        }
    }

    struct APS: Encodable, Sendable {
        var timestamp: Int
        var event: String
        var state: CueActivityState
        var staleDate: Int?
        var dismissalDate: Int?
        var attributesType: String?
        var attributes: Attributes?
        var alert: Alert?
        var inputPushToken: Int?

        enum CodingKeys: String, CodingKey {
            case timestamp, event, attributes, alert
            case state = "content-state"
            case staleDate = "stale-date"
            case dismissalDate = "dismissal-date"
            case attributesType = "attributes-type"
            case inputPushToken = "input-push-token"
        }
    }

    static let byteLimit = 4_096
    static let startOverhead = 384

    struct Oversized: Error {}

    static func fitted(_ original: CueActivityState) throws -> CueActivityState {
        func fits(_ value: CueActivityState) throws -> Bool { try JSONEncoder().encode(Payload(value)).count <= byteLimit - startOverhead }
        if try fits(original) { return original }
        var state = original
        state.now.name = clipped(state.now.name, bytes: 80)
        state.now.elsewhere = nil
        switch state.now.cue {
        case .away(let why, let failed): state.now.cue = .away(clipped(why, bytes: 200), failed: failed)
        case .working(let woke, let doing, let since):
            state.now.cue = .working(woke: woke.map { clipped($0, bytes: 160) }, doing: doing.map { clipped($0, bytes: 200) }, since: since)
        case .idle, .hearing: break
        }
        if var first = state.now.first {
            first.title = clipped(first.title, bytes: 160)
            first.detail = first.detail.map { clipped($0, bytes: 200) }
            state.now.first = first
        }
        state.now.items = state.now.items.map {
            var item = $0
            item.name = clipped(item.name, bytes: 160)
            return item
        }
        while try !fits(state), let index = state.now.items.lastIndex(where: { $0.kind != .done }) { state.now.items.remove(at: index) }
        if try !fits(state) { state.now.first?.detail = nil }
        if try !fits(state) { state.now.first?.allow = nil }
        guard try fits(state) else { throw Oversized() }
        return state
    }

    private static func clipped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count + "…".utf8.count <= bytes else { break }
            result.append(character)
        }
        return result + "…"
    }
}
