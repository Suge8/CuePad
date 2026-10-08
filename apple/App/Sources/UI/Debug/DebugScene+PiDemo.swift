#if DEBUG
import CueStore
import SwiftUI

/// 演示库里的 Pi：Mac 同步来的会话状态（含历史）、几段对话与发到 Mac 的请求（iOS 与 Mac 的 session 画面共用）。
extension DebugScene {
    /// 每 4 秒给会话写进一条 Pi 的回答，共 30 条。
    static func growChat(_ sessionID: String, store: CueStore) async {
        for index in 1...30 {
            try? await Task.sleep(for: .seconds(4))
            let text = "第 \(index) 条新回答：" + String(repeating: "这一段用来把对话撑长，看滚动跟随。", count: 4)
            try? await store.writePiTranscript(PiTranscript(
                sessionID: sessionID,
                messages: [PiChatMessage(sessionID: sessionID, entryID: UUID().uuidString, seq: Int64(Date.now.timeIntervalSince1970 * 1000), role: .pi, text: text, at: .now)],
                recap: PiRecap(lastReply: text)))
        }
    }

    /// 1.5 秒后一次写进 `count` 轮长对话（像 Mac 补写一个老会话的对话那样整批到达），核对整批到达时停在最新。
    static func bulkChat(_ sessionID: String, count: Int, store: CueStore) async {
        try? await Task.sleep(for: .seconds(1.5))
        let start = Int64(Date.now.timeIntervalSince1970) * 100
        let table = "\n\n| 项 | 结果 |\n|:--|--:|\n| 用例 | 12 |\n| 失败 | 2 |"
        let messages = (0..<count * 2).map { index in
            let pi = index % 2 == 1
            // 高度差得很远的回答（一行、长段落、表格、长代码块），懒加载按估计高度排时误差最大；代码块末行很宽，核对横向滚动
            let round = index / 2 + 1
            let body = switch round % 4 {
            case 0: "好的。"
            case 1: String(repeating: "整批到达的长回答，用来撑出很高的对话。", count: 12)
            case 2: "结果如下：" + table
            default: "改动如下：\n\n```swift\n" + (1...30).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
                + "\nlet all = [" + (1...30).map { "value\($0)" }.joined(separator: ", ") + "]\n```"
            }
            let text = pi ? "第 \(round) 轮回答：" + body : "第 \(round) 个问题"
            return PiChatMessage(sessionID: sessionID, entryID: "bulk-\(start)-\(index)", seq: start + Int64(index), role: pi ? .pi : .user, text: text, at: .now)
        }
        try? await store.writePiTranscript(PiTranscript(sessionID: sessionID, messages: messages, recap: PiRecap(lastReply: messages.last?.text)))
    }

    /// 两台 Mac 的项目目录绑定：工作室的 Mac 绑了全部带目录的项目，MacBook Air 只绑了 CuePad（新会话里 CuePad 要选 Mac）。
    /// 绑定由本机目录推导，所以先只留 CuePad 的目录发布第二台，再把目录放回去。
    private static func seedBindings(_ store: CueStore, projects: [Project]) async {
        try? await store.publishDirectoryBindings(host: "demo-mac", hostName: "工作室的 Mac Studio")
        guard let directories = try? await store.projectDirectories() else { return }
        let others = projects.filter { $0.name != "CuePad" }.map(\.id)
        for id in others { try? await store.setDirectory(nil, for: id) }
        try? await store.publishDirectoryBindings(host: "demo-air", hostName: "MacBook Air")
        for id in others { if let directory = directories[id] { try? await store.setDirectory(directory, for: id) } }
    }

