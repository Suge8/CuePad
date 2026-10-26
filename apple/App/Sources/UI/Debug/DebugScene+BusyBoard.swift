#if DEBUG
import CueStore
import Foundation

/// `-CuePadBusyBoard YES`（配 tasks 画面与 `-CuePadDemo YES`）：推进中那一列里再放几件 Agent 正在多步推进的任务——
/// 运行工具的、刚想的、派了子代理的、被打断的，与一件有三个子任务（登录回调）、做到第二步、第二步的会话在跑测试的（行尾估还要多久）；只写一次。
/// 每个会话之前还说过几句（`earlier`，几分钟前），卡下沿那条线的过去一句一颗点；这一轮的那句在 `busy` 分钟前。
extension DebugScene {
    static func seedBusyBoard(_ store: CueStore) async {
        guard defaults.bool(forKey: "CuePadBusyBoard") else { return }
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        guard (try? await store.piSessionPage(PiSessionQuery(text: "share")).items.isEmpty) != false else { return }
        let now = Date.now
        func session(_ id: String, _ state: PiWorkState, _ detail: String?, busy minutes: Double, earlier: [Double] = [], prompt: String, subagents: [PiSubagentState]? = nil) async {
            let since = now.addingTimeInterval(-minutes * 60)
            _ = try? await recorder.update(
                sessionID: id, state: state, detail: detail, title: id, directory: id,
                times: PiTimes(stateSince: since, busySince: state == .interrupted ? nil : since), subagents: subagents)
            let lastPrompt = String(localized: "先读一遍相关代码", table: "Demo")
            let said = earlier.map { (lastPrompt, $0) } + [(prompt, minutes)]
            let messages = said.enumerated().map { index, line in
                PiChatMessage(sessionID: id, entryID: "said-\(index)", seq: Int64(index), role: .user, text: line.0, at: now.addingTimeInterval(-line.1 * 60))
            }
            try? await store.writePiTranscript(PiTranscript(sessionID: id, messages: messages, recap: PiRecap(lastPrompt: lastPrompt, lastReply: String(localized: "读完了。", table: "Demo"), pendingPrompt: prompt)))
        }
        await session("widget", .tool, "edit · Widgets/TaskEntry.swift", busy: 12, earlier: [170, 150, 95, 70, 40, 25], prompt: String(localized: "小组件里列出进行中的任务", table: "Demo"))
        await session("undo", .thinking, nil, busy: 3, earlier: [18], prompt: String(localized: "把连续拖拽合并成一条撤销记录", table: "Demo"))
        await session("export", .delegating, nil, busy: 26, earlier: [40], prompt: String(localized: "导出 PNG 时保留透明背景", table: "Demo"), subagents: [
            PiSubagentState(name: String(localized: "渲染", table: "Demo"), role: String(localized: "工程师", table: "Demo"), phase: .known(.running), action: String(localized: "改 Exporter.render", table: "Demo"), startedAt: now.addingTimeInterval(-600)),
            PiSubagentState(name: String(localized: "截图对比", table: "Demo"), role: String(localized: "哨兵", table: "Demo"), phase: .known(.running), action: String(localized: "运行 pnpm test export", table: "Demo"), startedAt: now.addingTimeInterval(-300)),
        ])
        await session("share", .interrupted, nil, busy: 48, earlier: [90, 60], prompt: String(localized: "分享扩展一次收多张图片", table: "Demo"))
        await session("gateway", .tool, "bash · pnpm test -- auth", busy: 7, earlier: [35, 20], prompt: String(localized: "换成统一网关并跑测试", table: "Demo"))
        guard let tasks = try? await store.tasks(.todo).flatMap(\.tasks) else { return }
        func task(_ prefix: String) -> Card? { tasks.first { $0.parentID == nil && $0.body.hasPrefix(prefix) } }
        for (prefix, id) in [(String(localized: "小组件显示进行中的任务", table: "Demo"), "widget"), (String(localized: "撤销栈合并连续拖拽", table: "Demo"), "undo"), (String(localized: "导出 PNG 时保留透明背景", table: "Demo"), "export"), (String(localized: "分享扩展支持多张图片", table: "Demo"), "share")] {
            if let card = task(prefix) { try? await store.linkCard(card.id, toSession: id) }
        }
        guard let mute = task(String(localized: "登录回调改走统一网关", table: "Demo")) else { return }
        let first = try? await store.createTask(String(localized: "列出所有回调地址", table: "Demo"), under: mute.id)
        let second = try? await store.createTask(String(localized: "换成统一网关并跑测试", table: "Demo"), under: mute.id)
        _ = try? await store.createTask(String(localized: "补超时重试的用例", table: "Demo"), under: mute.id)
        // 先开工（开始时刻记在第一步上）、隔几秒做完它：行尾按它的用时估剩下两步，写"约 N 秒"（`TaskPace`）
        try? await store.setStatus(mute.id, .inProgress)
        try? await Task.sleep(for: .seconds(3))
        if let first { try? await store.setStatus(first.id, .done) }
        if let second { try? await store.linkCard(second.id, toSession: "gateway") }
    }

    /// `-CuePadCanvasSteps YES`（配 tasks 画面，两端）：待办里"画布缩放锚点跟随指针"写上正文与三个子任务（第一个做完），
    /// 进展页的看板上点它的卡看任务气泡的正文与子任务（演示库里另一件有子任务的"发言轮次乱序"在等你那一列，点它是去 Cue 页那一问、不开气泡）。
    static func seedCanvasSteps(_ store: CueStore) async {
        guard defaults.bool(forKey: "CuePadCanvasSteps") else { return }
        guard let canvas = try? await store.tasks(.inProgress, .todo).flatMap(\.tasks).first(where: { $0.body.hasPrefix(String(localized: "画布缩放锚点跟随指针", table: "Demo")) }),
              (try? await store.children(of: canvas.id))?.isEmpty != false else { return }
        try? await store.updateCard(canvas.id) {
            $0.rest = String(localized: "缩放时以指针所在的点为锚点，指针下的那块内容不动、四周跟着放大缩小\n触控板捏合、⌘ 加滚轮、双击放大三种入口都要对，缩放到边界时不回弹", table: "Demo")
        }
        let first = try? await store.createTask(String(localized: "复现缩放时画布跳动\n在 200% 以上连续捏合，记下画布偏移", table: "Demo"), under: canvas.id)
        _ = try? await store.createTask(String(localized: "以指针为锚点换算平移", table: "Demo"), under: canvas.id)
        _ = try? await store.createTask(String(localized: "捏合、滚轮、双击各补一个用例", table: "Demo"), under: canvas.id)
        if let first { try? await store.setStatus(first.id, .done) }
    }
}
#endif
