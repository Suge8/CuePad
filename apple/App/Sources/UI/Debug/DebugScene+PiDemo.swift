#if DEBUG
import CueStore
import SwiftUI

/// 演示库里的 Pi：Mac 同步来的会话状态（含历史）、几段对话与发到 Mac 的请求（iOS 与 Mac 的 session 画面共用）。
extension DebugScene {
    /// 会话里的一轮：你的话、Pi 的回答（还没答完是 nil）与这一轮的工具活动，问与答的时刻。
    struct ChatTurn {
        var you: String
        var pi: String?
        var tools: PiChatMessage.Tools?
        var asked: Date
        var answered: Date
    }

    /// 把几轮写成会话的对话与摘要（最后一轮没答完，它的话是进行中的提问）。演示对话与大库的长对话共用。
    static func writeChat(_ sessionID: String, _ turns: [ChatTurn], store: CueStore) async throws {
        var messages: [PiChatMessage] = []
        for (index, turn) in turns.enumerated() {
            messages.append(PiChatMessage(sessionID: sessionID, entryID: "u\(index)", seq: Int64(index * 2), role: .user, text: turn.you, at: turn.asked))
            if let reply = turn.pi {
                messages.append(PiChatMessage(
                    sessionID: sessionID, entryID: "p\(index)", seq: Int64(index * 2 + 1), role: .pi, text: reply, at: turn.answered,
                    tools: turn.tools, roundStartedAt: turn.asked))
            }
        }
        let done = turns.last { $0.pi != nil }
        let pending = turns.last.flatMap { $0.pi == nil ? $0.you : nil }
        try await store.writePiTranscript(PiTranscript(
            sessionID: sessionID, messages: messages, recap: PiRecap(lastPrompt: done?.you, lastReply: done?.pi, pendingPrompt: pending)))
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

    /// 任务三态与提示词：圆桌"乱序"的第一条提示词交给 notes 已回复、第二条交给 atlas 在处理、第三条没发（任务进行中）；
    /// CuePad"投送超时"的提示词交给 notes 已回复（行尾出现"完成"）；CuePad、Flow、圆桌各完成一条（先后完成）。
    private static func seedTaskStates(_ store: CueStore, projects: [Project]) async {
        guard let tasks = try? await store.tasks(.todo).flatMap(\.tasks) else { return }
        func prompts(_ prefix: String) async -> [Card] {
            guard let task = tasks.first(where: { $0.body.hasPrefix(prefix) }) else { return [] }
            return ((try? await store.children(of: task.id)) ?? []).filter { !$0.isTask }
        }
        func send(_ prompt: Card?, to session: String) async {
            guard let prompt else { return }
            _ = try? await store.recordSend(prompt.body, to: SendTarget(kind: .piSession, name: session, ref: session), card: prompt.id)
        }
        let order = await prompts("发言轮次"), timeout = await prompts("投送队列")
        await send(order.first, to: "notes")
        await send(timeout.first, to: "notes")
        await send(order.dropFirst().first, to: "atlas")
        // notes 这一轮做完：交给它的两条提示词已回复
        try? await Task.sleep(for: .milliseconds(5))
        _ = try? await PiStateRecorder(store: store, hostID: "demo-mac").update(
            sessionID: "notes", state: .settled, title: "notes", folder: "notes", projectID: projects.first { $0.name == "Career" }?.id,
            times: PiTimes(stateSince: .now, busySince: nil), modelState: demoModels)
        let cuepad = tasks.filter { $0.projectID == projects.first { $0.name == "CuePad" }?.id && !$0.body.hasPrefix("投送队列") }
        if let started = cuepad.first { try? await store.setStatus(started.id, .inProgress) }
        // Flow 只有一条在推进的任务、没有 Agent：项目的"此刻"是这条任务
        if let canvas = tasks.first(where: { $0.body.hasPrefix("画布缩放") }) { try? await store.setStatus(canvas.id, .inProgress) }
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

    /// notes 会话最后一轮：你让 Agent 发页面、截图、报告来看，Agent 在命令行里 `cuepad show` 了三个文件（对话里按创建时间排在你的话与回答之间）。
    private static func seedPreviews(_ store: CueStore, now: Date) async {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-previews", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appending(path: "login-v2.html")
        let shot = directory.appending(path: "login-mobile.png")
        let report = directory.appending(path: "review.md")
        try? Self.loginPage.write(to: page, atomically: true, encoding: .utf8)
        try? Self.review.write(to: report, atomically: true, encoding: .utf8)
        try? Self.screenshotPNG()?.write(to: shot)
        var created: [Date] = []
        for (file, title) in [(page, "登录页 v2：可点的完整页面"), (shot, "手机上的登录页截图"), (report, "评审结论")] {
            if let added = try? await store.addPreview(fileAt: file, title: title, sessionID: "notes") { created.append(added.preview.createdAt) }
        }
        // 对话围着预览的创建时间排：你的话在先，回答在后
        guard let first = created.first, let last = created.last else { return }
        let messages = [
            PiChatMessage(sessionID: "notes", entryID: "u9", seq: 8, role: .user, text: "把登录页的新样子、手机上的截图和评审结论发给我看看", at: first.addingTimeInterval(-50)),
            PiChatMessage(
                sessionID: "notes", entryID: "p9", seq: 9, role: .pi, text: "发给你了：完整页面可以直接点按钮试交互，截图是 iPhone 宽度下的样子，评审结论里有两处要你定。",
                at: last.addingTimeInterval(2), tools: .init(commands: 3, items: [.init(kind: .command, target: "cuepad show login-v2.html"), .init(kind: .command, target: "cuepad show login-mobile.png"), .init(kind: .command, target: "cuepad show review.md")]), roundStartedAt: first.addingTimeInterval(-50)),
        ]
        try? await store.writePiTranscript(PiTranscript(
            sessionID: "notes", messages: messages,
            recap: PiRecap(lastPrompt: messages[0].text, lastReply: messages.last?.text)))
    }

    /// 演示用的工具活动：一周会议记录那一轮读了资料、改了笔记、跑了脚本。
    private static let notesWeek = PiChatMessage.Tools(
        edits: 2, commands: 1, reads: 3, failed: 1,
        items: [
            .init(kind: .read, target: "notes/2026-W39.md"), .init(kind: .read, target: "notes/2026-W40.md"), .init(kind: .read, target: "notes/inbox.md"),
            .init(kind: .edit, target: "notes/2026-W40.md", added: 18, removed: 4), .init(kind: .edit, target: "notes/todo.md", added: 3),
            .init(kind: .command, target: "git status --short"), .init(kind: .command, target: "make lint-notes", failed: true),
        ])

    /// 演示用的工具活动：跑测试那一轮读了测试、跑了测试（一次失败），没有改代码。
    private static let testRun = PiChatMessage.Tools(
        commands: 1, reads: 2, failed: 1,
        items: [
            .init(kind: .read, target: "scheduler/queue.ts"), .init(kind: .read, target: "scheduler/queue.test.ts"),
            .init(kind: .command, target: "pnpm vitest run scheduler"), .init(kind: .command, target: "pnpm vitest run scheduler --reporter=verbose", failed: true),
        ])

    private static let loginPage = """
        <!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>登录</title><style>
        body{margin:0;min-height:100vh;display:grid;place-items:center;font:16px -apple-system,system-ui,sans-serif;background:linear-gradient(160deg,#eef2ff,#fdf2f8);color:#1c1b19}
        main{width:min(86vw,360px);padding:28px;border-radius:20px;background:#fff;box-shadow:0 10px 40px #4f46e522}
        h1{margin:0 0 4px;font-size:24px} p{margin:0 0 20px;color:#6b7280}
        input{width:100%;box-sizing:border-box;margin-bottom:12px;padding:12px 14px;border:1px solid #e5e7eb;border-radius:12px;font-size:16px}
        button{width:100%;padding:13px;border:0;border-radius:12px;background:#4f46e5;color:#fff;font-size:16px;font-weight:600}
        #ok{margin-top:14px;color:#059669;min-height:1.2em}</style></head><body><main>
        <h1>欢迎回来</h1><p>用邮箱登录 Atlas</p>
        <input placeholder="邮箱" value="me@example.com"><input placeholder="密码" type="password" value="secret">
        <button onclick="document.getElementById('ok').textContent='登录成功（演示）'">登录</button><div id="ok"></div>
        </main></body></html>
        """

    private static let review = """
        # 登录页评审结论

        改动都在 `login/` 下，**没有动接口**。

        ## 已处理
        - 错误提示从弹窗改成输入框下方的一行字
        - 密码框加了显示/隐藏

        ## 要你定
        1. 记住我默认勾选吗？
        2. 第三方登录放在页面底部还是顶部？

        | 项 | 之前 | 现在 |
        |:---|---:|---:|
        | 首屏可点元素 | 9 | 5 |
        | 登录成功率（内测） | 91% | 94% |
        """

    /// 手机宽度下登录页的"截图"：渐变底上一张白卡、两个输入框和一个按钮。
    private static func screenshotPNG() -> Data? {
        let view = ZStack {
            LinearGradient(colors: [Color(red: 0.93, green: 0.95, blue: 1), Color(red: 0.99, green: 0.95, blue: 0.97)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 12) {
                Text("欢迎回来").font(.system(size: 26, weight: .bold))
                Text("用邮箱登录 Atlas").foregroundStyle(.gray)
                RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.3)).frame(height: 44).overlay(alignment: .leading) { Text("me@example.com").padding(.leading, 14) }
                RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.3)).frame(height: 44).overlay(alignment: .leading) { Text("••••••").padding(.leading, 14) }
                RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.31, green: 0.27, blue: 0.9)).frame(height: 46).overlay { Text("登录").foregroundStyle(.white).bold() }
            }
            .padding(28).frame(width: 320).background(.white, in: RoundedRectangle(cornerRadius: 20))
        }
        .frame(width: 390, height: 640)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage.map { DemoLibrary.encode($0) }
    }

    /// 演示对话：notes 是几轮做完的对话（带工具活动与用时、Markdown），atlas 在处理新的话，homepage、rename 停在问题上，
    /// relay 在另一台 Mac 上（发过去的一条已送达还没进对话、一条没能送达）。
    private static func seedChats(_ store: CueStore) async {
        let now = Date.now
        func chat(_ sessionID: String, _ turns: [(you: String, pi: String?, tools: PiChatMessage.Tools?, minutes: Double)], startedMinutesAgo: Double) async {
            var clock = now.addingTimeInterval(-startedMinutesAgo * 60)
            var rounds: [ChatTurn] = []
            for turn in turns {
                let asked = clock
                clock = asked.addingTimeInterval(turn.minutes * 60)
                rounds.append(ChatTurn(you: turn.you, pi: turn.pi, tools: turn.tools, asked: asked, answered: clock))
                clock = clock.addingTimeInterval(120)
            }
            try? await writeChat(sessionID, rounds, store: store)
        }
        await chat("notes", [
            ("整理一下这周的会议记录", "整理好了，放在 `notes/2026-W40.md`。三件待办：\n\n- **续费域名**（周五前）\n- 评审计费额度\n- 补 scheduler 测试", Self.notesWeek, 1.5),
            ("续费域名那条加上负责人和链接", "加好了：负责人写的是你，链接指向注册商的续费页。", .init(edits: 1, items: [.init(kind: .edit, target: "notes/2026-W40.md", added: 2, removed: 1)]), 0.4),
            ("再把评审计费额度拆成两步", "拆成了两步：\n\n1. 先对一遍额度表和账单的口径\n2. 再看超额时的提示文案\n\n都放在待办的同一节下面。", .init(edits: 1, reads: 1, items: [.init(kind: .read, target: "notes/2026-W40.md"), .init(kind: .edit, target: "notes/2026-W40.md", added: 5, removed: 1)]), 0.8),
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
            """, .init(edits: 1, reads: 2, items: [.init(kind: .read, target: "bench/sorting.md"), .init(kind: .read, target: "bench/results.csv"), .init(kind: .edit, target: "notes/sorting-compare.md", added: 24)]), 1.0),
        ], startedMinutesAgo: 20)
        await seedPreviews(store, now: now)
        await chat("atlas", [
            ("跑一下 scheduler 的测试，失败的话先别改代码，告诉我原因", "12 个用例里有 **2 个失败**：\n\n1. 发言轮次在 5 人以上时，第 6 位被排到了最前——队列按加入时间排序，但重连的人会拿到新的时间戳。\n2. 登录回调走了旧网关，超时后没有重试。\n\n第一个建议改成按首次加入时间排序，改动在 `scheduler/queue.ts`：\n\n```ts\nqueue.sort((a, b) => a.firstJoinedAt - b.firstJoinedAt)\n```\n\n要我先改第一个吗？", Self.testRun, 2),
            ("按你说的改成首次加入时间排序，把断言也改了，再跑一遍", nil, nil, 0),
        ], startedMinutesAgo: 6)
        await chat("homepage", [
            ("把 RSS 输出改成全文", nil, nil, 0),
        ], startedMinutesAgo: 3)
        await chat("relay", [
            ("看一下线上库的迁移有没有卡住", "迁移跑到第 14 步停住了：`add_index_on_cards` 在等锁。现在没有别的写入，可以安全重跑。", .init(commands: 3, items: [.init(kind: .command, target: "psql -c 'select * from schema_migrations order by id desc limit 3'"), .init(kind: .command, target: "psql -c 'select pid, state, query from pg_stat_activity'"), .init(kind: .command, target: "psql -c 'select * from pg_locks where not granted'")]), 1.2),
        ], startedMinutesAgo: 10)
    }

    /// `-CuePadDemoMac YES`：演示库里一台会回话的"demo-mac"。发给它的会话的话，像真的经同步那样慢慢走完：
    /// 等一会儿才被接手（发送中）→ 送达用一会儿（送达中）→ 会话状态再晚一点才同步过来（思考中）→ 这一轮做完（该你了），
    /// 录"发出 → 返回列表 → 状态流转"用。
    static func runDemoMac(_ store: CueStore) async {
        let host = "demo-mac"
        do {
            for try await pending in store.observe({ store in
                try store.deliveryRequests().filter { $0.hostID == host && $0.status == .known(.pending) }.map(\.id)
            }) where !pending.isEmpty {
                try await Task.sleep(for: .seconds(1.2))
                // 与真的 Mac 一样，说出去的话送达后记一条发送记录（任务因此进行中、关联到这个会话）
                let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { _ in }) { request in
                    try? await Task.sleep(for: .seconds(1))
                    if let mode = request.mode.known, DeliveryMode.toSession.contains(mode), mode != .answer {
                        try? await store.recordSend(request.content, to: request.target, card: request.cardID)
                    }
                    return .succeeded
                }
                try await executor.start()
                for try await open in store.observe({ store in
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

    /// 演示会话的斜杠命令清单：内置、扩展、提示词模板、技能各有几条（回复框输入 "/" 弹出的面板）。
    private static let demoCommands = [
        PiSlashCommand(name: "compact", summary: "压缩当前上下文，可附上说明", source: .known(.builtin), hint: "[说明]"),
        PiSlashCommand(name: "name", summary: "设置会话名", source: .known(.builtin), hint: "<名字>"),
        PiSlashCommand(name: "model", summary: "换模型", source: .known(.builtin), hint: "<提供方/模型>"),
        PiSlashCommand(name: "thinking", summary: "设置思考强度", source: .known(.builtin), hint: "<强度>"),
        PiSlashCommand(name: "new", summary: "开一个新会话", source: .known(.builtin)),
        PiSlashCommand(name: "clone", summary: "在当前位置复制出一个新会话", source: .known(.builtin)),
        PiSlashCommand(name: "reload", summary: "重新载入扩展、skill、提示词模板与上下文文件", source: .known(.builtin)),
        PiSlashCommand(name: "plan", summary: "先列计划，确认后再动手", source: .known(.extension)),
        PiSlashCommand(name: "review", summary: "审查当前分支的改动", source: .known(.prompt)),
        PiSlashCommand(name: "changelog", summary: "按提交记录写更新说明", source: .known(.prompt)),
        PiSlashCommand(name: "skill:deploy", summary: "按清单检查并部署到生产", source: .known(.skill)),
        PiSlashCommand(name: "skill:frontend-design", summary: "做界面时先定视觉方向与密度", source: .known(.skill)),
    ]

    /// 演示会话的上下文用量（窗口 20 万 token）：多数宽裕，atlas 用到八成多（百分比加粗转墨色、说明里建议压缩），
    /// rename 用到九成多（胭脂那一档），billing 刚压缩过。
    private static let demoContexts: [String: PiContextUsage] = [
        "atlas": PiContextUsage(tokens: 172_000, window: 200_000),
        "homepage": PiContextUsage(tokens: 31_000, window: 200_000),
        "cuepad": PiContextUsage(tokens: 96_000, window: 200_000),
        "rename": PiContextUsage(tokens: 188_000, window: 200_000),
        "billing": PiContextUsage(tokens: nil, window: 200_000),
    ]

    /// 演示用的 Mac 端状态：各种状态的 Pi 会话（含刚开的、回复框里有草稿的）、发到 Mac 的几条请求。只在库里还没有时写。
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
            ("review", .delegating, nil, nil, DemoRecap(lastPrompt: "让子代理分头审查这两个分支")),
            ("migrate", .compacting, nil, "Flow", DemoRecap(lastPrompt: "把迁移脚本拆成三步", lastReply: "拆好了，三步各自能回滚。")),
            ("billing", .error, "模型拒绝了请求（400）：prompt is too long", "闲鱼", DemoRecap(lastPrompt: "把整个 billing 目录读一遍，总结计费规则")),
            ("notes", .settled, nil, "Career", DemoRecap(
                lastPrompt: "整理一下这周的会议记录", lastReply: "整理好了，放在 `notes/2026-W40.md`。三件待办：**续费域名**、评审计费额度、补 scheduler 测试。")),
            // 终端里刚开、还没说过话
            ("scratch", .settled, nil, "CuePad", DemoRecap()),
            ("piwork", .settled, nil, nil, DemoRecap(
                lastPrompt: "列出 piwork 目录下的文件", lastReply: "目录里有 3 个文件：\n- README.md\n- notes.txt\n- todo.md")),
        ]
        // 历史里再加两个带近况的：一个正在请 Mac 继续，一个不在项目里
        let history: [(String, String?, PiRecap)] = [
            ("landing-copy", "旅行", PiRecap(lastPrompt: "把首页标题换成新文案", lastReply: "改好了，首页标题现在是「把想法写成卡片」。")),
            ("weekly", nil, PiRecap(lastPrompt: "汇总这周的提交", lastReply: "这周 23 个提交，主要是同步和 Agent 页。")),
        ]
        // 文件夹名与还没绑文件夹的项目同名（Flow）：项目的 Agent 空态给一键"绑定 flow 文件夹（3 个会话）"
        for index in 1...3 {
            let id = "flow-\(index)"
            try? await recorder.update(sessionID: id, state: .settled, detail: nil, title: "flow \(index)", folder: "flow", projectID: nil)
            try? await recorder.end(sessionID: id)
        }
        for (id, name, recap) in history {
            try? await recorder.update(sessionID: id, state: .settled, detail: nil, title: id, folder: id, projectID: name.flatMap(project))
            try? await store.writePiTranscript(PiTranscript(sessionID: id, messages: [], recap: recap))
            try? await recorder.end(sessionID: id)
        }
        for (id, state, detail, name, recap) in sessions {
            try? await recorder.update(
                sessionID: id, state: state, detail: detail, title: id, folder: id, projectID: name.flatMap(project), question: recap.question,
                modelState: demoModels, context: demoContexts[id] ?? PiContextUsage(tokens: 12_000, window: 200_000), commands: demoCommands)
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
        let started = Date.now.addingTimeInterval(-260)
        try? await recorder.update(sessionID: "review", state: .delegating, hosted: true, subagents: [
            PiSubagentState(name: "计费额度", role: "审查员", phase: .known(.running), action: "运行 pnpm test billing", startedAt: started),
            PiSubagentState(name: "登录回调", role: "工程师", phase: .known(.failed), action: "请求超时", startedAt: started, settledAt: started.addingTimeInterval(95)),
            PiSubagentState(name: "文档", role: "写手", phase: .known(.done), action: "已补完 README 的同步一节", startedAt: started, settledAt: started.addingTimeInterval(180)),
        ])
        await seedBindings(store, projects: projects)
        // 另一台 Mac 上的会话（演示发过去的话送达与失败）
        try? await PiStateRecorder(store: store, hostID: "demo-mini").update(sessionID: "relay", state: .settled, title: "relay", folder: "relay")
        await seedChats(store)
        if defaults.bool(forKey: "CuePadLongChat") { await seedLongChat(store, project: project("CuePad")) }
        // 会话文件里的压缩记录：对话里的一行系统行（notes 最后一轮回答之后）
        try? await store.writePiTranscript(PiTranscript(
            sessionID: "notes",
            messages: [PiChatMessage(sessionID: "notes", entryID: "compaction-demo", seq: 99, role: .system, text: "已压缩上下文", at: .now.addingTimeInterval(-1_800))],
            recap: PiRecap(lastPrompt: "整理一下这周的会议记录", lastReply: "整理好了，放在 `notes/2026-W40.md`。三件待办：**续费域名**、评审计费额度、补 scheduler 测试。")))
        let states = (try? await store.piSessionPage(PiSessionQuery(limit: 100)).items.map(\.state)) ?? []
        // -CuePadCommand YES：atlas 的会话页回复框上方有一条在路上的命令（看进度行；没有执行它的 Mac，一直在路上）
        if defaults.bool(forKey: "CuePadCommand"), let atlas = states.first(where: { $0.sessionID == "atlas" }) {
            _ = try? await services.requestMacDelivery("/compact", to: atlas, mode: .command)
        }
        await seedTaskStates(store, projects: projects)
        if let relay = states.first(where: { $0.sessionID == "relay" }) {
            // 一条已送达还没进对话、一条没能送达：由一个只认这台演示 Mac 的执行器给出结果
            _ = try? await services.requestMacDelivery("先把迁移脚本在测试库上跑一遍", to: relay, mode: .send)
            _ = try? await services.requestMacDelivery("顺便备份一下线上数据库", to: relay, mode: .send)
            // 发给那台 Mac 上已结束的会话、没能送达：装修项目的"此刻"写这条的原因
            let mini = PiStateRecorder(store: store, hostID: relay.hostID)
            try? await mini.update(sessionID: "quote", state: .settled, title: "quote", folder: "quote", projectID: project("装修"))
            try? await mini.end(sessionID: "quote")
            if let quote = try? await store.piSessionPage(PiSessionQuery(text: "quote")).items.first(where: { $0.state.sessionID == "quote" })?.state {
                _ = try? await services.requestMacDelivery("把报价单备份到网盘", to: quote, mode: .send)
            }
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
        if let notes = states.first(where: { $0.sessionID == "notes" }) {
            services.settings.setReplyDraft(ComposerDraft(text: "续费域名那条再加上截止日期"), for: notes.id)
        }
        if let cuepad = states.first(where: { $0.sessionID == "cuepad" }) {
            _ = try? await services.requestMacDelivery("超时后先重试一次，还失败再报错", to: cuepad, mode: .steer)
        }
    }
}
#endif