    /// 任务三态：圆桌的一条交给了 atlas（进行中、带会话状态），CuePad 的一条手动开始；CuePad、Flow、圆桌各完成一条（先后完成）。
    private static func seedTaskStates(_ store: CueStore, projects: [Project]) async {
        guard let tasks = try? await store.tasks(.todo).flatMap(\.tasks) else { return }
        func first(in name: String) -> Card? { tasks.first { $0.projectID == projects.first { $0.name == name }?.id } }
        if let task = first(in: "圆桌") {
            _ = try? await store.recordSend(task.body, to: SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), card: task.id)
        }
        let cuepad = tasks.filter { $0.projectID == projects.first { $0.name == "CuePad" }?.id }
        if let started = cuepad.first { try? await store.setStatus(started.id, .inProgress) }
        if cuepad.count > 1 { try? await store.setStatus(cuepad[1].id, .done) }
        // 再完成两个别的项目的，最近完成那组跨项目、按完成时间排
        for name in ["Flow", "圆桌"] {
            guard let task = tasks.last(where: { $0.projectID == projects.first { $0.name == name }?.id }) else { continue }
            try? await Task.sleep(for: .milliseconds(5))
            try? await store.setStatus(task.id, .done)
        }
    }

    /// 演示会话的摘要与弹窗：摘要写成对话的投影，弹窗交给状态记录器（与真实来源一致）。
    private struct DemoRecap {
        var lastPrompt: String?
        var lastReply: String?
        var pendingPrompt: String?
        var question: PiQuestion?
    }

    /// 演示对话的另一台 Mac 的执行器（留住它，结果写回后照常显示）。
    private static var relayExecutor: DeliveryExecutor?

    /// 演示对话：notes 是几轮做完的对话（带工具数与用时、Markdown），atlas 在处理新的话，homepage、rename 停在问题上，
    /// relay 在另一台 Mac 上（发过去的一条已送达还没进对话、一条没能送达）。
    private static func seedChats(_ store: CueStore) async {
        let now = Date.now
        func chat(_ sessionID: String, _ turns: [(you: String, pi: String?, tools: Int, minutes: Double)], startedMinutesAgo: Double) async {
            var messages: [PiChatMessage] = []
            var clock = now.addingTimeInterval(-startedMinutesAgo * 60)
            for (index, turn) in turns.enumerated() {
                let asked = clock
                messages.append(PiChatMessage(sessionID: sessionID, entryID: "u\(index)", seq: Int64(index * 2), role: .user, text: turn.you, at: asked))
                clock = asked.addingTimeInterval(turn.minutes * 60)
                if let reply = turn.pi {
                    messages.append(PiChatMessage(
                        sessionID: sessionID, entryID: "p\(index)", seq: Int64(index * 2 + 1), role: .pi, text: reply, at: clock,
                        toolCount: turn.tools, roundStartedAt: asked))
                }
                clock = clock.addingTimeInterval(120)
            }
            let done = turns.last { $0.pi != nil }
            let pending = turns.last.flatMap { $0.pi == nil ? $0.you : nil }
            try? await store.writePiTranscript(PiTranscript(
                sessionID: sessionID, messages: messages,
                recap: PiRecap(lastPrompt: done?.you, lastReply: done?.pi, pendingPrompt: pending)))
        }
        await chat("notes", [
            ("整理一下这周的会议记录", "整理好了，放在 `notes/2026-W40.md`。三件待办：\n\n- **续费域名**（周五前）\n- 评审计费额度\n- 补 scheduler 测试", 4, 1.5),
            ("续费域名那条加上负责人和链接", "加好了：负责人写的是你，链接指向注册商的续费页。", 1, 0.4),
            ("再把评审计费额度拆成两步", "拆成了两步：\n\n1. 先对一遍额度表和账单的口径\n2. 再看超额时的提示文案\n\n都放在待办的同一节下面。", 2, 0.8),
            // 最坏的 Markdown：宽表（对齐语法、代码单元格、中英混排长单元格）、引用、嵌套列表、标题、链接、长代码行
            ("把三个排序方案的对比做成表格", """
            ## 对比结果

            | 方案 | 延迟 (p95) | 内存 | 说明 |
            |:---|---:|:---:|---|
            | `queue.sort` 按首次加入 | 12 ms | 38 MB | 改动最小，重连的人不会插队 |
            | 按 rejoinAt 排序并去重 | 9 ms | 41 MB | 需要迁移旧数据；**不建议**本周上 |
            | LinkedHashMap + lazy eviction of stale participants | 7 ms | 52 MB | 最快，但最复杂，出错时很难查 |

            > 注意：p95 是在 8 人房间里测的，16 人以上还没测。

            ### 下一步
            1. 先合第一个方案
               - 补 3 个重连用例
               - 跑一遍压测
            2. 再评估第三个

            详见 [调度设计说明](https://example.com/scheduler)。

            ```ts
            export function sortQueue(queue: Participant[]): Participant[] { return [...queue].sort((a, b) => a.firstJoinedAt - b.firstJoinedAt) }
            ```
            """, 3, 1.0),
        ], startedMinutesAgo: 20)
        await chat("atlas", [
            ("跑一下 scheduler 的测试，失败的话先别改代码，告诉我原因", "12 个用例里有 **2 个失败**：\n\n1. 发言轮次在 5 人以上时，第 6 位被排到了最前——队列按加入时间排序，但重连的人会拿到新的时间戳。\n2. 登录回调走了旧网关，超时后没有重试。\n\n第一个建议改成按首次加入时间排序，改动在 `scheduler/queue.ts`：\n\n```ts\nqueue.sort((a, b) => a.firstJoinedAt - b.firstJoinedAt)\n```\n\n要我先改第一个吗？", 5, 2),
            ("按你说的改成首次加入时间排序，把断言也改了，再跑一遍", nil, 0, 0),
        ], startedMinutesAgo: 6)
        await chat("homepage", [
            ("把 RSS 输出改成全文", nil, 0, 0),
        ], startedMinutesAgo: 3)
        await chat("relay", [
            ("看一下线上库的迁移有没有卡住", "迁移跑到第 14 步停住了：`add_index_on_cards` 在等锁。现在没有别的写入，可以安全重跑。", 3, 1.2),
        ], startedMinutesAgo: 10)
    }

    /// `-CuePadDemoMac YES`：演示库里一台会回话的"demo-mac"。发给它的会话的话，像真的经同步那样慢慢走完：
    /// 等一会儿才被接手（发送中）→ 送达用一会儿（送达中）→ 会话状态再晚一点才同步过来（思考中）→ 这一轮做完（待你回复），
    /// 录"发出 → 返回列表 → 状态流转"用。
    static func runDemoMac(_ store: CueStore) async {
        let host = "demo-mac"
        do {
            for try await pending in store.observe([.deliveryRequests], { store in
                try store.deliveryRequests().filter { $0.hostID == host && $0.status == .known(.pending) }.map(\.id)
            }) where !pending.isEmpty {
                try await Task.sleep(for: .seconds(1.2))
                // 与真的 Mac 一样，说出去的话送达后记一条发送记录（任务因此进行中、关联到这个会话）
                let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { _ in }) { request in
                    try? await Task.sleep(for: .seconds(1))
                    if let mode = request.mode.known, DeliveryMode.toSession.contains(mode), mode != .answer {
                        try? await store.recordSend(request.content, to: request.target, card: request.cardID, parts: request.partIDs)
                    }
                    return .succeeded
                }
                try await executor.start()
                for try await open in store.observe([.deliveryRequests], { store in
                    try store.deliveryRequests().contains { pending.contains($0.id) && $0.isOpen }
                }) where !open { break }
                await executor.stop()
                for id in pending { await playRound(for: id, store: store, host: host) }
            }
        } catch {}
    }

    /// 会话状态晚于送达结果同步过来：先进入思考，过一会儿做完。
    private static func playRound(for request: UUID, store: CueStore, host: String) async {
        guard let ref = try? await store.deliveryRequest(request)?.target.ref,
              let session = try? await store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: ref))).items.first?.state
        else { return }
        let recorder = PiStateRecorder(store: store, hostID: host)
        func set(_ state: PiWorkState) async {
            try? await recorder.update(
                sessionID: ref, state: state, title: session.title, folder: session.folder, projectID: session.projectID)
        }
        try? await Task.sleep(for: .seconds(0.8))
        await set(.thinking)
        try? await Task.sleep(for: .seconds(2.5))
        await set(.settled)
    }

    /// 演示会话的模型配置：两家各一个模型，思考强度档位不同（回复框下的模型胶囊与强度条有东西可换）。
    private static let demoModels: PiModelState = {
        let opus = PiModelOption(key: PiModelKey(provider: "anthropic", id: "claude-opus-5-5-20260901"), name: "Claude Opus 5.5",
                                 thinkingLevels: [.low, .medium, .high, .max])
        let luna = PiModelOption(key: PiModelKey(provider: "openai", id: "gpt-6-luna"), name: "GPT-6 Luna", thinkingLevels: [.off, .low, .high])
        return PiModelState(model: opus, thinking: .known(.medium), models: [opus, luna])
    }()

    /// 演示用的 Mac 端状态：三个 Pi 会话（一个等你确认）、一条等 Mac 接手的请求。只在库里还没有时写。
    static func seedRemote(_ services: AppServices) async {
        let store = services.store
        // 演示库的会话索引已写成历史；这里补的是在线会话，有在线的就是写过了
        guard (try? await store.piSessionPage(.live).items.isEmpty) == true, let projects = try? await store.projects() else { return }
        func project(_ name: String) -> UUID? { projects.first { $0.name == name }?.id }
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        let sessions: [(String, PiWorkState, String?, String?, DemoRecap)] = [
            // 在跑的会话：新的话在 pendingPrompt，上一轮问答成对
            ("atlas", .tool, "bash · pnpm test -- scheduler", "圆桌", DemoRecap(
                lastPrompt: "跑一下 scheduler 的测试，失败的话先别改代码，告诉我原因",
                lastReply: "上一轮 12 个用例里有 **2 个失败**：\n\n1. 发言轮次在 5 人以上时，第 6 位的顺序被排到了最前——队列按加入时间排序，但重连的人会拿到新的时间戳。\n2. 登录回调走了旧网关，超时后没有重试。\n\n第一个建议改成按首次加入时间排序，改动在 `scheduler/queue.ts`：\n\n```ts\nqueue.sort((a, b) => a.firstJoinedAt - b.firstJoinedAt)\n```\n\n第二个需要把回调地址换成统一网关。\n\n另外顺手看了一眼覆盖率：scheduler 目录是 71%，主要缺重连和超时两条路径。两个失败修好后，我可以补上这两条的用例，大概再加 6 个测试。\n\n要我先改第一个吗？",
                pendingPrompt: "按你说的改成首次加入时间排序，把断言也改了，再跑一遍")),
            ("homepage", .waitingForUser, "要覆盖 public/feed.xml 吗？", "个人网站", DemoRecap(
                lastPrompt: "把 RSS 输出改成全文",
                question: PiQuestion(
                    promptID: "demo-prompt", kind: .select, text: "要覆盖 public/feed.xml 吗？", options: ["覆盖", "另存为 feed-full.xml", "取消"]))),
            ("cuepad", .thinking, nil, "CuePad", DemoRecap(
                lastPrompt: "先跑一遍全部测试", lastReply: "全部通过，共 214 个。", pendingPrompt: "看看投送队列超时的那个 bug")),
            ("notes-edit", .waitingForUser, "编辑提交说明", nil, DemoRecap(
                lastPrompt: "写一段提交说明",
                question: PiQuestion(promptID: nil, kind: .unknown("editor"), text: "编辑提交说明\n在编辑器里改好后保存"))),
            ("rename", .waitingForUser, "新分支叫什么？", "CuePad", DemoRecap(
                lastPrompt: "把这批改动挪到新分支上",
                question: PiQuestion(promptID: "demo-text", kind: .text, text: "新分支叫什么？"))),
            ("deploy", .waitingForUser, "部署到生产吗？", nil, DemoRecap(
                lastPrompt: "测试都过了就部署",
                question: PiQuestion(promptID: "demo-confirm", kind: .confirm, text: "部署到生产吗？\n会替换当前线上的 1.4.2"))),
            ("review", .delegating, "2 个子代理在审查：计费额度、登录回调", nil, DemoRecap(lastPrompt: "让子代理分头审查这两个分支")),
            ("billing", .error, "模型拒绝了请求（400）：prompt is too long", nil, DemoRecap(lastPrompt: "把整个 billing 目录读一遍，总结计费规则")),
            ("notes", .settled, nil, nil, DemoRecap(
                lastPrompt: "整理一下这周的会议记录", lastReply: "整理好了，放在 `notes/2026-W40.md`。三件待办：**续费域名**、评审计费额度、补 scheduler 测试。")),
            ("piwork", .settled, nil, nil, DemoRecap(
                lastPrompt: "列出 piwork 目录下的文件", lastReply: "目录里有 3 个文件：\n- README.md\n- notes.txt\n- todo.md")),
        ]
        // 历史里再加两个带近况的：一个正在请 Mac 继续，一个不在项目里
        let history: [(String, String?, PiRecap)] = [
            ("landing-copy", "个人网站", PiRecap(lastPrompt: "把首页标题换成新文案", lastReply: "改好了，首页标题现在是「把想法写成卡片」。")),
            ("weekly", nil, PiRecap(lastPrompt: "汇总这周的提交", lastReply: "这周 23 个提交，主要是同步和 Pi 页。")),
        ]
        for (id, name, recap) in history {
            try? await recorder.update(sessionID: id, state: .settled, detail: nil, title: id, folder: id, projectID: name.flatMap(project))
            try? await store.writePiTranscript(PiTranscript(sessionID: id, messages: [], recap: recap))
            try? await recorder.end(sessionID: id)
        }
        for (id, state, detail, name, recap) in sessions {
            try? await recorder.update(
                sessionID: id, state: state, detail: detail, title: id, folder: id, projectID: name.flatMap(project), question: recap.question,
                modelState: demoModels)
            try? await store.writePiTranscript(PiTranscript(
                sessionID: id, messages: [],
                recap: PiRecap(lastPrompt: recap.lastPrompt, lastReply: recap.lastReply, pendingPrompt: recap.pendingPrompt)))
        }
        try? await recorder.end(sessionID: "piwork")
        // 没归类的想法：书架顶上提醒去整理
        for body in ["周末读完《设计心理学》第三章", "菜单栏面板能不能直接拖图进来？", "给落地页换一张首图"] {
            _ = try? await store.createCard(in: nil, body: body)
        }
        // 后台托管、带两个子代理的会话
        try? await recorder.update(sessionID: "review", state: .delegating, hosted: true, subagents: [
            PiSubagentState(name: "计费额度", activity: .known(.working)),
            PiSubagentState(name: "登录回调", activity: .known(.waitingForUser)),
            PiSubagentState(name: "文档", activity: .known(.idle)),
        ])
        await seedBindings(store, projects: projects)
        let extra = defaults.integer(forKey: "CuePadHistory")
        for index in 0..<extra {
            let id = "history-\(index + 1)"
            let name = ["CuePad", "圆桌", nil][index % 3]
            let ended = Date.now.addingTimeInterval(-Double(index + 1) * 8 * 3600)
            let past = PiStateRecorder(store: store, hostID: "demo-mac", timing: Timing(now: { ended }, sleep: { _ in }))
            try? await past.update(
                sessionID: id, state: .settled, detail: nil, title: "历史会话 \(index + 1)", folder: id, projectID: name.flatMap(project))
            try? await store.writePiTranscript(PiTranscript(
                sessionID: id, messages: [], recap: PiRecap(lastPrompt: "第 \(index + 1) 个", lastReply: "做完了")))
            try? await past.end(sessionID: id)
        }
        // 另一台 Mac 上的会话（演示发过去的话送达与失败）
        try? await PiStateRecorder(store: store, hostID: "demo-mini").update(sessionID: "relay", state: .settled, title: "relay", folder: "relay")
        await seedChats(store)
        let states = (try? await store.piSessionPage(PiSessionQuery(limit: 100)).items.map(\.state)) ?? []
        await seedTaskStates(store, projects: projects)
        if let relay = states.first(where: { $0.sessionID == "relay" }) {
            // 一条已送达还没进对话、一条没能送达：由一个只认这台演示 Mac 的执行器给出结果
            _ = try? await services.requestMacDelivery("先把迁移脚本在测试库上跑一遍", to: relay, mode: .send)
            _ = try? await services.requestMacDelivery("顺便备份一下线上数据库", to: relay, mode: .send)
            relayExecutor = DeliveryExecutor(store: store, hostID: relay.hostID, onIssue: { _ in }) { request in
                request.content.contains("备份") ? .failed("那台 Mac 上的 Pi 已经退出，没能送进去") : .succeeded
            }
            try? await relayExecutor?.start()
        }
        if let atlas = states.first(where: { $0.sessionID == "atlas" }) {
            _ = try? await services.requestMacDelivery("改完再看看登录回调那个超时", to: atlas, mode: .followUp)
        }
        if let landing = states.first(where: { $0.sessionID == "landing-copy" }) {
            // 发给已结束的会话：Mac 先在后台唤醒它
            _ = try? await services.requestMacDelivery("标题再短一点", to: landing, mode: .send)
        }
        if let cuepad = states.first(where: { $0.sessionID == "cuepad" }) {
            _ = try? await services.requestMacDelivery("超时后先重试一次，还失败再报错", to: cuepad, mode: .steer)
        }
    }
}
#endif
