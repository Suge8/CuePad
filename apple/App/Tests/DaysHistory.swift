#if os(macOS)
import CueAgent
import CuePi
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 两周的历史：启用 Cue 之前写进库（时刻往回倒），在做的两件事挂着假会话。
@MainActor
final class DaysHistory {
    private(set) var storage: ScriptedSession?
    private(set) var weekly: ScriptedSession?
    private(set) var logged = 0, memoryLines = 0, pinned = 0, doneTasks = 0

    func write(into rig: CueHostTests.Rig) async throws {
        let store = rig.store
        let site = try await store.createProject(name: "官网", color: "green")
        let siteFolder = rig.app.directory.appending(path: "site", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: siteFolder, withIntermediateDirectories: true)
        try await store.setDirectory(siteFolder.path, for: site.id)
        let demo = try #require(try await store.projects().first { $0.name == "演示" })

        var log: [Seeded] = []
        let calendar = Calendar(identifier: .gregorian)
        func at(_ day: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: .minute, value: 9 * 60 + minute, to: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -day, to: .now)!))!
        }
        // 日常来回：每天二十八轮，他的话、这一轮的经过、Cue 的回复、Cue 自己醒来的动态
        for day in stride(from: 14, through: 1, by: -1) {
            for turn in 0..<28 {
                let topic = DaysScript.routine[(day * 28 + turn) % DaysScript.routine.count]
                let minute = turn * 20
                log.append(Seeded(.you, topic.ask, at(day, minute)))
                log.append(Seeded(.round, "", at(day, minute) + 5, tools: [topic.step]))
                log.append(Seeded(.cue, topic.reply, at(day, minute) + 40))
                log.append(Seeded(.note, topic.note, at(day, minute + 12)))
            }
        }
        // 埋的事实
        log.append(Seeded(.you, "顺便说一句，我女儿 11 月 18 号钢琴考级，那天我请一天假。", at(13, 7 * 60 + 3)))
        log.append(Seeded(.cue, "好的，祝考级顺利。", at(13, 7 * 60 + 4)))
        log.append(Seeded(.cue, "图片存储我打算迁到 S3：生命周期规则和 CloudFront 都现成，压缩做完一起迁。你点头我就让会话准备。", at(5, 5 * 60)))
        log.append(Seeded(.you, "不用 S3，太贵，而且团队没人熟 AWS，就继续用 R2。", at(5, 5 * 60 + 6)))
        log.append(Seeded(.cue, "好，图片存储留在 R2，不迁 S3。", at(5, 5 * 60 + 7)))
        log.append(Seeded(.you, "官网十月周报那件，数据出来告诉我访问量。", at(2, 6 * 60)))
        log.append(Seeded(.cue, "好，周报数据一出来我就告诉你访问量。", at(2, 6 * 60 + 1)))
        log.append(Seeded(.you, "提交信息以后改用中文写吧，英文的大家看着费劲。", at(1, 4 * 60)))
        log.append(Seeded(.cue, "好，以后让会话的提交信息都用中文写。", at(1, 4 * 60 + 1)))
        try await store.seed(log.sorted { $0.at < $1.at })
        logged = log.count

        // 记忆：先是一直记着的（含后来改掉的那条旧偏好），再是日常学到的，最后是 1 天前改的新偏好；共 94 行、6 行一直记着
        let pins = ["改数据库结构前先问我", "推送到远端前先问我", "提交信息用英文写", "界面方案先给几个让我在卡上选", "回复用中文、一两句", "官网的改动不要碰 blog 子目录"]
        // 序号按写下的先后：同一毫秒写下的按 id 排，所以一条一条隔开写
        let lines = pins.map { ($0, true) } + (0..<87).map { (DaysScript.learned[$0 % DaysScript.learned.count] + "（\($0 + 1)）", false) }
            + [("他 10/20 说：提交信息以后改用中文写", false)]
        for (line, pin) in lines {
            _ = try await store.noteCueLine(line, source: .cue, pinned: pin)
            await quietPeriod(.milliseconds(3))
        }
        memoryLines = pins.count + 88
        pinned = pins.count

        // 做完的任务（会话回复里带细节）
        for (index, task) in DaysScript.done.enumerated() {
            try await doneTask(task.title, task.body, task.reply, day: task.day, project: demo.id, store: store, at: at, index: index)
        }
        doneTasks = DaysScript.done.count

        // 在做的两件：图片存储（5 天前开工）、官网十月周报（2 天前开工），会话在干活
        storage = try await working(
            "优化图片存储", "上传的图片压缩成 WebP、按宽度出三档；存储留在 R2。", rig: rig, project: demo.id, folder: rig.folder,
            replies: [("接口与转码好了，在补存量图片的批处理。", at(4, 3 * 60))], started: at(5, 5 * 60 + 10))
        weekly = try await working(
            "整理官网十月周报", "从统计后台导出十月的访问量、来源与转化，整理成周报。", rig: rig, project: site.id, folder: siteFolder,
            replies: [("统计后台的导出接口在排队，数据要明天才出得来。", at(1, 2 * 60))], started: at(2, 6 * 60 + 5))
    }

    private func doneTask(
        _ title: String, _ body: String, _ reply: String, day: Int, project: UUID, store: CueStore, at: (Int, Int) -> Date, index: Int
    ) async throws {
        let first = "\(title)\n\(body)", id = "done-\(index)", delivery = UUID()
        let task = try await store.createTask(first, in: project)
        try await store.recordSend(first, to: SendTarget(kind: .piSession, name: title, ref: id), card: task.id, delivery: delivery, origin: .known(.cue))
        let prompt = PiChatMessage(sessionID: id, entryID: "u1", seq: 1, role: .user, text: first, at: at(day, 60), deliveryID: delivery)
        let answer = PiChatMessage(sessionID: id, entryID: "a1", seq: 2, role: .pi, text: reply, at: at(day, 180))
        try await store.writePiTranscript(PiTranscript(sessionID: id, messages: [prompt, answer], recap: PiRecap(lastPrompt: title, lastReply: reply, answeredAt: at(day, 180))))
        try await store.setStatus(task.id, .done)
    }

    private func working(
        _ title: String, _ body: String, rig: CueHostTests.Rig, project: UUID, folder: URL, replies: [(String, Date)], started: Date
    ) async throws -> ScriptedSession {
        let first = "\(title)\n\(body)", id = "s-\(UUID().uuidString.prefix(8).lowercased())", delivery = UUID()
        let task = try await rig.store.createTask(first, in: project)
        try await rig.store.recordSend(first, to: SendTarget(kind: .piSession, name: title, ref: id), card: task.id, delivery: delivery, origin: .known(.cue))
        let fake = try await rig.app.host.connect(id, cwd: folder.path, busy: true)
        fake.sendInfo(["name": title])
        var history = [PiChatMessage(sessionID: id, entryID: "e1", seq: 1, role: .user, text: first, at: started, deliveryID: delivery)]
        for (text, at) in replies {
            history.append(PiChatMessage(sessionID: id, entryID: "e\(history.count + 1)", seq: Int64(history.count + 1), role: .pi, text: text, at: at))
            history.append(PiChatMessage(sessionID: id, entryID: "e\(history.count + 1)", seq: Int64(history.count + 1), role: .user, text: "继续", at: at + 60))
        }
        try await rig.store.writePiTranscript(PiTranscript(sessionID: id, messages: history, recap: PiRecap(pendingPrompt: "继续")))
        try await eventually("\(title) 在干活写进库") { try await rig.store.sessions(matching: id).first?.state.isWorking == true }
        return ScriptedSession(session: fake, task: task, history: history)
    }
}

