#if DEBUG
import CueStore
import CueText
import SwiftUI

extension DebugScene {
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

    static var loginPage: String { """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>\(String(localized: "登录", table: "Demo"))</title><style>
        body{margin:0;min-height:100vh;display:grid;place-items:center;font:16px -apple-system,system-ui,sans-serif;background:linear-gradient(160deg,#eef2ff,#fdf2f8);color:#1c1b19}
        main{width:min(86vw,360px);padding:28px;border-radius:20px;background:#fff;box-shadow:0 10px 40px #4f46e522}
        h1{margin:0 0 4px;font-size:24px} p{margin:0 0 20px;color:#6b7280}
        input{width:100%;box-sizing:border-box;margin-bottom:12px;padding:12px 14px;border:1px solid #e5e7eb;border-radius:12px;font-size:16px}
        button{width:100%;padding:13px;border:0;border-radius:12px;background:#4f46e5;color:#fff;font-size:16px;font-weight:600}
        #ok{margin-top:14px;color:#059669;min-height:1.2em}</style></head><body><main>
        <h1>\(String(localized: "欢迎回来", table: "Demo"))</h1><p>\(String(localized: "用邮箱登录 Atlas", table: "Demo"))</p>
        <input placeholder="\(String(localized: "邮箱", table: "Demo"))" value="me@example.com"><input placeholder="\(String(localized: "密码", table: "Demo"))" type="password" value="secret">
        <button onclick="document.getElementById('ok').textContent='\(String(localized: "登录成功（演示）", table: "Demo"))'">\(String(localized: "登录", table: "Demo"))</button><div id="ok"></div>
        </main></body></html>
        """ }

    static var review: String { String(localized: """
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
        """, table: "Demo") }

    /// 演示用的一张图（手机上的登录页）存进附件目录，返回正文里引用它的写法；你的话带图片的演示（对话里的、还在路上的）用它。
    static func screenshotMarkup(_ store: CueStore) -> String? {
        screenshotPNG().flatMap { try? store.files.store($0) }.map(CueFormat.imageMarkup(id:))
    }

