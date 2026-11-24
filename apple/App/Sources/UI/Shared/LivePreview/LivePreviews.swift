import CueStore
import Foundation
import Observation

/// 每个会话的活预览走到了哪一步（`Workspace.livePreviews`），Mac 与手机、iPad 同一份；换不换地址只经 `Target.move`。
/// Mac 上一个会话的页面来自三处：认出的服务（`Entry.found`）、Agent 发来的（`cuepad live`）、你填的。手机、iPad 上有哪些页面看 Mac 的答复（`LiveRemote`）。
@Observable
final class LivePreviews {
    enum Stage {
        /// 还没有网页视图：Mac 上可能已认出服务（`Entry.found`）。
        case found
        /// Mac 上闲置被放掉的：地址留着，Agent 再用或你点开时照它重建。
        case pending(LivePreview.Target)
        /// 有网页视图，一直探着服务在不在。`held`：你正看着自己填的地址时 Agent 发来的，收起再开时换上。
        case loaded(LivePreview, held: LivePreview.Target?)
    }

    struct Entry {
        var stage = Stage.found
        var found: [URL] = []
        /// Mac：Agent 最后一次发来的（答给手机）；手机、iPad：照着换过的那一次。
        var sent: LiveSignal.Sent?
    }

    private(set) var entries: [UUID: Entry] = [:]
    @ObservationIgnored private var watching: [UUID: Task<Void, Never>] = [:]
    #if os(iOS)
    @ObservationIgnored private let remote: LiveRemote

    init(remote: LiveRemote) { self.remote = remote }
    #else
    init() {}
    #endif

    subscript(id: UUID) -> LivePreview? {
        if case .loaded(let preview, _)? = entries[id]?.stage { preview } else { nil }
    }

    var loaded: [LivePreview] {
        entries.values.compactMap { if case .loaded(let preview, _) = $0.stage { preview } else { nil } }
    }

    /// 这个会话有哪些页面可看，先到的在前：栏头的钮指着第一个，改地址时其余的列在气泡里。
    func pages(_ id: UUID) -> [URL] {
        #if os(macOS)
        guard let entry = entries[id] else { return [] }
        let first: [URL?] = switch entry.stage {
        case .found: []
        case .pending(let target): [target.url]
        case .loaded(let preview, let held): [held?.url, preview.target.keeps(entry.found) ? preview.address : nil]
        }
        var pages: [URL] = []
        for url in first.compactMap(\.self) + entry.found where !pages.contains(url) { pages.append(url) }
        return pages
        #else
        answer(id)?.pages ?? []
        #endif
    }

    /// 要开在面板里：照规则换到该看的地址，没有网页视图就建一个。返回开不开得了：Mac 上没有地址也开（空的地址输入），手机、iPad 上 Mac 没答有页面就不开。
    func show(_ id: UUID, sessionID: String?) -> Bool {
        guard let sessionID else { return Self.typesAddress }
        #if os(macOS)
        let entry = entries[id] ?? Entry()
        switch entry.stage {
        case .loaded(let preview, let held):
            if case .go(let target) = LivePreview.Target.move(from: preview.target, showing: false, sent: held, found: entry.found, pages: entry.found) {
                preview.retarget(target)
            }
            entries[id]?.stage = .loaded(preview, held: nil)
        case .pending(let target): load(id, sessionID, target)
        case .found:
            if case .go(let target) = LivePreview.Target.move(from: nil, showing: false, sent: nil, found: entry.found, pages: entry.found) { load(id, sessionID, target) }
        }
        return true
        #else
        guard let answer = answer(id), !answer.pages.isEmpty else { return false }
        if let preview = self[id] {
            follow(preview, answer, showing: false)
            return true
        }
        guard let target = take(id, answer, current: nil, showing: false) else { return false }
        load(id, sessionID, target).host = remote.host(sessionID)
        return true
        #endif
    }

    #if os(macOS)
    static let typesAddress = true
    #else
    static let typesAddress = false
    #endif

    /// 你在地址栏或空的地址输入里填的。
    @discardableResult func type(_ url: URL, for id: UUID, sessionID: String) -> LivePreview {
        let target = LivePreview.Target(url: url, source: .typed)
        guard let preview = self[id] else { return load(id, sessionID, target) }
        preview.retarget(target)
        return preview
    }

    @discardableResult private func load(_ id: UUID, _ sessionID: String, _ target: LivePreview.Target) -> LivePreview {
        let preview = LivePreview(sessionID: sessionID, target: target)
        entries[id, default: Entry()].stage = .loaded(preview, held: nil)
        watching.removeValue(forKey: id)?.cancel()
        watching[id] = Task { await preview.watch() }
        return preview
    }

    /// 放掉网页视图，地址留在 `next` 那一步。
    private func unload(_ id: UUID, to next: Stage) {
        guard case .loaded(let preview, _)? = entries[id]?.stage else { return }
        watching.removeValue(forKey: id)?.cancel()
        // 弹着的对话框先答掉：WebKit 等着的回调没调就放掉网页视图会抛异常，网页的脚本也停在那一句上等着
        for ask in preview.asks { preview.answer(ask.id, nil) }
        #if os(macOS)
        preview.disengage()
        #endif
        entries[id]?.stage = next
        if case .found = next, entries[id]?.found.isEmpty != false, entries[id]?.sent == nil { entries[id] = nil }
    }

