import CueStore
import Foundation

/// Cue 自己醒来的一轮在 Cue 页对话里的样子（`CueNoteBubble` 里的一节）：这一轮的经过那一行（为什么醒、做了什么）与它这一轮说的话。
/// 旧版本写下的动态可能没有经过那一行（只有正文），也可能经过那一行上没有醒来原因（`header` 为 nil）。
nonisolated struct CueNoteRound: Identifiable, Equatable, Sendable {
    /// 经过那一行；设置里关了工具步骤时去掉清单（`tools`）
    let row: CueMessage?
    /// 第一行：为什么醒（`CueMessage.wake`）
    let header: CueWakeHeader?
    /// 动过手：经过里有一步不只是看看（`Kind.looks`，同 `CueRound.acted`）
    let acted: Bool
    /// 这一轮说的话（动态的正文），从早到晚
    var said: [CueMessage]

    init(row: CueMessage, showsSteps: Bool, names: CueWakeNames) {
        var row = row
        acted = row.tools?.items.contains { !$0.kind.looks } ?? false
        header = row.wake.map { CueWakeHeader($0, names: names) }
        if !showsSteps { row.tools = nil }
        self.row = row
        said = []
    }

    init(said: CueMessage) {
        row = nil
        header = nil
        acted = false
        self.said = [said]
    }

    var id: UUID { row?.id ?? said[0].id }
    var date: Date { row?.createdAt ?? said[0].createdAt }
    /// 只看了看：做完了（不是在跑的 `live` 那一轮）、没动手、没说话（写"没动手"，连着几次并成一行）
    func quiet(live: UUID?) -> Bool { said.isEmpty && !acted && header != nil && id != live }
    /// 什么都不显示：没有醒来原因、没说话、清单也不显示
    var isEmpty: Bool { header == nil && said.isEmpty && row?.tools == nil }

    /// 写在 `date` 的一条动态还接在 `last` 这一节所在的那一格里：没隔 `ChatTime.gap`、没跨天（同时间那一行另起一段的规则）。
    static func continues(_ last: CueNoteRound, at date: Date) -> Bool {
        let end = last.said.last?.createdAt ?? last.date
        return date.timeIntervalSince(end) < ChatTime.gap && Calendar.current.isDate(date, inSameDayAs: end)
    }
}

/// 一节的第一行：为什么醒，与叫醒它的那几处（点了去那里）。为什么醒只画图标（`CueWake.icon`），字只写图标说不出的：会话的动静写"atlas 停下了"
/// （几处时"atlas 等 3 处有动静"），提醒写那条记忆；其余只有图标。一句固定的话（`reason`）只给读屏。名字读的时候查好（`CueWakeNames`）。
nonisolated struct CueWakeHeader: Equatable, Sendable {
    /// 点了去哪
    enum Target: Equatable, Sendable {
        case session(CueWakeNames.Session)
        case task(UUID)
        case memory
    }

    struct Place: Equatable, Sendable {
        let title: String
        let target: Target
    }

    let wake: CueWake
    /// 叫醒它的那一处叫什么（墨色加粗）
    let name: String?
    /// 名字后面的话（"停下了"）
    let trail: String?
    /// 叫醒它的会话出错、话没送到：图标换成出错的那个
    let failed: Bool
    /// 叫醒它的那几处（最新的在前）与各自的名字：一处点了直接去，几处点了列出来选；不在了的不列
    let targets: [Place]

    init(_ wake: CueWake, names: CueWakeNames) {
        self.wake = wake
        switch wake {
        case .sessionActivity(let stirs):
            var seen = Set<String>(), places: [(title: String, target: Target?)] = []
            for stir in stirs.reversed() where seen.insert(stir.session ?? stir.task?.uuidString ?? "").inserted {
                if let id = stir.session {
                    let session = names.sessions[id]
                    places.append((session?.title ?? "一个会话", session.map(Target.session)))
                } else if let task = stir.task {
                    places.append((names.tasks[task] ?? "一件任务", names.tasks[task] == nil ? nil : .task(task)))
                }
            }
            let latest = stirs.last
            name = places.first?.title
            trail = places.isEmpty ? nil : places.count > 1 ? "等 \(places.count) 处有动静" : latest.map { Self.verb($0.kind) }
            failed = latest.map { [.failed, .undelivered].contains($0.kind) } ?? false
            targets = places.compactMap { place in place.target.map { Place(title: place.title, target: $0) } }
        case .reminder(let ids):
            let first = ids.lazy.compactMap { names.lines[$0] }.first
            (name, failed) = (first.map { PiProgress.firstLine($0) ?? $0 }, false)
            trail = ids.count > 1 ? "等 \(ids.count) 条" : nil
            targets = first.map { [Place(title: $0, target: .memory)] } ?? []
        case .enabled, .message, .idle, .tidy, .renewed, .settingsChanged:
            (name, trail, failed, targets) = (nil, nil, false, [])
        }
    }

    /// 为什么醒的一句话（读屏读，界面上是图标）
    var reason: String {
        switch wake {
        case .enabled: "刚启用"
        case .message: "你发来消息"
        case .idle: "空闲时看了一眼"
        case .tidy: "整理记忆"
        case .renewed: "接着上次做"
        case .settingsChanged: "设置改了"
        case .sessionActivity: "会话有动静"
        case .reminder: "提醒到点"
        }
    }

    private static func verb(_ kind: CueChange.Kind) -> String {
        switch kind {
        case .settled: "停下了"
        case .waitingForUser: "在等回答"
        case .failed: "出错了"
        case .undelivered: "话没送到"
        case .done: "做完了"
        case .stalled: "子代理卡住了"
        }
    }
}

/// Cue 自己醒来的那几轮，叫醒它的会话、任务与提醒此刻叫什么（`CueThread.read` 一次读好，不在主线程）：改了名跟着变，名字不另存。
nonisolated struct CueWakeNames: Equatable, Sendable {
    struct Session: Equatable, Sendable {
        let id: UUID
        let sessionID: String
        let title: String
    }

    /// 按 Pi 的会话 id
    var sessions: [String: Session] = [:]
    var tasks: [UUID: String] = [:]
    /// 提醒的记忆：正文
    var lines: [UUID: String] = [:]

    static func read(_ wakes: [CueWake], from store: isolated CueStore) throws -> CueWakeNames {
        var sessionIDs: [String] = [], taskIDs = Set<UUID>(), lineIDs: [UUID] = []
        for wake in wakes {
            switch wake {
            case .sessionActivity(let stirs):
                sessionIDs += stirs.compactMap(\.session)
                taskIDs.formUnion(stirs.compactMap(\.task))
            case .reminder(let ids): lineIDs += ids
            case .enabled, .message, .idle, .tidy, .renewed, .settingsChanged: break
            }
        }
        var names = CueWakeNames()
        for (id, item) in try store.piSessions(sessionIDs: sessionIDs) {
            names.sessions[id] = Session(id: item.state.id, sessionID: id, title: item.state.title)
        }
        for id in taskIDs {
            if let card = try store.card(id), card.deletedAt == nil { names.tasks[id] = card.title }
        }
        for line in try store.cueLines(lineIDs) { names.lines[line.line.id] = line.line.text }
        return names
    }
}