/// 预置的一条对话：谁、写什么、在什么时刻；他的话记成当时就交给了 Cue。
nonisolated struct Seeded: Sendable {
    let author: CueAuthor
    let text: String
    let at: Date
    var tools: [PiChatMessage.Tools.Item] = []

    init(_ author: CueAuthor, _ text: String, _ at: Date, tools: [PiChatMessage.Tools.Item] = []) {
        (self.author, self.text, self.at, self.tools) = (author, text, at, tools)
    }
}

extension CueStore {
    /// 预置历史：按给的时刻写对话（一轮的经过带清单），他的话标成当时已交给 Cue。只给评测用：正式路径只写此刻。
    func seed(_ log: [Seeded]) throws {
        try write {
            for entry in log {
                let tools = entry.tools.isEmpty ? nil : PiChatMessage.Tools(steps: entry.tools.count, items: entry.tools)
                let message = try insertCueMessage(entry.author, text: entry.text, tools: tools, at: entry.at)
                if entry.author == .you { try db.run("UPDATE cueMessages SET deliveredAt = ? WHERE id = ?", [entry.at, message.id]) }
            }
        }
    }
}

/// 预置历史与会话交回的文字。
enum DaysScript {
    /// 多日后段补记的记忆（Cue 记下的），让视图超出预算、有块待合并；第一条是后面要问的车位
    static let notedLater = [
        "他的车停在公司地库 B2 层 117 号车位", "官网的 CDN 是 Cloudflare，缓存规则在 Page Rules 里", "演示项目的预发环境每晚 2 点自动重置数据",
        "他周五下午一般不开会", "看板的拖拽在 Safari 15 上有已知闪烁", "设计组的图标库 v2 月底出", "演示项目的数据库每周日凌晨全量备份",
        "R2 的桶叫 demo-uploads", "官网首页的首图在 public/images", "他的时区是东八区",
    ]

