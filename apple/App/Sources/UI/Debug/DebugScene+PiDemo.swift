#if DEBUG
import CueStore
import CueText
import Foundation
import OSLog

/// 演示库里的 Pi：Mac 同步来的会话状态（含历史）、几段对话与发到 Mac 的请求（iOS 与 Mac 的 session 画面共用）。
extension DebugScene {
    /// 演示脚本自己出的错（读写演示库失败）：演示画面因此停在半路，记下来，不当作没事。
    static let demoLog = Logger(subsystem: AppIdentity.id, category: "demo")

    /// 演示会话的摘要与弹窗：摘要写成对话的投影，弹窗交给状态记录器（与真实来源一致）。
    private struct DemoRecap {
        var lastPrompt: String?
        var lastReply: String?
        var pendingPrompt: String?
        var question: PiQuestion?
    }

    /// 演示对话的另一台 Mac 的执行器（留住它，结果写回后照常显示）。
    private static var relayExecutor: DeliveryExecutor?

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
            ("atlas", .tool, "bash · pnpm test -- scheduler", String(localized: "圆桌", table: "Demo"), DemoRecap(
                lastPrompt: String(localized: "跑一下 scheduler 的测试，失败的话先别改代码，告诉我原因", table: "Demo"),
                lastReply: String(localized: "上一轮 12 个用例里有 **2 个失败**：\n\n1. 发言轮次在 5 人以上时，第 6 位的顺序被排到了最前——队列按加入时间排序，但重连的人会拿到新的时间戳。\n2. 登录回调走了旧网关，超时后没有重试。\n\n第一个建议改成按首次加入时间排序，改动在 `scheduler/queue.ts`：\n\n```ts\nqueue.sort((a, b) => a.firstJoinedAt - b.firstJoinedAt)\n```\n\n第二个需要把回调地址换成统一网关。\n\n另外顺手看了一眼覆盖率：scheduler 目录是 71%，主要缺重连和超时两条路径。两个失败修好后，我可以补上这两条的用例，大概再加 6 个测试。\n\n要我先改第一个吗？", table: "Demo"),
                pendingPrompt: String(localized: "按你说的改成首次加入时间排序，把断言也改了，再跑一遍", table: "Demo"))),
            ("homepage", .waitingForUser, String(localized: "要覆盖 public/feed.xml 吗？", table: "Demo"), String(localized: "个人网站", table: "Demo"), DemoRecap(
                lastPrompt: String(localized: "把 RSS 输出改成全文", table: "Demo"),
                question: PiQuestion(
                    promptID: "demo-prompt", kind: .select, text: String(localized: "要覆盖 public/feed.xml 吗？", table: "Demo"), options: [String(localized: "覆盖", table: "Demo"), String(localized: "另存为 feed-full.xml", table: "Demo"), String(localized: "取消", table: "Demo")]))),
            ("cuepad", .thinking, nil, "CuePad", DemoRecap(
                lastPrompt: String(localized: "先跑一遍全部测试", table: "Demo"), lastReply: String(localized: "全部通过，共 214 个。", table: "Demo"), pendingPrompt: String(localized: "看看投送队列超时的那个 bug", table: "Demo"))),
            ("notes-edit", .waitingForUser, String(localized: "编辑提交说明", table: "Demo"), nil, DemoRecap(
                lastPrompt: String(localized: "写一段提交说明", table: "Demo"),
                question: PiQuestion(promptID: nil, kind: .unknown("editor"), text: String(localized: "编辑提交说明\n在编辑器里改好后保存", table: "Demo")))),
            ("rename", .waitingForUser, String(localized: "新分支叫什么？", table: "Demo"), "CuePad", DemoRecap(
                lastPrompt: String(localized: "把这批改动挪到新分支上", table: "Demo"),
                question: PiQuestion(promptID: "demo-text", kind: .text, text: String(localized: "新分支叫什么？", table: "Demo")))),
            ("deploy", .waitingForUser, String(localized: "部署到生产吗？", table: "Demo"), nil, DemoRecap(
                lastPrompt: String(localized: "测试都过了就部署", table: "Demo"),
                question: PiQuestion(promptID: "demo-confirm", kind: .confirm, text: String(localized: "部署到生产吗？\n会替换当前线上的 1.4.2", table: "Demo")))),
            ("review", .delegating, nil, nil, DemoRecap(lastPrompt: String(localized: "让子代理分头审查这两个分支", table: "Demo"))),
            ("migrate", .compacting, nil, "Flow", DemoRecap(lastPrompt: String(localized: "把迁移脚本拆成三步", table: "Demo"), lastReply: String(localized: "拆好了，三步各自能回滚。", table: "Demo"))),
            ("billing", .error, String(localized: "模型拒绝了请求（400）：prompt is too long", table: "Demo"), String(localized: "闲鱼", table: "Demo"), DemoRecap(lastPrompt: String(localized: "把整个 billing 目录读一遍，总结计费规则", table: "Demo"))),
            ("notes", .settled, nil, "Career", DemoRecap(
                lastPrompt: String(localized: "整理一下这周的会议记录", table: "Demo"), lastReply: String(localized: "整理好了，放在 `notes/2026-W40.md`。三件待办：**续费域名**、评审计费额度、补 scheduler 测试。", table: "Demo"))),
            // 终端里刚开、还没说过话
            ("scratch", .settled, nil, "CuePad", DemoRecap()),
            ("piwork", .settled, nil, nil, DemoRecap(
                lastPrompt: String(localized: "列出 piwork 目录下的文件", table: "Demo"), lastReply: String(localized: "目录里有 3 个文件：\n- README.md\n- notes.txt\n- todo.md", table: "Demo"))),
        ]
        // 历史里再加几个带近况的：一个正在请 Mac 继续，一个不在项目里；pricing 是 Cue 核对过的那批四份的会话（`seedDeliveries`），会话页里那批横着滑
        let history: [(String, String?, PiRecap)] = [
            ("landing-copy", String(localized: "旅行", table: "Demo"), PiRecap(lastPrompt: String(localized: "把首页标题换成新文案", table: "Demo"), lastReply: String(localized: "改好了，首页标题现在是「把想法写成卡片」。", table: "Demo"))),
            ("weekly", nil, PiRecap(lastPrompt: String(localized: "汇总这周的提交", table: "Demo"), lastReply: String(localized: "这周 23 个提交，主要是同步和 Agent 页。", table: "Demo"))),
            ("pricing", String(localized: "个人网站", table: "Demo"), PiRecap(lastPrompt: String(localized: "重做定价区，三档在窄屏别挤成两行", table: "Demo"), lastReply: String(localized: "改好了，网页、对比表、宽屏截图和改动说明都发给你了。", table: "Demo"))),
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
        // 在问的从几分钟前问起（等了多久从进入这一态算，不给就是写入这一刻："1 秒"）
        let asked: [String: TimeInterval] = ["deploy": 21, "rename": 14, "homepage": 9, "notes-edit": 4]
        for (id, state, detail, name, recap) in sessions {
            _ = try? await recorder.update(
                sessionID: id, state: state, detail: detail, title: id, directory: id, projectID: name.flatMap(project), question: recap.question,
                times: asked[id].map { PiTimes(stateSince: .now.addingTimeInterval(-$0 * 60), busySince: nil) },
                modelState: demoModels(for: demoAgents[id]), context: demoContexts[id] ?? PiContextUsage(tokens: 12_000, window: 200_000), commands: demoCommands(for: demoAgents[id]),
                agent: demoAgents[id])
            try? await store.writePiTranscript(PiTranscript(
                sessionID: id, messages: [],
                recap: PiRecap(lastPrompt: recap.lastPrompt, lastReply: recap.lastReply, pendingPrompt: recap.pendingPrompt)))
        }
        try? await recorder.end(sessionID: "piwork")
        // 没指定项目的想法：进默认项目
        for body in [String(localized: "周末读完《设计心理学》第三章", table: "Demo"), String(localized: "菜单栏面板能不能直接拖图进来？", table: "Demo"), String(localized: "给落地页换一张首图", table: "Demo")] {
            _ = try? await store.createCard(body: body)
        }
        // 后台托管、带八个子代理的会话（两个在跑、一个失败、其余已交回或空闲：名册一行要让在跑的先被看到）
        let started = Date.now.addingTimeInterval(-260)
        func settled(_ name: String, _ role: String, _ phase: PiSubagentPhase, _ action: String, after seconds: TimeInterval) -> PiSubagentState {
            PiSubagentState(name: name, role: role, phase: .known(phase), action: action, startedAt: started, settledAt: started.addingTimeInterval(seconds),
                            model: "anthropic/claude-sonnet-5-5")
        }
        _ = try? await recorder.update(sessionID: "review", state: .delegating, hosted: true, subagents: [
            PiSubagentState(name: String(localized: "计费额度", table: "Demo"), role: String(localized: "哨兵", table: "Demo"), phase: .known(.running), action: String(localized: "运行 pnpm test billing", table: "Demo"), startedAt: started, model: "anthropic/claude-opus-5-5"),
            PiSubagentState(name: String(localized: "同步冲突", table: "Demo"), role: String(localized: "工程师", table: "Demo"), phase: .known(.running), action: String(localized: "改 CardLinks.repairs", table: "Demo"), startedAt: started.addingTimeInterval(40),
                            model: "openai-codex/gpt-6.1-sol"),
            settled(String(localized: "登录回调", table: "Demo"), String(localized: "工程师", table: "Demo"), .failed, String(localized: "请求超时", table: "Demo"), after: 95),
            settled(String(localized: "文档", table: "Demo"), String(localized: "批量工", table: "Demo"), .done, String(localized: "已补完 README 的同步一节", table: "Demo"), after: 180),
            settled(String(localized: "迁移脚本", table: "Demo"), String(localized: "工程师", table: "Demo"), .done, String(localized: "已在测试库上跑通", table: "Demo"), after: 150),
            settled(String(localized: "类型检查", table: "Demo"), String(localized: "哨兵", table: "Demo"), .done, String(localized: "没有新增警告", table: "Demo"), after: 60),
            settled(String(localized: "截图", table: "Demo"), String(localized: "设计师", table: "Demo"), .done, String(localized: "已出浅色、深色各一组", table: "Demo"), after: 120),
            PiSubagentState(name: String(localized: "性能", table: "Demo"), role: String(localized: "工程师", table: "Demo"), phase: .known(.idle), action: ""),
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
            recap: PiRecap(lastPrompt: String(localized: "整理一下这周的会议记录", table: "Demo"), lastReply: String(localized: "整理好了，放在 `notes/2026-W40.md`。三件待办：**续费域名**、评审计费额度、补 scheduler 测试。", table: "Demo"))))
        let states = (try? await store.piSessionPage(PiSessionQuery(limit: 100)).items.map(\.state)) ?? []
        // -CuePadCommand YES：atlas 的会话页回复框上方有一条在路上的命令（看进度行；没有执行它的 Mac，一直在路上）
        if defaults.bool(forKey: "CuePadCommand"), let atlas = states.first(where: { $0.sessionID == "atlas" }) {
            _ = try? await services.store.requestDelivery("/compact", to: atlas.target, on: atlas.hostID, mode: .command)
        }
        await seedTaskStates(store, projects: projects)
        if let relay = states.first(where: { $0.sessionID == "relay" }) {
            // 一条已送达还没进对话、一条没能送达：由一个只认这台演示 Mac 的执行器给出结果
            _ = try? await services.store.requestDelivery(String(localized: "先把迁移脚本在测试库上跑一遍，报错长这样", table: "Demo") + (screenshotMarkup(store).map { "\n" + $0 } ?? ""), to: relay.target, on: relay.hostID, mode: .send)
            _ = try? await services.store.requestDelivery(String(localized: "顺便备份一下线上数据库", table: "Demo"), to: relay.target, on: relay.hostID, mode: .send)
            // 发给那台 Mac 上已结束的会话、没能送达：装修项目的"此刻"写这条的原因
            let mini = PiStateRecorder(store: store, hostID: relay.hostID)
            _ = try? await mini.update(sessionID: "quote", state: .settled, title: "quote", directory: "quote", projectID: project(String(localized: "装修", table: "Demo")))
            try? await mini.end(sessionID: "quote")
            if let quote = try? await store.piSessionPage(PiSessionQuery(text: "quote")).items.first(where: { $0.state.sessionID == "quote" })?.state {
                _ = try? await services.store.requestDelivery(String(localized: "把报价单备份到网盘", table: "Demo"), to: quote.target, on: quote.hostID, mode: .send)
            }
            relayExecutor = DeliveryExecutor(store: store, hostID: relay.hostID, onIssue: { _ in }) { request in
                [String(localized: "顺便备份一下线上数据库", table: "Demo"), String(localized: "把报价单备份到网盘", table: "Demo")].contains(request.content)
                    ? .failed(ShownText(SendError.sessionNotOnThisMac(request.target.name))) : .succeeded
            }
            try? await relayExecutor?.start()
        }
        if let atlas = states.first(where: { $0.sessionID == "atlas" }) {
            _ = try? await services.store.requestDelivery(String(localized: "改完再看看登录回调那个超时", table: "Demo"), to: atlas.target, on: atlas.hostID)
        }
        if let landing = states.first(where: { $0.sessionID == "landing-copy" }) {
            // 发给已结束的会话：Mac 先在后台唤醒它
            _ = try? await services.store.requestDelivery(String(localized: "标题再短一点", table: "Demo"), to: landing.target, on: landing.hostID, mode: .send)
        }
        if let notes = states.first(where: { $0.sessionID == "notes" }) {
            // 回复框里还挂着两条对最后那轮回答的批注（对话里那两处带高亮）
            let reply = PiChatMessage.recordID(sessionID: "notes", entryID: "p9")
            services.settings.setReplyDraft(ComposerDraft(text: String(localized: "续费域名那条再加上截止日期", table: "Demo"), notes: [
                ReplyNote(entry: reply, run: 0, location: 5, quote: String(localized: "完整页面可以直接点按钮试交互", table: "Demo"), note: String(localized: "要能离线打开", table: "Demo")),
                ReplyNote(entry: reply, run: 0, location: 38, quote: String(localized: "评审结论里有两处要你定", table: "Demo"), note: String(localized: "这两处我来定，先列出来", table: "Demo")),
            ]), for: notes.id)
        }
    }
}
#endif
