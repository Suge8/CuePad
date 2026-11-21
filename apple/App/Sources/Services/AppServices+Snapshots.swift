import CueStore
import Foundation
#if os(iOS)
import UIKit
#endif

extension AppServices {
    func startSnapshots() {
        follow(reporting: { .widgetDataUnavailable("\($0)") }) {
            for try await seen in self.cueUpdates() {
                guard seen.read.widget != nil else { continue }
                try await self.snapshots.writeSnapshots()
            }
        }
    }

    #if os(iOS)
    /// 实时活动只能在前台开：启动到变成 active 之前（inactive）也算前台，库读完的第一份就能开，不等下一次变化。
    private static var inForeground: Bool { UIApplication.shared.applicationState != .background }
    #endif

    var knowsActivityState: Bool { syncing.state.reconciled && syncing.state.status.reachesMac }

    func activityState(_ digest: @autoclosure () throws -> CueDigest) throws -> CueActivityState? {
        guard knowsActivityState else { return nil }
        return try ActivityPush.fitted(CueActivityState(now: Self.cueNow(try digest(), at: speech, local: CueNow.Local(waiting: nil, here: nil))))
    }

    func activityNewest(_ digest: CueDigest) -> CueNow.Item? {
        var moment = speech
        moment.now = .now
        return CueNow.newest(digest, at: moment)
    }

    static func cueNow(_ digest: CueDigest, at moment: Speech.Moment, local: CueNow.Local) -> CueNow {
        var moment = moment
        moment.now = .now
        return DebugHooks.cueNow ?? CueNow(digest, at: moment, local: local)
    }

    var cueLocal: CueNow.Local {
        #if os(macOS)
        let here: String? = hostID
        #else
        let here: String? = nil
        #endif
        return CueNow.Local(waiting: CueGate.of(self, running: nil, name: nil).waitingReason, here: here)
    }

    func resendSnapshots() async {
        do {
            try await snapshots.writeSnapshots(resend: true)
        } catch {
            reportIssue(.widgetDataUnavailable("\(error)"))
        }
    }

    func present(_ digest: CueDigest, first: Bool, resend: Bool) async throws -> CueNow {
        let now = Self.cueNow(digest, at: speech, local: cueLocal)
        #if os(iOS)
        await cueActivity?.show(try ActivityPush.fitted(CueActivityState(now: now)), resend: resend || first, foreground: Self.inForeground)
        await alerts?.showBadge(now.needsYou)
        #endif
        return now
    }
}

nonisolated struct WidgetSnapshots: Equatable, Sendable {
    var projects: ProjectsSnapshot
    var home: DefaultProjectSnapshot
    var cue: CueNow

    init(_ content: WidgetContent, now: CueNow) {
        projects = content.projects
        home = content.home
        cue = now
    }

    static func == (a: Self, b: Self) -> Bool { a.projects == b.projects && a.home == b.home && a.cue.same(as: b.cue) }
}

nonisolated struct WidgetContent: Equatable, Sendable {
    var projects: ProjectsSnapshot
    var home: DefaultProjectSnapshot
}

extension CueStore {
    fileprivate static let widgetCardLimit = 5

    func widgetContent() throws -> WidgetContent {
        let cards = try cards(in: Project.defaultID)
        let latest = cards.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(Self.widgetCardLimit)
        return WidgetContent(
            projects: ProjectsSnapshot(projects: try projects().map {
                ProjectsSnapshot.Entry(id: $0.id, name: $0.name, color: $0.color, icon: $0.icon)
            }),
            home: DefaultProjectSnapshot(
                name: try project(Project.defaultID)?.name ?? "",
                cards: latest.map {
                    DefaultProjectSnapshot.Card(id: $0.id, title: $0.heading, modifiedAt: $0.modifiedAt)
                },
                total: cards.count))
    }
}
