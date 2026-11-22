import Foundation

nonisolated struct ActivityDiagnosticReport: Codable, Sendable {
    static let eventLimit = 96
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    var events: [Event] = []

    struct Event: Codable, Sendable {
        enum Action: String, Codable, Sendable {
            case processStarted, restore, request, created, blocked, endRequested, invalidated
            case stateObserved, contentObserved, destinationWrite, destinationRemove, destinationResult, appPhase
        }

        var at: Date
        var run: UUID
        var sequence: Int
        var build: String
        var action: Action
        var activity: String?
        var reason: String?
        var sourceAt: Date?
        var contentTag: String?
        var tokenTag: String?
        var foreground: Bool?
        var errorDomain: String?
        var errorCode: Int?

        init(
            at: Date = .now, run: UUID, sequence: Int, build: String, action: Action, activity: String? = nil,
            reason: String? = nil, sourceAt: Date? = nil, contentTag: String? = nil, tokenTag: String? = nil, foreground: Bool? = nil,
            errorDomain: String? = nil, errorCode: Int? = nil
        ) {
            self.at = at
            self.run = run
            self.sequence = sequence
            self.build = build
            self.action = action
            self.activity = activity
            self.reason = reason
            self.sourceAt = sourceAt
            self.contentTag = contentTag
            self.tokenTag = tokenTag
            self.foreground = foreground
            self.errorDomain = errorDomain
            self.errorCode = errorCode
        }
    }

    mutating func append(_ event: Event) {
        events.removeAll { $0.at < event.at.addingTimeInterval(-Self.retention) }
        let next = events.firstIndex { $0.run == event.run && $0.sequence > event.sequence }
        let afterRun = events.lastIndex { $0.run == event.run }.map { $0 + 1 }
        events.insert(event, at: next ?? afterRun ?? events.endIndex)
        events = events.reduce(into: []) { kept, item in
            if let last = kept.last, [.contentObserved, .blocked].contains(item.action),
                last.run == item.run, last.action == item.action, last.activity == item.activity,
                last.reason == item.reason, last.sourceAt == item.sourceAt, last.contentTag == item.contentTag,
                last.foreground == item.foreground, last.errorDomain == item.errorDomain, last.errorCode == item.errorCode
            {
                kept.removeLast()
            }
            kept.append(item)
        }
        if events.count > Self.eventLimit { events.removeFirst(events.count - Self.eventLimit) }
    }
}