    #if os(macOS)
    enum Received {
        case loaded(LivePreview)
        /// 你正看着自己填的这个地址，Agent 的留到收起再开时。
        case held(by: URL)
    }

    /// Agent 发来的地址（`cuepad live`）：没有网页视图就建一个，你正看着自己填的地址时不换。
    func receive(_ sent: LiveSignal.Sent, for id: UUID, sessionID: String, showing: Bool) -> Received {
        entries[id, default: Entry()].sent = sent
        let target = LivePreview.Target(url: sent.url, source: sent.found ? .found : .sent)
        guard case .loaded(let preview, _)? = entries[id]?.stage else { return .loaded(load(id, sessionID, target)) }
        let found = entries[id]?.found ?? []
        switch LivePreview.Target.move(from: preview.target, showing: showing, sent: target, found: found, pages: found) {
        case .hold:
            entries[id]?.stage = .loaded(preview, held: target)
            return .held(by: preview.address)
        case .go(let next):
            preview.retarget(next)
            entries[id]?.stage = .loaded(preview, held: nil)
        case .stay: break
        }
        return .loaded(preview)
    }

    /// 认服务的结果：`scanned` 是这一遍认的那几个会话（nil 是全部）。认出的服务换了端口，正看着认出的地址的跟过去。
    func found(_ found: [UUID: [URL]], scanned: Set<UUID>?) {
        let ids = scanned ?? Set(entries.keys).union(found.keys)
        for id in ids {
            let urls = found[id] ?? []
            guard (entries[id]?.found ?? []) != urls else { continue }
            entries[id, default: Entry()].found = urls
            if case .loaded(let preview, _)? = entries[id]?.stage,
               case .go(let target) = LivePreview.Target.move(from: preview.target, showing: true, sent: nil, found: urls, pages: urls) {
                preview.retarget(target)
            }
            if urls.isEmpty, case .found? = entries[id]?.stage, entries[id]?.sent == nil { entries[id] = nil }
        }
    }

    /// Agent 要用这一页：放掉过的照原来的地址重建（`rebuilt`），没发过地址的报错。
    func forAgent(_ id: UUID, sessionID: String) throws -> (preview: LivePreview, rebuilt: Bool) {
        switch entries[id]?.stage {
        case .loaded(let preview, _)?: return (preview, false)
        case .pending(let target)?: return (load(id, sessionID, target), true)
        case .found?, nil: throw LiveRefusal("这个会话还没有活预览：先 cuepad live（或 cuepad live <端口>）把页面开在 CuePad 里，再操作它")
        }
    }

    /// 闲置的放掉网页视图、地址留着；结束了的会话连地址一起忘掉。
    func release(_ id: UUID, ended: Bool) {
        guard case .loaded(let preview, let held)? = entries[id]?.stage else { return }
        if ended { entries[id]?.sent = nil }
        unload(id, to: ended ? .found : .pending(held ?? preview.target))
    }
    #else
    /// 手机、iPad：Mac 的答复变了（隧道连着时一直跟着，`LiveLink`）。返回换没换地址。
    @discardableResult func follow(_ preview: LivePreview, _ answer: LiveRemote.Pages, showing: Bool) -> Bool {
        let id = SessionState.recordID(sessionID: preview.sessionID)
        guard let target = take(id, answer, current: preview.target, showing: showing) else { return false }
        preview.retarget(target)
        return true
    }

    private func take(_ id: UUID, _ answer: LiveRemote.Pages, current: LivePreview.Target?, showing: Bool) -> LivePreview.Target? {
        let sent = answer.sent.flatMap { $0.at == entries[id]?.sent?.at ? nil : $0 }
        let move = LivePreview.Target.move(from: current, showing: showing, sent: sent.map { .init(url: $0.url, source: $0.found ? .found : .sent) },
                                           found: answer.serving, pages: answer.pages)
        guard case .go(let target) = move else { return nil }
        if let sent { entries[id, default: Entry()].sent = sent }
        return target
    }

    private func answer(_ id: UUID) -> LiveRemote.Pages? {
        remote.answers.first { SessionState.recordID(sessionID: $0.key) == id }?.value
    }

    /// 只留开在这一排或这条路上的会话的：离开会话页就放掉。
    func keep(_ open: Set<UUID>) {
        for id in Array(entries.keys) where !open.contains(id) {
            unload(id, to: .found)
            entries[id] = nil
        }
    }
    #endif
}

extension LivePreview.Target {
    func keeps(_ found: [URL]) -> Bool { source != .found || found.contains(url) }

    enum Move: Equatable {
        case stay
        case go(LivePreview.Target)
        /// Agent 发来的先留着：你正看着自己填的地址。
        case hold
    }

    /// 换不换地址的唯一规则：Agent 新发来的跟过去，除非你正看着自己填的；认出的服务没了（或还没有地址）换到这个会话的第一个页面；别的不动。
    static func move(from current: Self?, showing: Bool, sent: Self?, found: [URL], pages: [URL]) -> Move {
        if let sent { return current?.source == .typed && showing ? .hold : .go(sent) }
        if let current, current.keeps(found) { return .stay }
        guard let first = pages.first, first != current?.url else { return .stay }
        return .go(.init(url: first, source: found.contains(first) ? .found : .sent))
    }
}