    /// 手机宽度下登录页的"截图"：渐变底上一张白卡、两个输入框和一个按钮。
    static func screenshotPNG() -> Data? {
        let view = ZStack {
            LinearGradient(colors: [Color(red: 0.93, green: 0.95, blue: 1), Color(red: 0.99, green: 0.95, blue: 0.97)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 12) {
                Text("欢迎回来", tableName: "Demo").font(.system(size: 26, weight: .bold))
                Text("用邮箱登录 Atlas", tableName: "Demo").foregroundStyle(.gray)
                RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.3)).frame(height: 44).overlay(alignment: .leading) { Text("me@example.com").padding(.leading, 14) }
                RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.3)).frame(height: 44).overlay(alignment: .leading) { Text("••••••").padding(.leading, 14) }
                RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.31, green: 0.27, blue: 0.9)).frame(height: 46).overlay { Text("登录", tableName: "Demo").foregroundStyle(.white).bold() }
            }
            .padding(28).frame(width: 320).background(.white, in: RoundedRectangle(cornerRadius: 20))
        }
        .frame(width: 390, height: 640)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage.map { DemoLibrary.encode($0) }
    }

    /// 演示对话：notes 是几轮做完的对话（带工具活动与用时、Markdown），atlas 在处理新的话，homepage、rename 停在问题上，
    /// relay 在另一台 Mac 上（第二句是斜杠技能，存的是 Pi 展开后的样子；发过去的一条已送达还没进对话、一条没能送达）。
    static func seedChats(_ store: CueStore) async {
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
            (String(localized: "整理一下这周的会议记录", table: "Demo"), String(localized: "整理好了，放在 `notes/2026-W40.md`。三件待办：\n\n- **续费域名**（周五前）\n- 评审计费额度\n- 补 scheduler 测试", table: "Demo"), Self.notesWeek, 1.5),
            (String(localized: "续费域名那条加上负责人和链接", table: "Demo"), String(localized: "加好了：负责人写的是你，链接指向注册商的续费页。", table: "Demo"), .init(steps: 1, items: [.init(kind: .edit, target: "notes/2026-W40.md", added: 2, removed: 1)]), 0.4),
            (String(localized: "再把评审计费额度拆成两步", table: "Demo"), String(localized: "拆成了两步：\n\n1. 先对一遍额度表和账单的口径\n2. 再看超额时的提示文案\n\n都放在待办的同一节下面。", table: "Demo"), .init(steps: 2, items: [.init(kind: .read, target: "notes/2026-W40.md"), .init(kind: .edit, target: "notes/2026-W40.md", added: 5, removed: 1)]), 0.8),
            // 最坏的 Markdown：宽表（对齐语法、代码单元格、中英混排长单元格）、引用、嵌套列表、标题、链接、长代码行
            (String(localized: "把三个排序方案的对比做成表格", table: "Demo"), String(localized: """
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
            """, table: "Demo"), .init(steps: 3, items: [.init(kind: .read, target: "bench/sorting.md"), .init(kind: .read, target: "bench/results.csv"), .init(kind: .edit, target: "notes/sorting-compare.md", added: 24)]), 1.0),
        ], startedMinutesAgo: 20)
        await seedPreviews(store, now: now)
        if let kinds = defaults.string(forKey: "CuePadAllKinds") { await seedAllKinds(store, upTo: Int(kinds)) }
        await chat("atlas", [
            (String(localized: "跑一下 scheduler 的测试，失败的话先别改代码，告诉我原因", table: "Demo"), String(localized: "12 个用例里有 **2 个失败**：\n\n1. 发言轮次在 5 人以上时，第 6 位被排到了最前——队列按加入时间排序，但重连的人会拿到新的时间戳。\n2. 登录回调走了旧网关，超时后没有重试。\n\n第一个建议改成按首次加入时间排序，改动在 `scheduler/queue.ts`：\n\n```ts\nqueue.sort((a, b) => a.firstJoinedAt - b.firstJoinedAt)\n```\n\n要我先改第一个吗？", table: "Demo"), Self.testRun, 2),
            (String(localized: "按你说的改成首次加入时间排序，把断言也改了，再跑一遍", table: "Demo"), nil, .init(
                steps: 4,
                items: [
                    .init(kind: .read, target: "scheduler/queue.ts"), .init(kind: .edit, target: "scheduler/queue.ts", added: 3, removed: 1),
                    .init(kind: .edit, target: "scheduler/queue.test.ts", added: 8, removed: 2), .init(kind: .command, target: "pnpm tsc --noEmit", failed: true),
                ]), 0),
        ], startedMinutesAgo: 6)
        await chat("homepage", [
            (String(localized: "把 RSS 输出改成全文", table: "Demo"), nil, nil, 0),
        ], startedMinutesAgo: 3)
        await chat("relay", [
            (String(localized: "看一下线上库的迁移有没有卡住", table: "Demo"), String(localized: "迁移跑到第 14 步停住了：`add_index_on_cards` 在等锁。现在没有别的写入，可以安全重跑。", table: "Demo"), .init(steps: 3, items: [.init(kind: .command, target: "psql -c 'select * from schema_migrations order by id desc limit 3'"), .init(kind: .command, target: "psql -c 'select pid, state, query from pg_stat_activity'"), .init(kind: .command, target: "psql -c 'select * from pg_locks where not granted'")]), 1.2),
            (Self.skillSaid, String(localized: "就像排队上厕所：建索引要把整张表锁一下，可前面有人一直占着没出来，它只能在门口等。占着的人走了，它马上就能进去。", table: "Demo"), nil, 0.3),
        ], startedMinutesAgo: 10)
    }

    /// "/skill:eli5 为什么在等锁" 经 Pi 展开后进会话文件的样子（`PiSkillCall`）。
    private static var skillSaid: String { """
        <skill name="eli5" location="/Users/demo/.agents/skills/eli5/SKILL.md">
        References are relative to /Users/demo/.agents/skills/eli5.

        # 用大白话讲

        - 先给一句结论，再打一个生活里的比方
        - 不用术语；非用不可时当场解释
        - 三句话以内讲完
        </skill>

        \(String(localized: "为什么在等锁", table: "Demo"))
        """ }

    /// `-CuePadDemoMac YES`：演示库里一台会回话的"demo-mac"。发给它的会话的话，像真的经同步那样慢慢走完：
    /// 等一会儿才被接手（发送中）→ 送达用一会儿（送达中）→ 会话状态再晚一点才同步过来（思考中）→ 这一轮做完（该你了），
    /// 录"发出 → 返回列表 → 状态流转"用。Cue 运行在它上面时，你对 Cue 说的话一会儿后交给 Cue（已送达），它想一会儿回一句（`demoCueAnswers`）。
    /// 同步替身报连不上 iCloud 时（`-CuePadSync offline`）它收不到，恢复后再接手。
}
#endif