    struct Routine {
        let ask: String, reply: String, note: String
        let step: PiChatMessage.Tools.Item
    }

    /// 日常来回的几种：换着用，凑出两周的量
    static let routine: [Routine] = ([
        ("看下 CI 现在绿不绿", "CI 绿的，最近 20 次构建都过了。", "CI：例行看过，全绿", "CI 构建记录"),
        ("依赖更新的那几个 PR 合了吗", "合了三个，剩一个等测试补完。", "依赖更新：合了 3 个 PR", "依赖更新 PR"),
        ("登录页那个小 bug 修了没", "修了，会话补了测试，已经 done。", "登录页 bug：做完", "登录页 bug"),
        ("看板拖拽卡顿的事有进展吗", "会话定位到重复渲染，正在改。", "看板拖拽：在改重复渲染", "看板拖拽卡顿"),
        ("官网首页文案改好了吗", "改好了，截图发你手机了。", "官网文案：做完", "官网首页文案"),
        ("帮我看看昨晚的报错", "是第三方统计脚本超时，不影响主流程，已让会话加超时降级。", "报错：统计脚本超时，加降级", "昨晚的报错"),
        ("设置页的反馈整理一下", "整理好了，按主题分了五类，放在任务里。", "设置页反馈：整理完", "设置页反馈"),
        ("数据库备份正常吗", "正常，最近 7 天每天都成功，最大一次 3.1 GB。", "备份：例行看过，正常", "数据库备份"),
        ("README 里的安装步骤过时了吗", "过时了两步，已让会话更新。", "README：更新安装步骤", "README 安装步骤"),
        ("这周的发版准备好了吗", "准备好了，等你点头推送。", "发版：等他允许推送", "这周发版"),
        ("移动端的字号再调大一点", "已让会话把正文从 15 调到 16，截图稍后发你。", "移动端字号：在改", "移动端字号"),
        ("搜索变慢是怎么回事", "索引没覆盖新加的字段，会话加了索引，查询从 1.2 秒降到 80 毫秒。", "搜索：加索引，变快", "搜索变慢"),
        ("给通知中心加个全部已读", "加好了，测试过了，已 done。", "通知中心：全部已读做完", "通知中心全部已读"),
        ("把日志保留期改成 30 天", "改了，旧日志下次清理时按新规则删。", "日志保留期：改成 30 天", "日志保留期"),
    ] as [(String, String, String, String)]).map { Routine(ask: $0.0, reply: $0.1, note: $0.2, step: PiChatMessage.Tools.Item(kind: .talk, target: "\($0.3)：让会话跟进")) }

