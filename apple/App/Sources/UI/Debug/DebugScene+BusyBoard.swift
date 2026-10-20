#if DEBUG
import CueStore
import Foundation

/// `-CuePadBusyBoard YES`（配 tasks 画面与 `-CuePadDemo YES`）：推进中那一列里再放几件 Agent 正在多步推进的任务——
/// 运行工具的、刚想的、派了子代理的、被打断的，与一件有三个步骤（登录回调）、做到第二步、第二步的会话在跑测试的（行尾估还要多久）；只写一次。
extension DebugScene {
    static func seedBusyBoard(_ store: CueStore) async {
        guard defaults.bool(forKey: "CuePadBusyBoard") else { return }
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        guard (try? await store.piSessionPage(PiSessionQuery(text: "share")).items.isEmpty) != false else { return }
        let now = Date.now
        func session(_ id: String, _ state: PiWorkState, _ detail: String?, busy minutes: Double, prompt: String, subagents: [PiSubagentState]? = nil) async {
            let since = now.addingTimeInterval(-minutes * 60)
            _ = try? await recorder.update(
                sessionID: id, state: state, detail: detail, title: id, directory: id,
                times: PiTimes(stateSince: since, busySince: state == .interrupted ? nil : since), subagents: subagents)
            try? await store.writePiTranscript(PiTranscript(sessionID: id, messages: [], recap: PiRecap(lastPrompt: "先读一遍相关代码", lastReply: "读完了。", pendingPrompt: prompt)))
        }
        await session("widget", .tool, "edit · Widgets/TaskEntry.swift", busy: 12, prompt: "小组件里列出进行中的任务")
        await session("undo", .thinking, nil, busy: 3, prompt: "把连续拖拽合并成一条撤销记录")
        await session("export", .delegating, nil, busy: 26, prompt: "导出 PNG 时保留透明背景", subagents: [
            PiSubagentState(name: "渲染", role: "工程师", phase: .known(.running), action: "改 Exporter.render", startedAt: now.addingTimeInterval(-600)),
            PiSubagentState(name: "截图对比", role: "哨兵", phase: .known(.running), action: "运行 pnpm test export", startedAt: now.addingTimeInterval(-300)),
        ])
        await session("share", .interrupted, nil, busy: 48, prompt: "分享扩展一次收多张图片")
        await session("gateway", .tool, "bash · pnpm test -- auth", busy: 7, prompt: "换成统一网关并跑测试")
        guard let tasks = try? await store.tasks(.todo).flatMap(\.tasks) else { return }
        func task(_ prefix: String) -> Card? { tasks.first { $0.parentID == nil && $0.body.hasPrefix(prefix) } }
        for (prefix, id) in [("小组件显示", "widget"), ("撤销栈", "undo"), ("导出 PNG", "export"), ("分享扩展", "share")] {
            if let card = task(prefix) { try? await store.linkCard(card.id, toSession: id) }
        }
        guard let mute = task("登录回调改走统一网关") else { return }
        let first = try? await store.createTask("列出所有回调地址", under: mute.id)
        let second = try? await store.createTask("换成统一网关并跑测试", under: mute.id)
        _ = try? await store.createTask("补超时重试的用例", under: mute.id)
        // 先开工、隔几秒做完第一步：行尾按做完的那一步估剩下两步"约 N 秒"（`TaskPace`）
        try? await store.setStatus(mute.id, .inProgress)
        try? await Task.sleep(for: .seconds(3))
        if let first { try? await store.setStatus(first.id, .done) }
        if let second { try? await store.linkCard(second.id, toSession: "gateway") }
    }
}
#endif
