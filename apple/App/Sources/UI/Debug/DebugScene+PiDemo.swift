#if DEBUG
import CueStore
import CueText
import OSLog
import SwiftUI

/// 演示库里的 Pi：Mac 同步来的会话状态（含历史）、几段对话与发到 Mac 的请求（iOS 与 Mac 的 session 画面共用）。
extension DebugScene {
    /// 演示脚本自己出的错（读写演示库失败）：演示画面因此停在半路，记下来，不当作没事。
    static let demoLog = Logger(subsystem: AppServices.bundleID, category: "demo")

    /// 会话里的一轮：你的话、Pi 的回答（还没答完是 nil）与这一轮的工具活动，问与答的时刻。
    struct ChatTurn {
        var you: String
        var pi: String?
        var tools: PiChatMessage.Tools?
        var asked: Date
        var answered: Date
    }

    /// 把几轮写成会话的对话与摘要（最后一轮没答完，它的话是进行中的提问、它的工具活动是这一轮已做完的几步）。演示对话与大库的长对话共用。
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
        let pending = turns.last.flatMap { $0.pi == nil ? $0 : nil }
        try await store.writePiTranscript(PiTranscript(
            sessionID: sessionID, messages: messages,
            recap: PiRecap(lastPrompt: done?.you, lastReply: done?.pi, pendingPrompt: pending?.you, pendingTools: pending?.tools)))
    }

    /// 两台 Mac 的项目目录绑定（名字是各自报的，`seedMacAgents`）：Mac Studio 绑了全部带目录的项目，MacBook Air 只绑了 CuePad（新会话里 CuePad 要选 Mac）。
    /// 绑定由本机目录推导，所以先只留 CuePad 的目录发布第二台，再把目录放回去。
    private static func seedBindings(_ store: CueStore, projects: [Project]) async {
        // 只用来写绑定记录里的文件夹名，不建目录
        let workspaces = Workspaces.resolve(isolatedLibrary: nil)
        try? await store.publishDirectoryBindings(host: "demo-mac")
        guard let directories = try? await store.projectDirectories() else { return }
        let others = projects.filter { $0.name != "CuePad" }.map(\.id)
        for id in others { try? await store.setDirectory(nil, for: id) }
        try? await store.publishDirectoryBindings(host: "demo-air")
        for id in others { if let directory = directories[id] { try? await store.setDirectory(directory, for: id) } }
    }

    /// 任务三态：圆桌"乱序"的步骤"复现乱序""改成按首次加入时间排序""部署到预发环境"开了工，正文发给了会话 piwork、atlas、deploy
    /// （步骤记着会话；复现乱序随后完成，它的会话 piwork 已结束：会话页看完成了的任务），"补 3 个重连用例"还没开始；
    /// CuePad"投送超时"的正文发给 notes；CuePad、Flow、圆桌各完成一条（先后完成）。
    private static func seedTaskStates(_ store: CueStore, projects: [Project]) async {
        guard let tasks = try? await store.tasks(.todo).flatMap(\.tasks) else { return }
        // 发出的正文留在任务上，任务记着会话
        func send(_ prefix: String, to session: String) async {
            guard let task = tasks.first(where: { $0.body.hasPrefix(prefix) }) else { return }
            _ = try? await store.recordSend(task.body, to: SendTarget(kind: .piSession, name: session, ref: session), card: task.id)
        }
        await send("复现乱序", to: "piwork")
        await send("投送队列", to: "notes")
        await send("改成按首次", to: "atlas")
        await send("部署到预发", to: "deploy")
        if let reproduce = tasks.first(where: { $0.body.hasPrefix("复现乱序") }) { try? await store.setStatus(reproduce.id, .done) }
        // notes 这一轮做完，会话歇下
        try? await Task.sleep(for: .milliseconds(5))
        _ = try? await PiStateRecorder(store: store, hostID: "demo-mac").update(
            sessionID: "notes", state: .settled, title: "notes", directory: "notes", projectID: projects.first { $0.name == "Career" }?.id,
            times: PiTimes(stateSince: .now, busySince: nil), modelState: demoModels, commands: demoCommands)
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

    /// notes 会话最后一轮：你让 Agent 发页面、截图、报告来看，Agent 先截了手机宽度的图，再在命令行里 `cuepad show` 了两次——
    /// 页面一张卡，截图与评审结论一起一张卡（对话里按创建时间排在你的话与回答之间）；工具清单只有截图那条，发卡片的命令不列（`PiToolLog`）。
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
        for batch in [[(page, "登录页 v2：可点的完整页面")], [(shot, "手机截图：登录钮在键盘上方"), (report, "评审结论：还有三处要改")]] {
            if let added = try? await store.addPreviews(batch.map { (url: $0.0, title: $0.1) }, sessionID: "notes") { created.append(added[0].preview.createdAt) }
        }
        // 对话围着预览的创建时间排：你的话在先，回答在后
        guard let first = created.first, let last = created.last else { return }
        let messages = [
            PiChatMessage(
                sessionID: "notes", entryID: "u9", seq: 8, role: .user, text: "把登录页的新样子、手机上的截图和评审结论发给我看看，样子参考这张" + (screenshotMarkup(store).map { "\n" + $0 } ?? ""),
                at: first.addingTimeInterval(-50)),
            PiChatMessage(
                sessionID: "notes", entryID: "p9", seq: 9, role: .pi, text: "发给你了：完整页面可以直接点按钮试交互，截图是 iPhone 宽度下的样子，评审结论里有两处要你定。",
                at: last.addingTimeInterval(2), tools: .init(steps: 1, items: [.init(kind: .command, target: "npx playwright screenshot --device 'iPhone 15' login-v2.html login-mobile.png")]), roundStartedAt: first.addingTimeInterval(-50)),
        ]
        try? await store.writePiTranscript(PiTranscript(
            sessionID: "notes", messages: messages,
            recap: PiRecap(lastPrompt: messages[0].text, lastReply: messages.last?.text)))
    }

    /// 演示用的工具活动：一周会议记录那一轮读了资料、改了笔记、跑了脚本。
    private static let notesWeek = PiChatMessage.Tools(
        steps: 7,
        items: [
            .init(kind: .read, target: "notes/2026-W39.md"), .init(kind: .read, target: "notes/2026-W40.md"), .init(kind: .read, target: "notes/inbox.md"),
            .init(kind: .edit, target: "notes/2026-W40.md", added: 18, removed: 4), .init(kind: .edit, target: "notes/todo.md", added: 3),
            .init(kind: .command, target: "git status --short"), .init(kind: .command, target: "make lint-notes", failed: true),
        ])

    /// 演示用的工具活动：跑测试那一轮读了测试、跑了测试（一次失败），没有改代码。
    private static let testRun = PiChatMessage.Tools(
        steps: 4,
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

    /// 演示用的一张图（手机上的登录页）存进附件目录，返回正文里引用它的写法；你的话带图片的演示（对话里的、还在路上的）用它。
    private static func screenshotMarkup(_ store: CueStore) -> String? {
        screenshotPNG().flatMap { try? store.files.store($0) }.map(CueFormat.imageMarkup(id:))
    }

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
            ("续费域名那条加上负责人和链接", "加好了：负责人写的是你，链接指向注册商的续费页。", .init(steps: 1, items: [.init(kind: .edit, target: "notes/2026-W40.md", added: 2, removed: 1)]), 0.4),
            ("再把评审计费额度拆成两步", "拆成了两步：\n\n1. 先对一遍额度表和账单的口径\n2. 再看超额时的提示文案\n\n都放在待办的同一节下面。", .init(steps: 2, items: [.init(kind: .read, target: "notes/2026-W40.md"), .init(kind: .edit, target: "notes/2026-W40.md", added: 5, removed: 1)]), 0.8),
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
            """, .init(steps: 3, items: [.init(kind: .read, target: "bench/sorting.md"), .init(kind: .read, target: "bench/results.csv"), .init(kind: .edit, target: "notes/sorting-compare.md", added: 24)]), 1.0),
        ], startedMinutesAgo: 20)
        await seedPreviews(store, now: now)
        if let kinds = defaults.string(forKey: "CuePadAllKinds") { await seedAllKinds(store, upTo: Int(kinds)) }
        await chat("atlas", [
            ("跑一下 scheduler 的测试，失败的话先别改代码，告诉我原因", "12 个用例里有 **2 个失败**：\n\n1. 发言轮次在 5 人以上时，第 6 位被排到了最前——队列按加入时间排序，但重连的人会拿到新的时间戳。\n2. 登录回调走了旧网关，超时后没有重试。\n\n第一个建议改成按首次加入时间排序，改动在 `scheduler/queue.ts`：\n\n```ts\nqueue.sort((a, b) => a.firstJoinedAt - b.firstJoinedAt)\n```\n\n要我先改第一个吗？", Self.testRun, 2),
            ("按你说的改成首次加入时间排序，把断言也改了，再跑一遍", nil, .init(
                steps: 4,
                items: [
                    .init(kind: .read, target: "scheduler/queue.ts"), .init(kind: .edit, target: "scheduler/queue.ts", added: 3, removed: 1),
                    .init(kind: .edit, target: "scheduler/queue.test.ts", added: 8, removed: 2), .init(kind: .command, target: "pnpm tsc --noEmit", failed: true),
                ]), 0),
        ], startedMinutesAgo: 6)
        await chat("homepage", [
            ("把 RSS 输出改成全文", nil, nil, 0),
        ], startedMinutesAgo: 3)
        await chat("relay", [
            ("看一下线上库的迁移有没有卡住", "迁移跑到第 14 步停住了：`add_index_on_cards` 在等锁。现在没有别的写入，可以安全重跑。", .init(steps: 3, items: [.init(kind: .command, target: "psql -c 'select * from schema_migrations order by id desc limit 3'"), .init(kind: .command, target: "psql -c 'select pid, state, query from pg_stat_activity'"), .init(kind: .command, target: "psql -c 'select * from pg_locks where not granted'")]), 1.2),
        ], startedMinutesAgo: 10)
    }

    /// `-CuePadDemoMac YES`：演示库里一台会回话的"demo-mac"。发给它的会话的话，像真的经同步那样慢慢走完：
    /// 等一会儿才被接手（发送中）→ 送达用一会儿（送达中）→ 会话状态再晚一点才同步过来（思考中）→ 这一轮做完（该你了），
    /// 录"发出 → 返回列表 → 状态流转"用。Cue 运行在它上面时，你对 Cue 说的话一会儿后交给 Cue（已送达），它想一会儿回一句（`demoCueAnswers`）。
    /// 同步替身报连不上 iCloud 时（`-CuePadSync offline`）它收不到，恢复后再接手。
    static func runDemoMac(_ services: AppServices) async {
        let store = services.store, host = "demo-mac"
        func reachable() async {
            for await offline in Observations({ services.syncStatus == .offline }) where !offline { return }
        }
        Task {
            do {
                // 每次变化都重读此刻还没交出去的：攒下的旧变化不再各等一遍
                for try await waiting in store.observe({ try toDemoCue($0) }) where !waiting.isEmpty {
                    guard try await !toDemoCue(store).isEmpty else { continue }
                    await reachable()
                    try await Task.sleep(for: .seconds(1.5))
                    try await store.markCueMessagesDelivered(toDemoCue(store))
                    try await demoCueAnswers(store)
                }
            } catch {
                demoLog.error("演示 Mac 交给 Cue 停了：\(error)")
            }
        }
        do {
            for try await pending in store.observe({ store in
                try store.deliveryRequests().filter { $0.hostID == host && $0.status == .known(.pending) }.map(\.id)
            }) where !pending.isEmpty {
                await reachable()
                try await Task.sleep(for: .seconds(1.2))
                // 与真的 Mac 一样，说出去的话送达后记一条发送记录（任务因此进行中、关联到这个会话）
                let executor = DeliveryExecutor(store: store, hostID: host, onIssue: { _ in }) { request in
                    try? await Task.sleep(for: .seconds(1))
                    if let mode = request.mode.known, DeliveryMode.toSession.contains(mode), mode != .answer {
                        _ = try? await store.recordSend(request.content, to: request.target, card: request.cardID, delivery: request.id, origin: request.origin)
                    }
                    return .succeeded
                }
                try await executor.start()
                for try await open in store.observe({ store in
                    try store.deliveryRequests().contains { pending.contains($0.id) && $0.isOpen }
                }) where !open { break }
                await executor.stop()
                // 各自演一轮，不挡住下一批话的接手
                for id in pending { Task { await playRound(for: id, store: store, host: host) } }
            }
        } catch is CancellationError {
        } catch {
            demoLog.error("演示 Mac 接手停了：\(error)")
        }
    }

    /// 演示 Mac 上的 Cue 接到你的话：思考几秒再回一句（同值班的 Mac 写下的样子，上下文照旧），看发出后的"思考中"与回答落下。
    private static func demoCueAnswers(_ store: CueStore) async throws {
        let context = try await store.cueState()?.context
        try await store.setCueState(.thinking, context: context)
        try await Task.sleep(for: .seconds(4))
        _ = try await store.addCueMessage(.cue, text: "收到，我这就去看。")
        try await store.setCueState(.settled, context: context)
    }

    /// 你对运行在演示 Mac 上的 Cue 说了、还没交给它的话；演示 Mac 不在线（`-CuePadCuePresence asleep`，没写在线记录）时它收不到。
    private static func toDemoCue(_ store: isolated CueStore) throws -> [UUID] {
        guard try store.cueProfile()?.hostID == "demo-mac", try store.macOnline("demo-mac") else { return [] }
        return try store.cueMessagesToDeliver().filter { $0.author == .known(.you) }.map(\.id)
    }

    /// `-CuePadCycle YES`（配 `-CuePadDemo YES`，画面就绪后开始、一直循环）：scratch 一个会话依次走过各种状态，录状态切换的动效用（`xc.sh rec`）——
    /// 发出一句（发送中，演示 Mac 接手，见 `runDemoMac`）→ 思考中 → 做完（有新回复）→ 等你确认 → 出错，再从发出一句开始。
    /// 会话换状态就换位置（按要你注意的先后排）：配 iOS 的 projectagent 与 `-CuePadProject CuePad`，列表只剩这个项目的几张卡，它不会出屏。
    static func cycleIfAsked(_ services: AppServices) async {
        guard defaults.bool(forKey: "CuePadCycle") else { return }
        let store = services.store
        if !defaults.bool(forKey: "CuePadDemoMac") { Task { await runDemoMac(services) } }
        let query = PiSessionQuery(id: PiSessionState.recordID(sessionID: "scratch"))
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        func set(_ state: PiWorkState, _ detail: String, question: PiQuestion? = nil) async {
            guard let session = try? await store.piSessionPage(query).items.first?.state else { return }
            await replay(session, as: state, detail: detail, question: question, recorder: recorder)
        }
        // 说过话的会话做完一轮才是"有新回复"（刚开的还是新会话）
        try? await store.writePiTranscript(PiTranscript(
            sessionID: "scratch", messages: [], recap: PiRecap(lastPrompt: "先跑一遍测试", lastReply: "全部通过。")))
        while !Task.isCancelled {
            guard let session = try? await store.piSessionPage(query).items.first?.state,
                  (try? await store.requestDelivery("再跑一遍测试", to: session.target, on: session.hostID, mode: .send)) != nil else { return }
            // 等演示 Mac 走完这一轮：干过活、又歇下
            var worked = false
            do {
                for try await state in store.observe({ try $0.piSessionPage(query).items.first?.state.state }) {
                    if state?.isWorking == true { worked = true } else if worked, state == .known(.settled) { break }
                }
            } catch { return }
            // 每个状态停留的时长是演示节奏，不是在等别的事
            try? await Task.sleep(for: .seconds(2.5))
            await set(.waitingForUser, "要提交吗？", question: PiQuestion(promptID: "cycle", kind: .confirm, text: "要提交吗？"))
            try? await Task.sleep(for: .seconds(3))
            await set(.error, "模型拒绝了请求（400）")
            try? await Task.sleep(for: .seconds(3))
        }
    }

    /// 会话状态晚于送达结果同步过来：先进入思考，过一会儿做完。
    private static func playRound(for request: UUID, store: CueStore, host: String) async {
        guard let ref = try? await store.deliveryRequest(request)?.target.ref,
              let session = try? await store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: ref))).items.first?.state
        else { return }
        let recorder = PiStateRecorder(store: store, hostID: host)
        try? await Task.sleep(for: .seconds(0.8))
        await replay(session, as: .thinking, recorder: recorder)
        try? await Task.sleep(for: .seconds(2.5))
        await replay(session, as: .settled, recorder: recorder)
    }

    /// 演示会话换一个状态：名字、所在、模型、命令与上下文照旧（记录器每次整份写入，不带上就被清掉）。
    private static func replay(
        _ session: PiSessionState, as state: PiWorkState, detail: String? = nil, question: PiQuestion? = nil, recorder: PiStateRecorder
    ) async {
        _ = try? await recorder.update(
            sessionID: session.sessionID, state: state, detail: detail, title: session.title, directory: session.folder, projectID: session.projectID,
            question: question, modelState: PiModelState(model: session.model, thinking: session.thinking, models: demoModels.models),
            context: session.context, commands: demoCommands, agent: session.agent.known)
    }

    private static func model(_ provider: String, _ id: String, _ name: String, _ levels: [PiThinkingLevel]) -> PiModelOption {
        PiModelOption(key: PiModelKey(provider: provider, id: id), name: name, thinkingLevels: levels)
    }

    /// 演示会话的模型配置，按哪家 Agent：Pi 的模型带提供方（几家各一两个，最后一个是用户自定义的提供方，菜单里不带标志）；
    /// OpenCode 的经 OpenRouter 转发（id 形如 `anthropic/claude-…`，标志按模型家族认）；
    /// Codex 与 Claude Code 是它们自己报的清单，照录像带里 Codex 的 `model/list`（GPT 系，`ultra` 不是 CuePad 认识的档，不列）
    /// 与 Claude Code 的 `initialize`（Claude 系），提供方是这一家（`AgentKind.modelProvider`），与真会话上报的一样。
    static func demoModels(for agent: AgentKind?) -> PiModelState {
        func listed(_ models: [PiModelOption], current: Int, thinking: PiThinkingLevel) -> PiModelState {
            PiModelState(model: models[current], thinking: .known(thinking), models: models)
        }
        let levels: [PiThinkingLevel] = [.low, .medium, .high, .xhigh, .max]
        switch agent {
        case .opencode:
            return listed([
                model("openrouter", "anthropic/claude-sonnet-5", "Claude Sonnet 5", [.low, .medium, .high]),
                model("openrouter", "google/gemini-3-pro", "Gemini 3 Pro", [.low, .high]),
                model("openrouter", "qwen/qwen3-coder", "Qwen3 Coder", [.off]),
            ], current: 0, thinking: .medium)
        case .codex:
            let provider = AgentKind.codex.modelProvider ?? ""
            return listed([
                model(provider, "gpt-6.1-sol", "GPT-6.1-Sol", levels), model(provider, "gpt-6-astra", "GPT-6-Astra", levels),
                model(provider, "gpt-6-sol", "GPT-6-Sol", levels), model(provider, "gpt-6-luna", "GPT-6-Luna", levels),
                model(provider, "gpt-5.6-terra", "GPT-5.6-Terra", levels),
            ], current: 0, thinking: .medium)
        case .claudeCode:
            let provider = AgentKind.claudeCode.modelProvider ?? ""
            return listed([
                model(provider, "default", "Default (recommended)", levels), model(provider, "opus", "Opus", levels),
                model(provider, "fable", "Fable", levels), model(provider, "sonnet", "Sonnet", levels), model(provider, "haiku", "Haiku", levels),
            ], current: 1, thinking: .high)
        case .pi, nil:
            return demoModels
        }
    }

    static let demoModels: PiModelState = {
        let opus = model("anthropic", "claude-opus-5-5-20260901", "Claude Opus 5.5", [.low, .medium, .high, .max])
        return PiModelState(model: opus, thinking: .known(.medium), models: [
            opus,
            model("anthropic", "claude-sonnet-5-20260801", "Claude Sonnet 5", [.off, .low, .medium, .high]),
            model("openai-codex", "gpt-6-luna", "GPT-6 Luna", [.off, .low, .high]),
            model("xai", "grok-5", "Grok 5", [.low, .high]),
            model("deepseek", "deepseek-v4", "DeepSeek V4", [.off, .high]),
            model("kimi-coding", "kimi-k3", "Kimi K3", [.off]),
            model("xiaomi", "mimo-v3-pro", "MiMo V3 Pro", [.off, .high]),
            model("lab-proxy", "house-1", "", [.off]),
        ])
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

    /// 演示的几台 Mac 上的 Agent（`MacAgents`，配 `-CuePadDemo YES`）：工作室的 Mac Studio（demo-mac，Cue 运行在这台）与 Mac 上的这台本机
    /// 有 Pi、Claude Code、Codex（OpenCode 没装：新会话里不列它），demo-mini 有 Claude Code 与 Codex；
    /// MacBook Air（demo-air，只绑了 CuePad）一家都不能用，各有原因（新会话里选"CuePad · MacBook Air"看为什么）。
    /// Mac 上给 `-CuePadHost bare` 时本机是一家都不能用的那台（看 + 的悬停与表单里的原因）；本机的记录会被它自己的探测改写成隔离目录里真实的样子。
    /// 各家的模型与不指定时用的那个照演示会话报的（`demoModels(for:)`）。
    static func seedMacAgents(_ services: AppServices) async {
        func agent(_ kind: AgentKind) -> MacAgent {
            let state = demoModels(for: kind)
            return MacAgent(kind: kind, model: state.model?.key, models: state.models)
        }
        let full = [agent(.pi), agent(.claudeCode), agent(.codex)]
        let bare = [
            MacAgentProblem(kind: .pi, reason: "没登录"), MacAgentProblem(kind: .claudeCode, reason: "没装"), MacAgentProblem(kind: .codex, reason: "没装"),
        ]
        let store = services.store
        _ = try? await store.recordMacAgents(host: "demo-mac", name: "Mac Studio", full)
        _ = try? await store.recordMacAgents(host: "demo-mini", name: "Mac mini", [agent(.claudeCode), agent(.codex)])
        _ = try? await store.recordMacAgents(host: "demo-air", name: "MacBook Air", [], problems: bare)
        #if os(macOS)
        let local = services.hostID
        _ = try? await store.recordMacAgents(
            host: local, name: "这台 Mac", local == "mac-bare" ? [] : full, problems: local == "mac-bare" ? bare : [])
        #endif
    }

    /// 不是 Pi 的演示会话（其余是 Pi）：都开在终端里，能做的按各家（`AgentCapabilities`）——cuepad 是 Claude Code（回复框只有文字、没有停止与模型），
    /// homepage 是 Codex（能作答、换模型，没有斜杠命令），billing 是 OpenCode，历史里的 weekly 是 Claude Code。
    private static let demoAgents: [String: AgentKind] = ["cuepad": .claudeCode, "homepage": .codex, "billing": .opencode, "weekly": .claudeCode]

    /// 演示用的 Mac 端状态：各种状态、各家 Agent 的会话（含刚开的、回复框里有草稿的）、发到 Mac 的几条请求。只在库里还没有时写。
    static func seedRemote(_ services: AppServices) async {
        let store = services.store
        // 演示库的会话索引已写成历史；这里补的是演示 Mac 的在线会话，它有在线的就是写过了。只看演示 Mac：
        // 截图实例的连接目录是各检出共用的，别处起的 Pi 会话会先连上来，算上它就一个演示会话都不补
        guard (try? await store.piSessionPage(.live).items.contains { $0.state.hostID == "demo-mac" }) == false, let projects = try? await store.projects() else { return }
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
        // 文件夹名与还没绑文件夹的项目同名（Flow）：手机给项目换文件夹时的候选里有它
        for index in 1...3 {
            let id = "flow-\(index)"
            _ = try? await recorder.update(sessionID: id, state: .settled, detail: nil, title: "flow \(index)", directory: "flow", projectID: nil)
            try? await recorder.end(sessionID: id)
        }
        for (id, name, recap) in history {
            _ = try? await recorder.update(
                sessionID: id, state: .settled, detail: nil, title: id, directory: id, projectID: name.flatMap(project), agent: demoAgents[id])
            try? await store.writePiTranscript(PiTranscript(sessionID: id, messages: [], recap: recap))
            try? await recorder.end(sessionID: id)
        }
        for (id, state, detail, name, recap) in sessions {
            _ = try? await recorder.update(
                sessionID: id, state: state, detail: detail, title: id, directory: id, projectID: name.flatMap(project), question: recap.question,
                modelState: demoModels(for: demoAgents[id]), context: demoContexts[id] ?? PiContextUsage(tokens: 12_000, window: 200_000), commands: demoCommands,
                agent: demoAgents[id])
            try? await store.writePiTranscript(PiTranscript(
                sessionID: id, messages: [],
                recap: PiRecap(lastPrompt: recap.lastPrompt, lastReply: recap.lastReply, pendingPrompt: recap.pendingPrompt)))
        }
        try? await recorder.end(sessionID: "piwork")
        // 没指定项目的想法：进默认项目
        for body in ["周末读完《设计心理学》第三章", "菜单栏面板能不能直接拖图进来？", "给落地页换一张首图"] {
            _ = try? await store.createCard(body: body)
        }
        // 后台托管、带八个子代理的会话（两个在跑、一个失败、其余已交回或空闲：名册一行要让在跑的先被看到）
        let started = Date.now.addingTimeInterval(-260)
        func settled(_ name: String, _ role: String, _ phase: PiSubagentPhase, _ action: String, after seconds: TimeInterval) -> PiSubagentState {
            PiSubagentState(name: name, role: role, phase: .known(phase), action: action, startedAt: started, settledAt: started.addingTimeInterval(seconds),
                            model: "anthropic/claude-sonnet-5-5")
        }
        _ = try? await recorder.update(sessionID: "review", state: .delegating, hosted: true, subagents: [
            PiSubagentState(name: "计费额度", role: "哨兵", phase: .known(.running), action: "运行 pnpm test billing", startedAt: started, model: "anthropic/claude-opus-5-5"),
            PiSubagentState(name: "同步冲突", role: "工程师", phase: .known(.running), action: "改 CardLinks.repairs", startedAt: started.addingTimeInterval(40),
                            model: "openai-codex/gpt-6.1-sol"),
            settled("登录回调", "工程师", .failed, "请求超时", after: 95),
            settled("文档", "批量工", .done, "已补完 README 的同步一节", after: 180),
            settled("迁移脚本", "工程师", .done, "已在测试库上跑通", after: 150),
            settled("类型检查", "哨兵", .done, "没有新增警告", after: 60),
            settled("截图", "设计师", .done, "已出浅色、深色各一组", after: 120),
            PiSubagentState(name: "性能", role: "工程师", phase: .known(.idle), action: ""),
        ])
        await seedBindings(store, projects: projects)
        // 另一台 Mac 上的会话（演示发过去的话送达与失败）
        _ = try? await PiStateRecorder(store: store, hostID: "demo-mini").update(sessionID: "relay", state: .settled, title: "relay", directory: "relay")
        await seedChats(store)
        if defaults.bool(forKey: "CuePadLongChat") { await seedLongChat(store, project: project("CuePad")) }
        // 会话文件里的压缩记录：对话里的一行系统行（notes 最后一轮回答之后）
        try? await store.writePiTranscript(PiTranscript(
            sessionID: "notes",
            messages: [PiChatMessage(sessionID: "notes", entryID: "compaction-demo", seq: 99, role: .system, text: PiNotice.compacted.rawValue, at: .now.addingTimeInterval(-1_800))],
            recap: PiRecap(lastPrompt: "整理一下这周的会议记录", lastReply: "整理好了，放在 `notes/2026-W40.md`。三件待办：**续费域名**、评审计费额度、补 scheduler 测试。")))
        let states = (try? await store.piSessionPage(PiSessionQuery(limit: 100)).items.map(\.state)) ?? []
        // -CuePadCommand YES：atlas 的会话页回复框上方有一条在路上的命令（看进度行；没有执行它的 Mac，一直在路上）
        if defaults.bool(forKey: "CuePadCommand"), let atlas = states.first(where: { $0.sessionID == "atlas" }) {
            _ = try? await services.store.requestDelivery("/compact", to: atlas.target, on: atlas.hostID, mode: .command)
        }
        await seedTaskStates(store, projects: projects)
        if let relay = states.first(where: { $0.sessionID == "relay" }) {
            // 一条已送达还没进对话、一条没能送达：由一个只认这台演示 Mac 的执行器给出结果
            _ = try? await services.store.requestDelivery("先把迁移脚本在测试库上跑一遍，报错长这样" + (screenshotMarkup(store).map { "\n" + $0 } ?? ""), to: relay.target, on: relay.hostID, mode: .send)
            _ = try? await services.store.requestDelivery("顺便备份一下线上数据库", to: relay.target, on: relay.hostID, mode: .send)
            // 发给那台 Mac 上已结束的会话、没能送达：装修项目的"此刻"写这条的原因
            let mini = PiStateRecorder(store: store, hostID: relay.hostID)
            _ = try? await mini.update(sessionID: "quote", state: .settled, title: "quote", directory: "quote", projectID: project("装修"))
            try? await mini.end(sessionID: "quote")
            if let quote = try? await store.piSessionPage(PiSessionQuery(text: "quote")).items.first(where: { $0.state.sessionID == "quote" })?.state {
                _ = try? await services.store.requestDelivery("把报价单备份到网盘", to: quote.target, on: quote.hostID, mode: .send)
            }
            relayExecutor = DeliveryExecutor(store: store, hostID: relay.hostID, onIssue: { _ in }) { request in
                request.content.contains("备份") ? .failed("那台 Mac 上的 Pi 已经退出，没能送进去") : .succeeded
            }
            try? await relayExecutor?.start()
        }
        if let atlas = states.first(where: { $0.sessionID == "atlas" }) {
            _ = try? await services.store.requestDelivery("改完再看看登录回调那个超时", to: atlas.target, on: atlas.hostID)
        }
        if let landing = states.first(where: { $0.sessionID == "landing-copy" }) {
            // 发给已结束的会话：Mac 先在后台唤醒它
            _ = try? await services.store.requestDelivery("标题再短一点", to: landing.target, on: landing.hostID, mode: .send)
        }
        if let notes = states.first(where: { $0.sessionID == "notes" }) {
            // 回复框里还挂着两条对最后那轮回答的批注（对话里那两处带高亮）
            let reply = PiChatMessage.recordID(sessionID: "notes", entryID: "p9")
            services.settings.setReplyDraft(ComposerDraft(text: "续费域名那条再加上截止日期", notes: [
                ReplyNote(entry: reply, run: 0, location: 5, quote: "完整页面可以直接点按钮试交互", note: "要能离线打开"),
                ReplyNote(entry: reply, run: 0, location: 38, quote: "评审结论里有两处要你定", note: "这两处我来定，先列出来"),
            ]), for: notes.id)
        }
    }
}
#endif
