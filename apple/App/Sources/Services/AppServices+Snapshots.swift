import CueStore
import Foundation
#if os(iOS)
import UIKit
#endif

/// 扩展不打开资料库。
/// 只写内容真正变了的那份；小组件显示默认项目与 Cue，只有这两份变了才刷新它们（刷新次数有系统预算）。
/// 每次运行的第一份全写、本地活动照发：留在共享容器与系统里的那份可能是旧版本写的，结构变了这版就解不出来（小组件读成空的），不能拿它比。
/// 本地实时活动与小组件读同一份 Cue 此刻；远程活动只用它开启，已有内容由 Mac 经 APNs 更新（`CueLiveActivity`）。
extension AppServices {
    func startSnapshots() {
        follow(reporting: { .widgetDataUnavailable("\($0)") }) {
            for try await seen in self.cueUpdates() {
                guard seen.read.widget != nil else { continue }
                try await self.snapshots.writeSnapshots()  // 观察只当通知：读在发布的串行段里重做，见 writeSnapshots
            }
        }
    }

    #if os(iOS)
    /// 实时活动只能在前台开：启动到变成 active 之前（inactive）也算前台，库读完的第一份就能开，不等下一次变化。
    private static var inForeground: Bool { UIApplication.shared.applicationState != .background }

    /// 远程活动只在身份已确认且资料已对账后开启；不用 CueFeed 在换号、清库前排队的旧快照。
    func remoteActivityState() throws -> CueActivityState? {
        guard syncing.state.reconciled, [.idle, .syncing].contains(syncing.state.status) else { return nil }
        let digest = try store.snapshot { try CueDigest.read(from: $0) }.value
        return try ActivityPush.fitted(CueActivityState(now: Self.cueNow(digest, at: speech, local: cueLocal)))
    }
    #endif

    /// 小组件、实时活动与 Cue 那一行（`CueWatch`）都经这里推。
    /// 按推出的这一刻推：说的话的此刻（`SpeechClock`）只在时限到点、同步通断时走，库变了时它可能停在很久以前，
    /// 拿它算会把早过了 `doneWindow` 的"刚做完"当成新的、过时时刻也从那时算。
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

    /// 不依赖观察任务赶在挂起前执行；前台重开、后台收尾都显式等这一份完成。
    func resendSnapshots() async {
        do {
            try await snapshots.writeSnapshots(resend: true)
        } catch {
            reportIssue(.widgetDataUnavailable("\(error)"))
        }
    }

    /// 按读到的摘要推出此刻，发布小组件之外跟着它的（手机的实时活动与角标），返回给小组件的那份；`first` 是这次运行的第一份。
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

    /// Cue 此刻随此刻推（在不在、话在不在路上、表情，`AppServices.cueNow`），读库的那份不随。
    init(_ content: WidgetContent, now: CueNow) {
        projects = content.projects
        home = content.home
        cue = now
    }

    /// 只比内容（Cue 此刻推出的时刻不算）：内容一样就不重写、不刷新小组件。
    static func == (a: Self, b: Self) -> Bool { a.projects == b.projects && a.home == b.home && a.cue.same(as: b.cue) }
}

/// 小组件除 Cue 之外从库里读的那份（与 Cue 的摘要同一次读，`CueFeed.Read`）。
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