    /// 日常学到的记忆（不 pin）
    static let learned = [
        "演示项目的测试用 vitest，跑全量约 40 秒", "官网用 Astro，部署在 Cloudflare Pages", "CI 跑在自建 runner 上，周末偶尔排队",
        "他早上九点前不看手机", "演示项目的数据库是 Postgres 15", "看板拖拽用的是 dnd-kit", "官网的统计用的是自建的 Plausible",
        "发版通常在周四下午", "设置页的埋点在 analytics/settings-usage.csv", "移动端用 390 宽截图验收",
    ]

    /// 做完的任务：标题、正文、会话的交回、几天前
    static let done: [(title: String, body: String, reply: String, day: Int)] = [
        ("查清 CI 变慢", "最近 CI 从 6 分钟涨到 14 分钟，查清原因。", ciReport, 9),
        ("修好登录页白屏", "Safari 上偶发白屏，查清并修掉。", "修好了：Safari 15 不支持 structuredClone，换成手写深拷贝；补了 3 个测试，全过。", 12),
        ("通知中心加全部已读", "通知中心加一个全部已读按钮。", "加好了：按钮在右上角，接口一次标记全部；测试 8 个全过，截图发到手机了。", 8),
        ("搜索加索引", "搜索变慢，查原因并修。", "索引没覆盖 tags 字段；加了 GIN 索引，查询中位从 1.2 秒降到 80 毫秒。", 6),
        ("更新 README 安装步骤", "README 的安装步骤过时了，更新。", "更新了两步：Node 版本要求改成 20，去掉了已经不用的 yarn 步骤。", 4),
    ]

    static let ciReport = """
        查清楚了：CI 从 6 分钟涨到 14 分钟，主要是依赖缓存失效。

        1. 缓存键用的是 package-lock.json 的哈希，但 10/8 起 lockfile 每次构建都被 npm 重写（npm 版本升级后会改写 lockfileVersion），缓存每次都不命中，npm ci 从 40 秒涨到 6 分半。
        2. e2e 并发从 4 降到了 2（有人为排查不稳定的用例临时改的，忘了改回），又多出 2 分钟。

        改法：缓存键改成 lockfile 内容去掉 lockfileVersion 后的哈希；e2e 并发改回 4。改完三次构建分别是 6 分 10 秒、5 分 58 秒、6 分 05 秒。

        顺带记一下环境：runner 用的镜像是 node:20.11.1-bookworm，缓存目录挂在 /mnt/ci-cache，磁盘还剩 61%。
        """

    static let weeklyShot = [
        "访问量 48,210（环比 +12%）  独立访客 31,870", "来源：搜索 46%  直接 29%  社交 17%  其他 8%", "注册 1,204（转化 2.5%）", "最忙：10/15  3,980 次访问",
    ]

    static let weekly = """
        官网十月周报整理好了。统计后台的导出接口今天早上放出来了，数据是刚导出的：

        - 10 月访问量 48,210（环比 +12%），独立访客 31,870
        - 来源：搜索 46%、直接访问 29%、社交 17%、其他 8%
        - 转化：注册 1,204（2.5%），比 9 月高 0.3 个百分点
        - 最忙的一天是 10/15（活动预热），单日 3,980 次访问

        原始数据（Plausible 导出，reports/raw/2026-10-visits.csv 前几行）：
        ```
        date,visits,visitors,source_search,source_direct,source_social,signups
        2026-10-01,1402,951,644,410,236,39
        2026-10-02,1388,940,640,401,239,37
        2026-10-15,3980,2711,1790,1150,690,112
        ...
        合计,48210,31870,22177,13981,8196,1204
        ```
        周报的总览图发到手机了，PDF 在 reports/2026-10.pdf。
        """
}
#endif
