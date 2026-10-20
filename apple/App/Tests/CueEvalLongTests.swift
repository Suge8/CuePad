#if os(macOS)
import AppKit
import CuePi
import CueStore
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 长程值班：Cue 值一段班，被叫醒二十多次（他的话、会话歇下带长回复、会话提问、出错），回复撑大上下文，现做法至少跨一次换新线。
/// 中后段的判定点只有记得前面才答得对：他口头交代、没让记成规矩的细节，早先会话交回的事实，正在推进的事不重做不丢，他否掉的方案不再提。
/// 只经库与假会话驱动、只读库与工具调用判定，不碰哪种上下文做法独有的内部状态（换新次数数库里的交接备忘）。跑法见 docs/verify.md「Cue 评测」。
@Suite(.enabled(if: evalEnvironment["CUEPAD_CUE_EVAL"] == "1", "CUEPAD_CUE_EVAL=1 才跑"), .timeLimit(.minutes(60)))
struct CueEvalLongTests {
    /// 同时跑几遍（`CUEPAD_CUE_EVAL_RUNS`，缺省 1）：多遍时第 n 遍写到"输出目录-n"
    nonisolated static let runs = max(1, Int(evalEnvironment["CUEPAD_CUE_EVAL_RUNS"] ?? "") ?? 1)

    @Test(arguments: 1...runs) func 长程值班(_ run: Int) async throws {
        let output = Self.runs == 1 ? evalOutput : URL(filePath: evalOutput.path + "-\(run)", directoryHint: .isDirectory)
        try await CueEval.run("长程", expect: Duty.expect, output: output) { try await Duty($0).play() }
    }
}

/// 一段值班的剧本与判定。
@MainActor
private final class Duty {
    static let expect = """
        值一段班（三十来次醒来）：中后段记得他口头交代的（这件做完后升版本号记 CHANGELOG、这周不跑 e2e）、早先会话查清的事实（发信走 Postmark）、\
        他否掉的方案（设置页不分标签页）；换新前后在做的事不重建、不重复说
        """

    private let eval: CueEval
    private var rig: CueHostTests.Rig { eval.rig }
    private var sessions: [ScriptedSession] = []
    private var steps: [Step] = []
    /// 剧本没按预想走的地方（Cue 没开工评测替它开、没叫醒）
    private var notes: [String] = []

    /// 剧本的一步：叫醒的事、这次醒来的时段（没叫醒为 nil）、事出在哪个会话
    struct Step {
        let label: String
        let window: ClosedRange<Date>?
        let session: ScriptedSession?
    }

    init(_ eval: CueEval) { self.eval = eval }

    func play() async throws -> [Check] {
        do {
            let checks = try await script()
            await summarize()
            return checks
        } catch {
            await summarize()
            throw error
        }
    }

    private func script() async throws -> [Check] {
        let site = try await rig.store.createProject(name: "官网", color: "green")
        let siteFolder = rig.app.directory.appending(path: "site", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: siteFolder, withIntermediateDirectories: true)
        try await rig.store.setDirectory(siteFolder.path, for: site.id)

        // 前段：派活、口头交代、早先的事实、他否掉的方案；长回复与长消息把上下文撑过换新线
        let reset = try await say("他：登录页加忘记密码", CueEvalTests.request)
        let login = try await adopt(/忘记密码|重置密码/, after: reset, title: "登录页加忘记密码", in: "演示")
        try await say("他：做完后升版本号（口头、不记规矩）", "对了，忘记密码那件做完以后，让它顺手把演示项目的版本号从 2.3.0 升到 2.3.1，CHANGELOG 里记一笔。就这一次，不用记成规矩。")
        try await say("他：贴站会纪要（长）", Script.standup)
        let mailAsk = try await say("他：查邮件服务", "演示项目现在发邮件用的是哪家服务、这个月额度还剩多少？找个会话查清楚。")
        let mail = try await adopt(/邮件|发信|额度/, after: mailAsk, title: "查清邮件服务与额度", in: "演示")
        try await event("忘记密码：问令牌存哪", on: login) {
            try await login.ask(
                said: "开始做重置令牌的存储。项目里 Postgres 和 Redis 都在用。",
                question: "重置令牌存哪里？\nA. 新建 password_resets 表（存令牌哈希、过期时间、是否已用）\nB. 存进 Redis，TTL 30 分钟，用过即删",
                options: ["A", "B"], rig: rig)
        }
        try await event("邮件服务：交回调研（长）", on: mail) { try await mail.settle(Script.mailReport, rig: rig) }
        let depsAsk = try await say("他：出依赖升级清单", "演示项目的依赖好久没升了，让会话出一份升级清单：哪些该升、风险多大。先别动手升。")
        let deps = try await adopt(/依赖|升级/, after: depsAsk, title: "出依赖升级清单", in: "演示")
        try await event("依赖：交回清单（长）", on: deps) { try await deps.settle(Script.depsReport, rig: rig) }
        try await say("他：设置页重新设计（带反馈，长）", "演示项目的设置页太乱了，重新设计一下。下面是客服整理的用户反馈，转给会话参考：\n\n" + Script.feedback)
        let go = try await say("他：开工、不要标签页", "可以，按你说的开工。别做成分标签页那种，我不喜欢点来点去，就一页长列表、分组加小标题。")
        let settings = try await adopt(/设置/, after: go, title: "重新设计设置页", in: "演示")
        try await say("他：这周不跑 e2e（口头）", "这周 e2e 环境坏了，这周派出去的活都别跑 e2e，单元测试和 lint 过了就行。")
        try await event("忘记密码：API 500", on: login) {
            try await login.fail(#"500 {"type":"error","error":{"type":"api_error","message":"Internal server error"}}"#, rig: rig)
        }
        try await event("设置页：交回分组清单（长）", on: settings) { try await settings.settle(Script.settingsInventory, rig: rig) }
        try await say("他：依赖先升第一档", "依赖那件先把第一档升了，别的等等。")
        try await event("依赖：第一档升完（长）", on: deps) { try await deps.settle(Script.depsTier1, rig: rig) }
        try await say("他：问 TS 那 14 处", "依赖清单里说 TypeScript 升级会报 14 处错，让它在临时分支上试一下，列出具体是哪些，先别修。")
        try await event("依赖：列出 14 处报错（长）", on: deps) { try await deps.settle(Script.tsErrors, rig: rig) }
        let speed = try await say("他：官网 Lighthouse 掉分", "官网首页的 Lighthouse 性能分掉到 60 多了，查一下原因修掉。")
        let website = try await adopt(/Lighthouse|性能|首页/, after: speed, title: "修回官网首页性能分", in: "官网")
        try await event("官网：交回分析（长）", on: website) { try await website.settle(Script.lighthouseAnalysis, rig: rig) }
        try await say("他：转来安全扫描报告（长）", Script.securityScan)
        try await event("忘记密码：后端做完（长）", on: login) { try await login.settle(Script.backendDone, rig: rig) }
        let progress = try await say("他：问登录页进展", "登录页那件做到哪了？")
        try await event("设置页：布局改完一版（长）", on: settings) { try await settings.settle(Script.layoutDone, rig: rig) }
        try await event("忘记密码：前端做了一半（长）", on: login) { try await login.settle(Script.frontendHalf, rig: rig) }

        // 中后段：判定点（放在换新线之后）
        let readmeAsk = try await say("他：README 截图重截", "演示项目 README 里的截图过时了，现在就让会话按现在的界面重截一遍换上；登录页和设置页改完后的样子以后再补。")
        let readme = try await adopt(/README/, after: readmeAsk, title: "重截 README 截图", in: "演示")
        try await event("README：问截图放哪", on: readme) {
            try await readme.ask(
                said: "README 用到的 9 张截图都按现在的界面重截好了。旧图在 docs/images/ 和 assets/readme/ 两处都有：README 引用的是 docs/images/，assets/readme/ 里是没人引用的旧副本。",
                question: "新截图放哪？", options: ["docs/images/", "assets/readme/"], rig: rig)
        }
        let digestAsk = try await say("他：加每周周报邮件", "演示项目再加一个：每周一早上 9 点给上周活跃过的用户发一封周报邮件，列出他看板上上周新建、完成的任务数和最忙的一天。")
        let digest = try await adopt(/周报/, after: digestAsk, title: "加每周周报邮件", in: "演示")
        let readmeStatus = try await say("他：问 README 那件", "README 那件开工了吗？做到哪了？")
        let provider = try await event("周报邮件：问走哪家发信", on: digest) {
            try await digest.ask(
                said: "周报邮件的模板写好了（沿用注册验证邮件的样式），统计查询和每周一 9 点的定时任务也接好了。",
                question: "项目里同时有 SendGrid 和 Postmark 两套发信配置（config/mail.sendgrid.ts、config/mail.postmark.ts），周报邮件走哪个？",
                options: ["SendGrid", "Postmark"], rig: rig)
        }
        let tabs = try await event("设置页：问要不要拆标签页", on: settings) {
            try await settings.ask(
                said: "分组的长列表在手机上有 3 屏半长，\"高级\"组在最底下要滑一阵才到。",
                question: "设置项太多、页面太长，要不要拆成「通用 / 账号 / 通知」三个标签页？", options: ["拆成标签页", "保持一页长列表"], rig: rig)
        }
        let e2e = try await event("官网：问跑不跑 e2e", on: website) {
            try await website.ask(
                said: "首页改好了：hero 图换成 AVIF 并按屏宽出图，字体改成 font-display: swap 并预加载，客服挂件改成点了才加载。本地 Lighthouse 移动端性能 63 → 92，单元测试 31 个全过，lint 干净。",
                question: "要不要再跑一遍 e2e 回归（Playwright，约 25 分钟）再交？", options: ["跑 e2e 回归", "只跑单元测试就交"], rig: rig)
        }
        try await event("README：做完交回", on: readme) {
            try await readme.deliver(pageShot("README 截图（新）", Script.readmeShots), title: "README 新截图", rig: rig)
            try await readme.settle(Script.readmeDone, rig: rig)
        }
        let finish = try await event("忘记密码：做完交回", on: login) {
            try await login.deliver(loginShot(), title: "登录页 忘记密码 改前改后", rig: rig)
            try await login.settle(CueEvalTests.doneReply, rig: rig)
        }
        try await event("官网：做完交回", on: website) {
            try await website.deliver(pageShot("Lighthouse 移动端 · 首页", Script.lighthouseShot), title: "首页 Lighthouse 改前改后", rig: rig)
            try await website.settle(Script.lighthouseDone, rig: rig)
        }
        let wrap = try await say("他：问今天的事", "今天这些事现在都怎么样了？")

        return try await judge(login: login, settings: settings, site: website, digest: digest, steps: (
            progress: progress, tabs: tabs, e2e: e2e, readmeStatus: readmeStatus, provider: provider, finish: finish, wrap: wrap, go: go))
    }

    // MARK: 判定

    private func judge(
        login: ScriptedSession, settings: ScriptedSession, site: ScriptedSession, digest: ScriptedSession,
        steps key: (progress: Step, tabs: Step, e2e: Step, readmeStatus: Step, provider: Step, finish: Step, wrap: Step, go: Step)
    ) async throws -> [Check] {
        for session in sessions { try await session.refresh(rig) }
        let adds = CueEval.calls(in: rounds(after: steps.first!), "task", ["add"]).filter { !$0.call.failed }
        let topics: [(String, Regex<Substring>)] = [
            ("忘记密码", /忘记密码|重置密码/), ("邮件服务", /服务|额度|哪家/), ("设置页", /设置页/), ("官网性能", /Lighthouse|性能/),
            ("README", /README/), ("依赖", /依赖/), ("周报", /周报/),
        ]
        let duplicated = topics.filter { _, topic in adds.count { ($0.args["title"] as? String)?.contains(topic) == true } > 1 }.map(\.0)
        let readmeAdds = adds.count { ($0.args["title"] as? String)?.contains(/README/) == true }
        let repeated = sessions.filter { session in
            let said = says(steps, to: session)
            return said.indices.contains { i in said[(i + 1)...].contains { Self.similar($0, said[i]) } }
        }
        let unhandled = steps.filter { step in
            guard let session = step.session else { return false }
            return !calls(step, "task").contains { !$0.call.failed && target($0.args) === session } && calls(step, "tell").isEmpty
        }
        let afterRejection = try await eval.said(since: key.go.window?.upperBound ?? .distantFuture).map(\.text)
            + says(steps.filter { ($0.window?.lowerBound ?? .distantPast) > (key.go.window?.upperBound ?? .distantFuture) }, to: settings)
        let tabsSaid = says([key.tabs], to: settings), e2eSaid = says([key.e2e], to: site), providerSaid = says([key.provider], to: digest)
        // 升版本号：收尾时交代（say、edit、add，或开工写着它的步骤），或还排在这件事没做完的步骤里（Cue 早先把它加成了步骤）
        let bump = /2\.3\.1|CHANGELOG|changelog/
        let started = CueEval.calls(in: rounds(key.finish), "task", ["start"]).compactMap { call in
            login.cards.first { card in (call.args["task"] as? String).map { card.id.uuidString.lowercased().hasPrefix($0.lowercased()) } == true }?.body
        }
        let wrapUp = CueEval.calls(in: rounds(key.finish), "task", ["say", "edit", "add"]).map { Self.texts($0.args) } + started
        let planned = try await rig.store.cueTaskDetail(login.task.id).leaves.contains { $0.leaf.status != .done && $0.leaf.body.contains(bump) }
        return [
            Check("(a) 他口头交代的升 2.3.1、记 CHANGELOG：收尾时交代了，或还排在这件事的步骤里", wrapUp.contains { $0.contains(bump) } || planned),
            Check("(a) 他口头交代的：官网问跑不跑 e2e，答只跑单元测试", e2eSaid.contains { $0.contains(/单元|只跑|不跑|别跑/) } && !e2eSaid.contains { $0.contains("跑 e2e 回归") || $0 == "1" }),
            Check("(b) 早先会话查清的：周报邮件问走哪家发信，答 Postmark", providerSaid.contains { $0.localizedCaseInsensitiveContains("Postmark") } && !providerSaid.contains { $0 == "SendGrid" || $0 == "1" }),
            Check("(c) README 只建了一个任务（问进展时没另建）", readmeAdds == 1 && calls(key.readmeStatus, "task", ["add", "start"]).isEmpty),
            Check("(c) 每件事只建一个任务" + (duplicated.isEmpty ? "" : "（重复：\(duplicated.joined(separator: "、"))）"), duplicated.isEmpty),
            Check("(c) 没对同一个会话把同一件事说两遍" + (repeated.isEmpty ? "" : "（\(repeated.map(\.title).joined(separator: "、"))）"), repeated.isEmpty),
            Check("(c) 会话的每次动静都有接手" + (unhandled.isEmpty ? "" : "（没接：\(unhandled.map(\.label).joined(separator: "、"))）"), unhandled.isEmpty),
            Check("(d) 设置页问拆不拆标签页：按他说的保持一页，不留给他、不问他",
                  tabsSaid.contains { $0.contains(/一页|不拆|保持|不分|别拆|不要/) } && !tabsSaid.contains { $0 == "拆成标签页" || $0 == "1" }
                    && calls(key.tabs, "tell").allSatisfy { $0.args["ask"] == nil }),
            Check("(d) 他否掉之后没再提分标签页", !afterRejection.contains(where: Self.proposesTabs)),
            Check("问登录页进展：答了进展、没派新活", try await reply(key.progress)?.contains(/后端|前端|测试|接口/) == true && calls(key.progress, "task", ["add", "start"]).isEmpty),
            Check("问今天的事：回了他、没派新活", try await reply(key.wrap) != nil && calls(key.wrap, "task", ["add", "start"]).isEmpty),
        ]
    }

    // MARK: 剧本的动作

    /// 他对 Cue 说一句，等 Cue 做完这次醒来引起的。
    @discardableResult
    private func say(_ label: String, _ text: String) async throws -> Step {
        try await step(label, on: nil) { try await self.rig.say(text) }
    }

    /// 会话有动静，等 Cue 做完这次醒来引起的。
    @discardableResult
    private func event(_ label: String, on session: ScriptedSession, _ act: () async throws -> Void) async throws -> Step {
        try await step(label, on: session, act)
    }

    private func step(_ label: String, on session: ScriptedSession?, _ act: () async throws -> Void) async throws -> Step {
        let window = try await eval.settle(act)
        if window == nil { notes.append("「\(label)」没叫醒 Cue") }
        let step = Step(label: label, window: window, session: session)
        steps.append(step)
        return step
    }

    /// 他交代的事开出的会话：Cue 开工时执行器开出假扩展（new-<令牌>），开场白的发送记录把任务绑上它。
    /// Cue 这一步没开工（先对齐、没建）就由评测替它开，记一笔：后面的剧本要有这个会话。
    private func adopt(_ topic: Regex<Substring>, after step: Step, title: String, in projectName: String) async throws -> ScriptedSession {
        let started = calls(step, "task", ["start"]).contains { !$0.call.failed }
        var found: ScriptedSession?
        try? await eventually("Cue 开出的会话绑上任务", timeout: started ? .seconds(60) : .zero) {
            found = try await self.opened(topic)
            return found != nil
        }
        if let found {
            sessions.append(found)
            return found
        }
        notes.append("「\(title)」Cue 没开工，评测替它开了会话")
        let project = try #require(try await rig.store.projects().first { $0.name == projectName })
        var card = try await rig.store.cueBoard().tasks.map(\.task).last { task in step.window.map { $0.contains(task.createdAt) } == true && task.body.contains(topic) }
        if card == nil { card = try await rig.store.createTask("\(title)\n照他的话做，做完把证据发到手机。", in: project.id) }
        let task = try #require(card)
        let folder = try #require(try await rig.store.directory(of: project.id))
        let id = "s-\(UUID().uuidString.prefix(8).lowercased())", delivery = UUID()
        try await rig.store.recordSend(task.body, to: SendTarget(kind: .piSession, name: task.heading, ref: id), card: task.id, delivery: delivery, origin: .known(.cue))
        let fake = try await rig.app.host.connect(id, cwd: folder, busy: true)
        fake.sendInfo(["name": task.heading])
        let session = ScriptedSession(session: fake, task: task, opening: PiChatMessage(sessionID: id, entryID: "e1", seq: 1, role: .user, text: task.body, at: .now, deliveryID: delivery))
        sessions.append(session)
        return session
    }

    private func opened(_ topic: Regex<Substring>) async throws -> ScriptedSession? {
        let extensions = rig.app.host.extensions
        for (id, fake) in extensions where id.hasPrefix("new-") && !sessions.contains(where: { $0.id == id }) {
            guard let leaf = try await rig.store.tasks(boundTo: id).first else { continue }
            let top = leaf.parent ?? leaf.task
            guard "\(top.body)\n\(leaf.task.body)".contains(topic) else { continue }
            fake.setState(["kind": "thinking"])  // 开场白在接手前就到了：像真会话那样在干活
            return ScriptedSession(session: fake, task: top, opening: nil)
        }
        return nil
    }

    // MARK: 读这几步里的事

    private func rounds(_ step: Step) -> [CueRound] {
        guard let window = step.window else { return [] }
        return eval.rounds.filter { window.contains($0.startedAt) }
    }

    private func rounds(after step: Step) -> [CueRound] {
        guard let from = step.window?.lowerBound else { return [] }
        return eval.rounds.filter { $0.startedAt >= from }
    }

    private func calls(_ step: Step, _ tool: String, _ actions: Set<String> = []) -> [(call: CueToolCall, args: [String: Any])] {
        CueEval.calls(in: rounds(step), tool, actions)
    }

    /// 这几步里成功对 `session` 说的话（say 的 text）
    private func says(_ steps: [Step], to session: ScriptedSession) -> [String] {
        steps.flatMap { calls($0, "task", ["say"]) }.filter { !$0.call.failed && target($0.args) === session }.compactMap { $0.args["text"] as? String }
    }

    /// 回答他的那句（这一步里）
    private func reply(_ step: Step) async throws -> String? {
        guard let window = step.window else { return nil }
        return try await eval.said(since: window.lowerBound).last { $0.author == .known(.cue) && $0.choices == nil && $0.taskID == nil && $0.createdAt <= window.upperBound }?.text
    }

    /// 工具参数里的 task（id 前缀或标题）或 session（id 前缀或会话名）指的是哪个会话
    private func target(_ args: [String: Any]) -> ScriptedSession? {
        if let ref = (args["task"] as? String)?.lowercased(), !ref.isEmpty {
            return sessions.first { $0.cards.contains { $0.id.uuidString.lowercased().hasPrefix(ref) || $0.heading.lowercased() == ref } }
        }
        if let ref = (args["session"] as? String)?.lowercased(), !ref.isEmpty {
            return sessions.first { $0.id.lowercased().hasPrefix(ref) || $0.title.lowercased() == ref }
        }
        return nil
    }

    private static func texts(_ args: [String: Any]) -> String {
        (["title", "body", "text"].compactMap { args[$0] as? String } + (args["steps"] as? [String] ?? [])).joined(separator: "\n")
    }

    /// 两句话几乎一样：去掉空白与标点后，相邻两字的集合重合八成以上
    private static func similar(_ a: String, _ b: String) -> Bool {
        func pairs(_ text: String) -> Set<String> {
            let characters = Array(text.filter { !$0.isWhitespace && !$0.isPunctuation })
            return Set(zip(characters, characters.dropFirst()).map { "\($0)\($1)" })
        }
        let x = pairs(a), y = pairs(b)
        guard !x.isEmpty, !y.isEmpty else { return a == b }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.8
    }

    /// 说到分标签页、又不是在否定它（前面几个字里没有不、别、没、无）；"按标签定位"这类说的是别的标签
    private static func proposesTabs(_ text: String) -> Bool {
        text.ranges(of: /标签页|页签|tab ?页|tabs/.ignoresCase()).contains { range in
            let from = text.index(range.lowerBound, offsetBy: -8, limitedBy: text.startIndex) ?? text.startIndex
            return !text[from..<range.lowerBound].contains(/不|别|没|无|免|否/)
        }
    }

    // MARK: 统计

    /// 写进 .md 的长程统计，与汇总行的两格
    func summarize() async {
        let rounds = eval.rounds.filter { $0.wake != .enabled }
        let durations = rounds.compactMap { round in round.finishedAt.map { $0.timeIntervalSince(round.startedAt) } }.sorted()
        let median = durations.isEmpty ? "—" : seconds(durations.count.isMultiple(of: 2)
            ? (durations[durations.count / 2 - 1] + durations[durations.count / 2]) / 2 : durations[durations.count / 2])
        let renewals = ((try? await rig.store.cueMessages(limit: 5000)) ?? []).count { $0.author == .known(.handoff) }
        let usage = rig.brainDirectory.map(BrainUsage.rounds(in:)) ?? []
        let total = usage.reduce(BrainUsage(), +)
        eval.overview = (rounds.reduce(0) { $0 + $1.calls.count }, "中位 \(median)")
        var lines = [
            "", "## 长程", "",
            "- 醒来 \(rounds.count) 次（不含预热；剧本叫醒 \(steps.count) 次），换新 \(renewals) 次（库里的交接备忘）",
            "- 每轮用时中位 \(median)",
            "- 合计（含预热，大脑报了 \(usage.count) 轮）：\(BrainUsage.header.replacingOccurrences(of: " | ", with: "、")) = \(total.cells.replacingOccurrences(of: " | ", with: "、"))",
        ]
        lines += notes.map { "- \($0)" }
        lines += ["", "| 步 | 叫醒的事 | 轮数 | 工具调用 |", "| --- | --- | --- | --- |"]
        for (index, step) in steps.enumerated() {
            let rounds = self.rounds(step)
            lines.append("| \(index + 1) | \(step.label) | \(rounds.count) | \(rounds.flatMap(\.calls).map(\.name).joined(separator: "、")) |")
        }
        eval.report = lines
    }
}

/// 剧本里的一个会话：假扩展扮演，对话按 Cue 真送进来的话（带投送 id，认作 Cue 说的）与剧本的回复累积，像 Mac 读会话文件那样写进库。
@MainActor
private final class ScriptedSession {
    let session: FakeExtension
    let task: Card
    var id: String { session.sessionID }
    /// 绑着这个会话的任务与步骤、会话名（判 say 给的是谁）；判定前 `refresh`
    private(set) var cards: [Card] = []
    private(set) var title = ""
    private var messages: [PiChatMessage] = []
    private var heard = 0

    init(session: FakeExtension, task: Card, opening: PiChatMessage?) {
        self.session = session
        self.task = task
        cards = [task]
        messages = opening.map { [$0] } ?? []
        // 像真扩展那样：收到话开始干活，作答后收起提问、接着干
        let ack = session.onCommand
        session.onCommand = { [weak session] connection, command in
            switch command["t"] as? String {
            case "send": session?.setState(["kind": "thinking"])
            case "answer":
                session?.sendInfo(["question": NSNull()])
                session?.setState(["kind": "thinking"])
            default: break
            }
            return ack(connection, command)
        }
    }

    func refresh(_ rig: CueHostTests.Rig) async throws {
        cards = [task] + (try await rig.store.tasks(boundTo: id)).flatMap { [$0.task] + ($0.parent.map { [$0] } ?? []) }
        title = try await rig.store.sessions(matching: id).first?.title ?? ""
    }

    /// 做完这一轮歇下，回复是 `reply`。
    func settle(_ reply: String, rig: CueHostTests.Rig) async throws {
        try await working(rig)
        append(.pi, reply)
        session.setState(["kind": "idle"])
        try await rig.answered(id, prompt: oneLine(lastPrompt), reply: reply, messages: messages)
    }

    /// 这一轮说了 `said` 后停下来问一个选择题。
    func ask(said: String, question: String, options: [String], rig: CueHostTests.Rig) async throws {
        try await working(rig)
        append(.pi, said)
        try await rig.store.writePiTranscript(PiTranscript(sessionID: id, messages: messages, recap: PiRecap(pendingPrompt: oneLine(lastPrompt))))
        session.sendInfo(["question": ["id": "q\(messages.count)", "kind": "select", "text": question, "options": options]])
        session.setState(["kind": "waiting_user", "title": question])
    }

    /// 这一轮出错停下。
    func fail(_ error: String, rig: CueHostTests.Rig) async throws {
        try await working(rig)
        session.setState(["kind": "error", "error": error])
    }

    /// 发一张图到手机。
    func deliver(_ png: Data, title: String, rig: CueHostTests.Rig) async throws {
        let file = rig.app.directory.appending(path: "\(title).png")
        try png.write(to: file)
        _ = try await rig.store.addPreviews(filesAt: [file], title: title, sessionID: id)
    }

    /// 收下 Cue 送进来的话（像会话文件那样记成带投送 id 的一条），在干活写进库。
    private func working(_ rig: CueHostTests.Rig) async throws {
        let commands = session.commands
        for command in commands.dropFirst(heard).map(\.json) where command["t"] as? String == "send" {
            append(.user, command["text"] as? String ?? "", delivery: (command["deliveryId"] as? String).flatMap(UUID.init(uuidString:)))
        }
        heard = commands.count
        session.setState(["kind": "thinking"])
        try await eventually("\(id) 在干活写进库") { try await rig.store.sessions(matching: self.id).first?.state.isWorking == true }
    }

    private var lastPrompt: String { messages.last { $0.role == .known(.user) }?.text ?? "" }

    private func append(_ role: PiChatRole, _ text: String, delivery: UUID? = nil) {
        let seq = Int64(messages.count + 1)
        messages.append(PiChatMessage(sessionID: id, entryID: "e\(seq)", seq: seq, role: role, text: text, at: .now, deliveryID: delivery))
    }
}

/// 一张写着字的页面截图（README 新截图、Lighthouse 报告）：Cue 用读文件工具打开看。
@MainActor
private func pageShot(_ title: String, _ lines: [String]) throws -> Data {
    let page = VStack(alignment: .leading, spacing: 10) {
        Text(title).font(.title2.bold())
        ForEach(lines, id: \.self) { Text($0).font(.body.monospaced()) }
    }
    .padding(24).frame(width: 640, alignment: .leading).background(.white).foregroundStyle(.black)
    let renderer = ImageRenderer(content: page)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
}

/// 会话的长回复：撑大 Cue 的上下文（peek 给最新回答全文），也藏着后面要用的事实。
private enum Script {
    static let mailReport = """
        查清楚了。结论：演示项目线上发信走的是 Postmark；SendGrid 那套是 2024 年迁移前留下的旧配置，已经不用了。这个月额度还剩 6,288 封，照现在的量月底前够用。

        ## 1. 用的是哪家

        - 发信入口在 src/mail/index.ts 的 `createTransport()`：读环境变量 `MAIL_PROVIDER` 选实现，`postmark` 走 config/mail.postmark.ts，`sendgrid` 走 config/mail.sendgrid.ts。
        - 生产环境（.env.production 与部署平台的环境变量）里是 `MAIL_PROVIDER=postmark`；预发环境也是 postmark；本地开发默认也是 postmark，只是 token 指向 Postmark 的沙盒 Server（demo-dev），邮件不会真发出去，在 Postmark 控制台的 Activity 里能看到。
        - config/mail.sendgrid.ts 现在只被 scripts/legacy-import.ts 引用，那个脚本最后一次改动是 2024-06-12（迁移到 Postmark 的那次提交 7c41e0a），之后没人跑过；SendGrid 的 API key 在 2024-07 已经吊销（SendGrid 控制台显示 revoked），就算有人把 MAIL_PROVIDER 改回 sendgrid 也发不出去，启动时会报 401。
        - 所以：新写的发信代码都应该走 Postmark；SendGrid 配置可以找时间删掉，但删除前要先问你。

        ```
        $ rg -n "MAIL_PROVIDER" --glob '!node_modules'
        src/mail/index.ts:14:  const provider = process.env.MAIL_PROVIDER ?? "postmark";
        .env.example:9:MAIL_PROVIDER=postmark
        deploy/production.env.tpl:22:MAIL_PROVIDER=postmark
        deploy/staging.env.tpl:22:MAIL_PROVIDER=postmark
        $ rg -ln "mail.sendgrid" --glob '!node_modules'
        scripts/legacy-import.ts
        $ git log -1 --format='%h %ad %s' --date=short -- scripts/legacy-import.ts
        7c41e0a 2024-06-12 迁移发信到 Postmark，SendGrid 只留给旧数据导入
        $ rg -n "sendMail\\(|transport\\.send\\(" src --glob '!**/*.test.ts' | wc -l
              17
        ```

        17 处调用发信的地方都经 `createTransport()`，没有绕过它直接调 SendGrid 或 Postmark SDK 的。

        ## 2. 账号与配置

        - Postmark 账号 ops@demo.dev，Server 名 demo-prod，发信域名 mail.demo.dev；DKIM 与 Return-Path 都已验证，SPF 记录里包含 spf.mtasv.net。
        - API token 在 1Password 的「demo-mail / Postmark server token」条目；CI 里对应的 secret 是 `POSTMARK_TOKEN`，部署平台里同名。
        - 消息流：事务邮件走 `outbound`，营销邮件走 `broadcast`（目前没在用）。注册验证邮件、重置密码邮件都属于事务邮件；以后要发周报、活动这类批量邮件，按 Postmark 的规矩要走 `broadcast` 流，不能混进 `outbound`，否则会影响事务邮件的送达率。
        - 模板：现有的邮件模板都在仓库里（templates/mail/*.mjml，构建时编译成 HTML），没有用 Postmark 自带的模板功能。

        ## 3. 额度

        - 套餐 Basic：每月 10,000 封，每月 1 号重置。
        - 10 月到今天已发 3,712 封，剩 6,288 封；最近 7 天日均约 180 封，照这个量到月底大约再发 2,000 封，够用。
        - 超出后要么限流，要么按 $1.30 / 千封计超额费：账单页的 overage 现在是关着的。按现在的量不会碰到，先记一笔。

        ```
        $ curl -s -H "X-Postmark-Server-Token: $POSTMARK_TOKEN" "https://api.postmarkapp.com/stats/outbound?fromdate=2026-10-01&todate=2026-10-20"
        {"Sent":3712,"Bounced":15,"SMTPApiErrors":0,"BounceRate":0.40,"SpamComplaints":0,"SpamComplaintsRate":0.00,"Tracked":0,"Opens":0}
        $ curl -s -H "X-Postmark-Server-Token: $POSTMARK_TOKEN" "https://api.postmarkapp.com/stats/outbound/sends?fromdate=2026-10-13&todate=2026-10-19"
        {"Days":[{"Date":"2026-10-13","Sent":172},{"Date":"2026-10-14","Sent":181},{"Date":"2026-10-15","Sent":190},{"Date":"2026-10-16","Sent":176},{"Date":"2026-10-17","Sent":185},{"Date":"2026-10-18","Sent":169},{"Date":"2026-10-19","Sent":187}],"Sent":1260}
        ```

        ## 4. 健康度

        - 退信率 0.40%、投诉率 0%，都在 Postmark 建议的范围内（退信 < 10%、投诉 < 0.1%）。
        - 15 封退信里 13 封是 hard bounce（邮箱不存在），都来自注册时手误的邮箱，已自动进 suppression 列表；另外 2 封是对方邮箱满了的 soft bounce。
        - 平均投递时间 1.8 秒，最近 30 天没有出现过发信接口报错。

        ## 5. 顺带发现的

        1. 新的发信代码只用 Postmark，别再碰 config/mail.sendgrid.ts。
        2. SendGrid 的旧配置与 scripts/legacy-import.ts 可以删，删之前先问你。
        3. .env.example 里还留着 SENDGRID_API_KEY 这一行，新同事照着配会以为两家都要配，建议跟着上面那条一起清掉。
        """

    static let settingsInventory = """
        先把现在的设置页摸了一遍，把分组结构定下来了，还没动界面。

        ## 现状

        设置页（src/pages/settings/SettingsPage.tsx，1,240 行）现在 46 项平铺在一个长表单里，顺序是按加功能的先后堆的：账号相关的散在第 3、17、29、40 项，通知开关散在 8 处，几个开发者选项夹在外观设置中间。搜索框只按标签全文匹配，搜"邮件"会同时出来通知邮件、登录邮箱、导出到邮箱三种不相干的东西。每一项的保存是各写各的：有 31 项改了立刻存，15 项要点页面最底下的"保存"，而那个按钮在手机上要滑 5 屏才看得到，用户反馈里有 23 条说"改了设置没生效"，基本都是这个原因。

        ## 46 项的归类

        | 组 | 项数 | 内容 |
        | --- | --- | --- |
        | 账号 | 8 | 头像、昵称、登录邮箱、手机号、修改密码、两步验证、已登录设备、注销账号 |
        | 通知 | 9 | 邮件通知总开关、评论、提及、关注、周报、产品更新、推送总开关、推送免打扰时段、声音 |
        | 外观 | 6 | 主题（浅/深/跟随系统）、强调色、字号、紧凑模式、侧栏位置、动画 |
        | 编辑器 | 7 | 默认格式、自动保存间隔、拼写检查、Markdown 快捷键、代码块主题、制表符宽度、自动补全 |
        | 隐私 | 6 | 资料可见范围、在线状态、已读回执、搜索引擎收录、数据收集、屏蔽列表 |
        | 数据 | 5 | 导出全部数据、导出到邮箱、导入、存储用量、清除缓存 |
        | 高级 | 5 | 开发者模式、API 令牌、Webhook、实验功能、重置所有设置 |

        ## 打算怎么排

        - 一页长列表，7 组按上面的顺序排，每组一个小标题，组内按使用频率排（埋点数据在 analytics/settings-usage.csv，近 30 天）。
        - 顶部的搜索改成按组过滤：搜到的项连同它的组标题一起显示；搜不到时提示"没有这一项，可能在账号中心里"，因为有 4 项（实名认证、发票、团队成员、付费方案）其实在账号中心，不在设置页。
        - 保存方式统一成改了立刻存，每项右边出一个小对勾表示存好了；底部的"保存"按钮去掉。要二次确认的只有危险操作。
        - 危险操作（注销账号、重置所有设置）挪到各组最底下，红字，点了要二次确认。
        - 改动只动布局与顺序，不改每一项的行为与存储的键名，老用户的设置不受影响。

        ## 使用频率（近 30 天，前 15）

        ```
        theme                 18,204
        notifications.email   11,930
        editor.autosave        9,415
        avatar                 7,866
        password               6,102
        font_size              5,877
        push.quiet_hours       4,310
        two_factor             3,955
        export.all             2,201
        devices                1,987
        editor.spellcheck      1,640
        accent_color           1,512
        privacy.profile        1,208
        push.enabled           1,155
        compact_mode             988
        ```

        后 10 项近 30 天加起来不到 200 次（Webhook、制表符宽度、侧栏位置、实验功能等），按组排进去即可，不单独处理。

        ## 风险

        - 有 3 个第三方插件通过 `#settings-editor-autosave` 这类锚点直接跳到某一项，改布局要保留这些锚点 id，我会在组件里照旧输出。
        - 设置页的 e2e 用例（tests/e2e/settings.spec.ts）按"第 n 个输入框"定位元素，改顺序后会全挂；这次按你说的不跑 e2e，但用例要顺手改成按标签定位，不然下周环境好了一跑就红。

        接下来改 SettingsPage 的布局：先拆出 SettingsGroup 组件，再把 46 项按上面的表挪进去。
        """

    static let lighthouseAnalysis = """
        查到原因了：性能分从 9 月底的 91 掉到现在的 63（移动端），主要是三处，都是最近两周上线的改动带进来的。

        ## Lighthouse（移动端，首页，本地 3 次取中位）

        ```
        Performance        63
        First Contentful Paint   2.9 s
        Largest Contentful Paint 5.8 s
        Total Blocking Time      620 ms
        Cumulative Layout Shift  0.21
        Speed Index              4.7 s
        ```

        桌面端是 88，掉得没那么多，所以之前没人注意到。线上 CrUX 数据（近 28 天真实用户）也印证了：移动端 LCP 的 75 分位从 2.1 s 涨到了 4.6 s，从"良好"掉进了"差"。

        ## 原因

        1. **Hero 图**（LCP 元素）：10 月 8 日换的新首图是 2.3 MB 的 PNG（3840×2160），所有屏宽都下这一张，没有 srcset，也没有 preload。LCP 5.8 s 里有 4.1 s 在等它。图本身是一张有大片纯色背景的插画，转成 AVIF 体积能降到原来的十分之一以下，肉眼看不出差别。
        2. **字体**：10 月 12 日引入的 Inter 可变字体（3 个字重，共 780 KB）用 @import 写在 CSS 里，阻塞渲染；`font-display` 没写，默认是 block，首屏文字要等字体到了才画，FCP 被拖到 2.9 s。字体换上时行高不同，引起 0.12 的 CLS。页面实际只用到了 400 和 600 两个字重，700 那份是白下的。
        3. **客服挂件**：10 月 15 日加的第三方客服挂件（widget.chatvendor.io）在 `<head>` 里同步加载 610 KB 的脚本，主线程长任务累计 540 ms，是 TBT 的大头；挂件的悬浮按钮晚出现，又贡献了 0.09 的 CLS。挂件的使用率很低：近两周 41,000 次首页访问里只有 86 次点开过它。

        ```
        $ npx lighthouse http://localhost:4173 --preset=perf --form-factor=mobile --output=json | jq '.audits["largest-contentful-paint-element"].details.items[0].items[0].node.snippet'
        "<img src=\\"/images/hero-2026.png\\" class=\\"hero__image\\" alt=\\"\\">"
        $ ls -la public/images/hero-2026.png
        -rw-r--r--  1 dev  staff  2412876 Oct  8 10:21 public/images/hero-2026.png
        $ npx lighthouse ... | jq '.audits["render-blocking-resources"].details.items[] | {url, wastedMs}'
        {"url":"https://fonts.example-cdn.com/inter-var.css","wastedMs":1180}
        {"url":"https://widget.chatvendor.io/v3/loader.js","wastedMs":760}
        $ npx lighthouse ... | jq '.audits["bootup-time"].details.items[0:3][] | {url, scripting}'
        {"url":"https://widget.chatvendor.io/v3/loader.js","scripting":541.2}
        {"url":"http://localhost:4173/assets/index-8f2c1.js","scripting":212.7}
        {"url":"Unattributable","scripting":61.3}
        $ git log --since=2026-09-25 --format='%h %ad %s' --date=short -- public/images src/styles index.html
        b81d3e2 2026-10-15 首页接入客服挂件
        4a09c7f 2026-10-12 换成 Inter 可变字体
        e17f5aa 2026-10-08 更新首页首图
        ```

        ## 不是原因的（排除过）

        - 打包体积：主包 index-8f2c1.js 186 KB（gzip 后 61 KB），和 9 月底比只多了 3 KB，不是问题。
        - 服务器响应：TTFB 中位 180 ms，CDN 命中率 97%，和之前一样。
        - 第三方统计脚本：一直是 async 加载，长任务只有 30 ms 左右。

        ## 打算怎么改（按收益排）

        1. Hero 图转 AVIF，按 640 / 1280 / 1920 三档出图写 srcset，加 `fetchpriority="high"` 和 preload；预计 LCP 回到 2 s 以内。
        2. 字体改成 `<link rel="preload">` + `font-display: swap`，只留正文用的 400 与 600 两个字重，用 `size-adjust` 对齐回退字体的行高，消掉字体那份 CLS。
        3. 客服挂件改成点了"联系我们"才加载，按钮位置先用一个同尺寸的占位，消掉它那份 CLS 和长任务。

        三处都只动官网仓库，不涉及推送和发布；先按 1 → 2 → 3 的顺序改，改完再跑一遍 Lighthouse 对比。
        """

    static let backendDone = """
        后端部分做完了，前端还没动。

        ## 改了什么

        - `POST /api/password/reset-request`：收邮箱，不管存不存在都返回 202 和同一句提示；存在时生成 32 字节随机令牌，库里只存 SHA-256 哈希（password_resets 表：user_id、token_hash、expires_at、used_at），发重置邮件。邮箱先做 trim 和小写，再查用户。
        - `POST /api/password/reset`：收令牌和新密码，按哈希查、校验没过期没用过，改密码、把 used_at 填上，同一用户其余未用的令牌一并作废，并让该用户已登录的会话全部下线（sessions 表按 user_id 删，refresh token 一起吊销）。
        - 限流：同一邮箱 60 秒内只发一次（第二次返回 429，前端照样显示同一句提示），按邮箱的哈希计数，存在 password_reset_throttle 表里；另外同一 IP 每小时最多 20 次，防止拿一堆邮箱轮着刷。
        - 邮件：沿用注册验证邮件的模板（templates/mail/verify.mjml），换了标题、正文和按钮文案，链接是 https://demo.dev/reset?token=…，30 分钟有效。邮件走现有的 `createTransport()`。
        - 迁移：20261019_add_password_resets.sql，建两张表与索引；本地与 CI 的测试库都跑过。回滚脚本也写了（down 里删两张表）。
        - 清理：加了一个每天凌晨跑的定时任务，删掉过期超过 7 天的令牌记录和限流记录，免得表一直涨。

        ## 对照你的四条要求

        | 要求 | 怎么做的 | 对应的测试 |
        | --- | --- | --- |
        | 链接 30 分钟有效、只能用一次 | expires_at = 签发时间 + 30 分钟；用过填 used_at，再用返回 410 | reset.test.ts 第 2、3 条 |
        | 沿用注册验证邮件的模板 | 同一个 verify.mjml，只换文案 | 手动看了 MailHog 里的样子 |
        | 同一邮箱一分钟最多一次 | password_reset_throttle 按邮箱哈希计数 | reset-request.test.ts 第 3、4、5 条 |
        | 不泄露用户是否存在 | 两种情况同一状态码、同一句提示、响应时间补齐到 300 ms | reset-request.test.ts 第 1、2 条 |

        响应时间补齐是额外加的：不补的话，存在的邮箱因为要发邮件会慢 200 ms 左右，能被用来猜用户是否存在。

        ## 验证

        ```
        $ npm test -- auth
         PASS  tests/auth/reset-request.test.ts
          ✓ 邮箱存在：202，发一封邮件，库里存的是哈希 (41 ms)
          ✓ 邮箱不存在：202，同一句提示，不发邮件 (12 ms)
          ✓ 60 秒内第二次：429，不发邮件 (18 ms)
          ✓ 61 秒后再请求：202，发第二封 (15 ms)
          ✓ 大小写不同的同一邮箱共用限流 (14 ms)
          ✓ 同一 IP 一小时第 21 次：429 (22 ms)
         PASS  tests/auth/reset.test.ts
          ✓ 令牌正确：改密码成功，旧密码失效 (63 ms)
          ✓ 令牌用过一次后再用：410 (22 ms)
          ✓ 令牌过期（31 分钟）：410 (19 ms)
          ✓ 同一用户签发新令牌后旧令牌作废 (27 ms)
          ✓ 改密码后该用户其余会话下线 (34 ms)
          ✓ 新密码不合规：422，令牌不作废 (16 ms)
         PASS  tests/auth/login.test.ts (9 tests)
        Test Suites: 3 passed, 3 total
        Tests:       21 passed, 21 total
        $ npm run lint
        ✔ No problems
        $ npm run typecheck
        ✔ tsc --noEmit: 0 errors
        ```

        手动用 curl 走了一遍：注册过的邮箱请求后 MailHog 收到邮件，标题「重置你的密码」，样式和注册验证邮件一致；没注册的邮箱返回同一句提示、MailHog 里没有邮件。

        后端好了，要接着做登录页的前端部分（入口、填邮箱的页面、设新密码的页面和提示文案）吗？
        """

    static let standup = """
        这是今天站会的纪要，跟咱们相关的你心里有个数就行，不用为它建任务。

        【10/20 站会纪要】
        1. 发布节奏：演示项目这个月照常每周四发版，下次是 10/23；官网的发版跟着市场部的活动走，下一次是 10/29 的秋季活动页上线。
        2. 设计：设计组下周开始统一图标风格，线性图标换成 1.5px 描边，会出一份新的图标库，届时各项目自己替换，不急。
        3. 客服反馈：这两周客服收到最多的三类问题是忘记密码（每周 40 来单，现在只能人工改）、设置改了不生效、首页在手机上打开慢。产品那边说这三件优先级最高。
        4. 运维：数据库下周六凌晨 2 点到 4 点做小版本升级，期间演示项目只读；官网不受影响。各项目这段时间别安排数据迁移。
        5. 安全：公司要求本季度内把所有项目的高危依赖清零，季度末（12/31）安全组会统一扫一遍。
        6. 招聘：前端岗位下周二、周四各有一场面试，需要的人自己报名当面试官。
        7. 杂项：办公室周五下午消防演练，3 点到 3 点半所有人下楼。
        8. 下周站会改到周二上午 10 点，周一大家调休。

        待办（都已经有人认领，咱们不用管）：
        - 市场部：秋季活动页的文案与配图，10/25 前给到官网。
        - 运维：数据库升级的通知邮件，10/24 前发给全体用户。
        - 设计：图标库 v2，10/31 前出。
        - 产品：忘记密码、设置页、首页性能三件的验收标准，今天之内写进各自的需求文档。

        另外，产品经理小林提了一句：忘记密码上线后，客服那边的人工改密码流程就可以停掉了，到时候要通知客服组。

        补充（会后小林单独发的）：
        - 忘记密码的验收她会亲自走一遍：注册过的邮箱、没注册的邮箱、过期链接、用过的链接、一分钟内连点，五种情况都要能复现。
        - 设置页这次改完，客服的"改了不生效"类工单预计能少一半，她会在上线两周后拉数据看。
        - 首页性能这件，市场部很在意，因为 10/29 的活动页会从首页导流，首页慢的话活动页的转化也会受影响。
        - 依赖升级那件，安全组的扫描结果她转给了我，高危的就是 jsonwebtoken、axios、semver 这几个，和之前的判断一致。
        - 下个月计划：演示项目要做"团队空间"，官网要改版导航；这两件月底开评审会，到时候再说。
        """

    static let feedback = """
        【设置页用户反馈汇总，客服组 10/6–10/19，共 64 条，按主题归类】

        一、改了不生效（23 条）
        - "我把通知关了，第二天还是收到邮件。"（后查：改完没点最底下的保存）
        - "字号调大以后一刷新又变回去了。"
        - "两步验证开了好几次，每次回来都是关的。"
        - "改头像要点两次保存？第一次点的那个是什么？"
        - "手机上根本找不到保存按钮，滑到底才看到。"
        - "以为改了自动保存，结果没有，白改了二十分钟。"
        - 另有 17 条内容类似，都指向"有的项立刻生效、有的项要点保存"。

        二、找不到某一项（19 条）
        - "免打扰时段在哪？我翻了三遍。"（在第 33 项，夹在编辑器设置中间）
        - "已登录设备在哪里看？想把旧手机踢掉。"
        - "搜'邮件'出来一堆，不知道哪个是关通知的。"
        - "导出数据和导出到邮箱有什么区别？"
        - "主题和强调色为什么不在一起？"
        - "实验功能是什么？点开了会怎样？"
        - 另有 13 条：找 API 令牌、Webhook、屏蔽列表、存储用量的，都说"不知道在哪个位置"。

        三、太长、太乱（12 条）
        - "设置页像一张没排版的表格。"
        - "什么都堆在一起，看着就累。"
        - "希望分个类，比如账号的放一起、通知的放一起。"
        - "能不能把不常用的收起来？"
        - "高级选项和普通选项混在一起，怕误点。"
        - 另有 7 条类似。

        四、误操作（6 条）
        - "不小心点了重置所有设置，没有任何确认，全没了。"
        - "注销账号按钮就在改昵称旁边，差点点到。"
        - "清除缓存以后草稿没了。"（后查：清除缓存会清掉本地未同步的草稿，界面没有说明）
        - 另有 3 条类似。

        五、其他（4 条）
        - "深色模式下有几个开关看不清是开还是关。"
        - "字号最大只到 18，看着还是小。"
        - "希望手机和电脑的设置能分开。"
        - "设置页打开要转两秒圈。"

        客服组的建议：先解决"改了不生效"和"找不到"，这两类占了六成多；误操作虽然少，但每一条都是用户真丢了东西，也要一起处理。
        """

    static let depsReport = """
        升级清单出好了，没有动任何依赖。演示项目 package.json 里直接依赖 38 个，有 21 个落后；按风险分三档，建议先做第一档。

        ## 第一档：有安全公告，建议尽快升（4 个）

        | 包 | 现在 | 建议 | 原因 | 风险 |
        | --- | --- | --- | --- | --- |
        | jsonwebtoken | 8.5.1 | 9.0.2 | 有两条公告（算法混淆、弱密钥），我们签 refresh token 用到它 | 9.x 默认拒绝不带 algorithms 的 verify，代码里有 2 处要补参数 |
        | express | 4.18.2 | 4.21.1 | 路径解析与 open redirect 的公告 | 小版本内升级，没有破坏性改动 |
        | axios | 1.6.0 | 1.7.7 | SSRF 相关公告，服务端调第三方时用到 | 小版本，没有破坏性改动 |
        | semver | 5.7.1 | 7.6.3 | ReDoS 公告，是 3 个包间接带进来的 | 只要升直接依赖它的那 3 个包就行 |

        ## 第二档：落后一个大版本、有维护价值（9 个）

        - React 18.2 → 19.0：新编译器与 Actions，项目里有 6 处用到了 `forwardRef`、2 处 `defaultProps` 写在函数组件上，19 里要改写；预计半天到一天。
        - Vite 5.4 → 6.0：配置里的 `resolve.conditions` 默认值变了，我们的别名配置要跟着改一行；开发服务器更快一点。
        - TypeScript 5.4 → 5.6：更严格的空值检查会报出 14 处新错误，都是真问题（可能为 undefined 的地方没判断）。
        - ESLint 8 → 9：要从 .eslintrc 迁到 flat config，规则本身不变；8 已经停止维护。
        - Vitest 1.6 → 2.1、Prisma 5.10 → 5.20、date-fns 2 → 4、zod 3.22 → 3.23、mjml 4.14 → 4.15：都是常规升级，改动都在一两处以内。

        ## 第三档：可以不急（8 个）

        - Tailwind 3 → 4：配置方式整体改了（CSS 里写配置），收益是构建更快，但改动面大，牵涉 120 多个组件里的类名写法，建议单独排期，不和别的升级混在一起做。
        - 其余 7 个是补丁版本（lodash、clsx、nanoid 等），一起升就行，几乎没有风险。

        ## 现在的状况

        ```
        $ npm outdated --long | wc -l
              22
        $ npm audit --omit=dev
        4 vulnerabilities (1 moderate, 3 high)
          jsonwebtoken  <9.0.0   high      Improper restriction of security token assignment
          express       <4.19.2  moderate  Open Redirect in malformed URLs
          axios         <1.7.4   high      Server-Side Request Forgery
          semver        <5.7.2   high      Regular Expression Denial of Service
        $ node -v
        v20.11.1
        ```

        Node 20 到 2026-04 已经结束维护，第二档升完后建议顺带把 CI 与部署的 Node 升到 22（.nvmrc 和 deploy/Dockerfile 各改一行）。

        ## 建议的顺序

        1. 第一档 4 个一起升，跑单元测试和 lint，单独一个提交，半天以内。
        2. 第二档按 TypeScript → ESLint → Vite/Vitest → React 的顺序，每个一个提交，React 放最后，因为它最可能牵出界面上的问题。
        3. Tailwind 4 单独立项。

        都只是建议，等你看过再定先做哪一档。
        """

    static let depsTier1 = """
        第一档的 4 个依赖升完了，单独一个提交（本地，没有推送）。

        ## 升了什么

        | 包 | 从 | 到 | 改了哪些代码 |
        | --- | --- | --- | --- |
        | jsonwebtoken | 8.5.1 | 9.0.2 | src/auth/tokens.ts 里 2 处 `jwt.verify` 补上 `algorithms: ["HS256"]`；签发时的密钥长度本来就是 64 字节，满足 9.x 的检查 |
        | express | 4.18.2 | 4.21.1 | 没改代码 |
        | axios | 1.6.0 | 1.7.7 | 没改代码；顺手把调第三方的 3 处加上了 `maxRedirects: 0`，和这次的公告是同一类问题 |
        | semver | 5.7.1 | 7.6.3 | 它是间接依赖：升了 node-gyp、nodemon、@prisma/internals 三个直接依赖，semver 跟着到了 7.x |

        ## 验证

        ```
        $ npm audit --omit=dev
        found 0 vulnerabilities
        $ npm test
        Test Suites: 42 passed, 42 total
        Tests:       318 passed, 318 total
        Time:        41.8 s
        $ npm run lint
        ✔ No problems
        $ npm run typecheck
        ✔ tsc --noEmit: 0 errors
        $ git log -1 --stat --format='%h %s'
        5d2c8e1 升级有安全公告的依赖：jsonwebtoken 9、express 4.21、axios 1.7、semver 7
         package.json                |  8 ++++----
         package-lock.json           | 214 +++++++++++++++++++++++++---------------------
         src/auth/tokens.ts          |  4 ++--
         src/integrations/http.ts    |  6 ++++--
         4 files changed, 128 insertions(+), 104 deletions(-)
        ```

        手动验证：本地登录、刷新 token、退出登录都正常；用 8.x 签发的旧 refresh token 刷新也能通过（算法一样是 HS256），所以线上用户不会因为这次升级被踢下线。

        第二档和第三档没动，等你定。提交还在本地，推不推送你说了算。
        """

    static let layoutDone = """
        设置页的布局改完一版了：一页长列表、7 个分组，每组一个小标题，保存方式统一成改了立刻存。

        ## 改了什么

        - 拆出了 `SettingsGroup`（组标题 + 组内各项）和 `SettingsRow`（标签、说明、控件、存好了的小对勾）两个组件，SettingsPage.tsx 从 1,240 行降到 310 行。
        - 46 项按分组表挪进了 7 组：账号、通知、外观、编辑器、隐私、数据、高级；组内按近 30 天的使用频率排。
        - 保存：每项改了就存，存好后右边的对勾亮 1.5 秒；底部的"保存"按钮去掉了。原来要点保存的 15 项里，有 2 项（登录邮箱、手机号）改了要发验证码，这两项保留了"发送验证码"的确认步骤，没有改成立刻存。
        - 搜索：顶部的搜索按组过滤，搜到的项连同组标题一起显示；搜"邮件"现在分在通知、账号、数据三组里，一眼看得出是哪种邮件。
        - 危险操作：注销账号挪到账号组最底下、重置所有设置挪到高级组最底下，都是红字、点了二次确认。
        - 第三方插件用的锚点 id（`#settings-editor-autosave` 这类）原样保留，用旧链接跳进来能定位到对应的项，并且高亮 2 秒。
        - e2e 用例里按"第 n 个输入框"定位的地方都改成了按标签定位（没跑，这周不跑 e2e）。

        ## 验证

        ```
        $ npm test -- settings
         PASS  tests/settings/SettingsPage.test.tsx (18 tests)
         PASS  tests/settings/SettingsRow.test.tsx (7 tests)
         PASS  tests/settings/search.test.ts (6 tests)
        Tests: 31 passed, 31 total
        $ npm run lint
        ✔ No problems
        $ npm run typecheck
        ✔ tsc --noEmit: 0 errors
        ```

        单元测试里覆盖了：每一项的存储键名没变（对着改前导出的 46 个键逐一比对）、立刻存成功后对勾出现、存失败时控件回到原值并提示、旧锚点能定位。

        ## 还没做的

        - 改前改后的截图还没截：本地模拟器今天起不来，正在换 Xcode 版本，好了就截手机与桌面两种宽度发到手机。
        - 手机上整页现在大约 3 屏半长，"高级"组在最底下，要滑一阵才到；后面可能要考虑在顶部加个分组的跳转。

        接下来等模拟器好了就截图。
        """

    static let frontendHalf = """
        前端做了一半：登录页的入口和填邮箱的页面好了，设新密码的页面还在做。

        ## 已经好的

        - 登录页密码框下面加了「忘记密码？」链接，点了进 /forgot。
        - /forgot 页：一个邮箱输入框和「发送重置邮件」按钮；提交后不管结果如何都显示「如果这个邮箱注册过，你会收到一封邮件」，按钮变成 60 秒倒计时，倒计时期间不能再点（和后端的限流对齐，避免用户连点看到 429）。
        - 邮箱格式不对时在输入框下面就地提示，不发请求；网络出错时提示「网络不太好，稍后再试」，不显示后端的原始报错。
        - 文案都走了 i18n（zh-CN 与 en 两份），和登录页其余文案放在同一个命名空间。
        - 键盘：在邮箱框里回车就提交；Tab 顺序是输入框 → 按钮 → 返回登录。

        ## 还在做的

        - /reset?token=… 页：两个密码框（新密码、确认新密码）、密码强度提示、提交后跳回登录页并提示「密码已重置，请用新密码登录」。
        - 令牌过期或用过时（后端返回 410）显示「链接已失效」，并给一个「重新发送重置邮件」的入口。
        - 改前改后的截图和端到端走一遍，等 /reset 页做完一起做。

        ## 现在的测试

        ```
        $ npm test -- forgot
         PASS  tests/pages/ForgotPage.test.tsx
          ✓ 提交后显示同一句提示（邮箱存在） (38 ms)
          ✓ 提交后显示同一句提示（邮箱不存在） (21 ms)
          ✓ 提交后按钮进入 60 秒倒计时 (44 ms)
          ✓ 邮箱格式不对不发请求 (12 ms)
          ✓ 网络出错显示友好提示 (19 ms)
          ✓ 回车提交 (15 ms)
         PASS  tests/pages/LoginPage.test.tsx (11 tests)
        Tests: 17 passed, 17 total
        $ npm run lint
        ✔ No problems
        ```

        后端那 21 个测试也重跑了一遍，都还是绿的。接下来做 /reset 页。
        """

    static let tsErrors = """
        TypeScript 5.6 报的 14 处新错误都列出来了（在一个临时分支上试的，没提交，主分支没动）。全是"可能为 undefined 却直接用了"这一类，都是真问题，不是误报。

        ## 按模块

        ### 认证（3 处）
        1. src/auth/session.ts:48 `user.profile.locale` —— profile 在注销流程里可能已经删掉，读 locale 会抛错。线上日志里 9 月有 12 次 "Cannot read properties of undefined (reading 'locale')"，就是这里。
        2. src/auth/tokens.ts:91 `payload.sub` —— 解析失败时 payload 是 undefined，现在靠外层 try/catch 兜住，报的错误信息不对（显示成"令牌过期"）。
        3. src/auth/oauth.ts:133 `account.provider` —— 第三方登录回调里，用户在授权页点了"取消"时 account 为空。

        ### 看板（5 处）
        4. src/board/columns.ts:27 `columns.find(...)!.cards` —— 非空断言；列被别人删了以后再拖卡片会崩。
        5. src/board/columns.ts:64 同上，排序时。
        6. src/board/drag.ts:112 `target.dataset.index` —— 拖到列表外时 target 是 document，没有 dataset。
        7. src/board/filters.ts:39 `filters.assignee.id` —— 筛选"未分配"时 assignee 是 null。
        8. src/board/stats.ts:18 `days[busiest].count` —— 一周都没有活动时 busiest 是 -1。周报邮件会用到这个统计，最好先修。

        ### 编辑器（3 处）
        9. src/editor/autosave.ts:55 `draft.updatedAt.getTime()` —— 新建的草稿还没存过时 updatedAt 为空。
        10. src/editor/paste.ts:22 `clipboard.files[0].type` —— 粘贴纯文本时 files 是空数组。
        11. src/editor/mentions.ts:80 `members.get(id).name` —— 被提及的人已经退出团队。

        ### 设置（2 处）
        12. src/pages/settings/useSetting.ts:31 `defaults[key]` 的返回值直接当字符串用，新增的键没有默认值时会存进 "undefined" 这个字符串。设置页重做正好会碰到这个文件。
        13. src/pages/settings/export.ts:14 `user.email.split('@')` —— 只用手机号注册的用户没有邮箱。

        ### 其他（1 处）
        14. src/integrations/webhook.ts:66 `res.headers['x-signature'].toString()` —— 对方不带签名头时抛错，Webhook 调用记录里显示"内部错误"。

        ## 修起来的工作量

        - 每处都是加判断或给默认值，改动都在 1–5 行；14 处加起来大约 60 行。
        - 第 1、8、12 处建议优先：1 有线上报错，8 会影响周报邮件的统计，12 会和设置页的重做撞在同一个文件。
        - 修完再升 TypeScript，就是一个只改 package.json 的小提交。

        ```
        $ npx tsc --noEmit -p tsconfig.json 2>&1 | tail -3
        src/integrations/webhook.ts(66,5): error TS18048: 'res.headers['x-signature']' is possibly 'undefined'.

        Found 14 errors in 11 files.
        ```

        没修，等你定要不要做第二档。
        """

    static let securityScan = """
        安全组刚发来的扫描报告，你对一下和依赖那件是不是一回事，不用转给会话。

        【安全组季度扫描 · 演示项目 · 2026-10-20】
        扫描范围：生产依赖（不含开发依赖）、容器镜像、公开端口、密钥泄露。

        一、依赖漏洞（4 项，均为本季度需清零的高危或中危）
        1. jsonwebtoken < 9.0.0：令牌校验时可被诱导使用不安全的算法。等级：高危。处置：升级到 9.x 并在校验时显式指定算法。
        2. axios < 1.7.4：服务端请求伪造。等级：高危。处置：升级到 1.7.4 以上；调用第三方时关闭自动跟随跳转。
        3. semver < 5.7.2：正则表达式拒绝服务。等级：高危。处置：升级引入它的直接依赖。
        4. express < 4.19.2：畸形地址导致的开放跳转。等级：中危。处置：升级到 4.19.2 以上。

        二、容器镜像（2 项）
        1. 基础镜像 node:20-bullseye 中的 openssl 有一个中危公告。处置：换成 node:22-bookworm-slim，镜像体积也能从 1.1 GB 降到 240 MB。
        2. 镜像里以 root 运行应用。处置：Dockerfile 加 USER node。等级：低危。

        三、公开端口（0 项）
        未发现除 443 以外的公开端口。

        四、密钥泄露（1 项）
        1. .env.example 中仍有 SENDGRID_API_KEY 字段（值为空），不是泄露，但容易让人误以为需要配置。等级：信息。处置：删除该字段。

        五、时间要求
        - 高危：本季度末（12/31）前清零。
        - 中危：下季度末前清零。
        - 低危与信息：自行安排。

        六、复查方式
        修复后在工单里回复提交号，安全组会在一周内复扫确认。
        """

    static let readmeShots = [
        "01-首页.png  1280×800  现在的首页（新导航）", "02-登录.png  1280×800  带「忘记密码？」入口", "03-看板.png  1280×800  三栏看板",
        "04-编辑器.png  1280×800  Markdown 编辑与预览", "05-设置.png  1280×800  设置页", "06-通知.png  1280×800  通知中心",
        "07-手机首页.png  390×844", "08-手机看板.png  390×844", "09-深色.png  1280×800  深色模式",
    ]

    static let readmeDone = """
        README 的截图换好了。

        - 9 张截图都按现在的界面重截（Mac 1280×800、手机 390×844 各按原来的尺寸），放在 docs/images/，文件名沿用原来的，README 里的引用不用改。
        - 对照表：01 首页、02 登录（多了「忘记密码？」入口）、03 看板、04 编辑器、05 设置、06 通知、07 手机首页、08 手机看板、09 深色模式。
        - assets/readme/ 里没人引用的旧副本没动，删不删等你定。

        ```
        $ ls -la docs/images/
        -rw-r--r--  1 dev  staff  412330 Oct 20 16:02 01-首页.png
        -rw-r--r--  1 dev  staff  298114 Oct 20 16:02 02-登录.png
        -rw-r--r--  1 dev  staff  455902 Oct 20 16:03 03-看板.png
        -rw-r--r--  1 dev  staff  377451 Oct 20 16:03 04-编辑器.png
        -rw-r--r--  1 dev  staff  341208 Oct 20 16:04 05-设置.png
        -rw-r--r--  1 dev  staff  289760 Oct 20 16:04 06-通知.png
        -rw-r--r--  1 dev  staff  201377 Oct 20 16:05 07-手机首页.png
        -rw-r--r--  1 dev  staff  219044 Oct 20 16:05 08-手机看板.png
        -rw-r--r--  1 dev  staff  433615 Oct 20 16:06 09-深色.png
        $ npx markdown-link-check README.md
        FILE: README.md
          [✓] docs/images/01-首页.png
          …（9 张都是 ✓）
          11 links checked.
        ```

        新截图的总览图发到手机了。
        """

    static let lighthouseShot = [
        "改前  Performance 63   LCP 5.8 s   TBT 620 ms   CLS 0.21", "改后  Performance 92   LCP 1.9 s   TBT 140 ms   CLS 0.02",
        "hero-2026.avif  640/1280/1920  共 312 KB", "inter-var  400/600  swap + preload", "chat widget  点了才加载",
    ]

    static let lighthouseDone = """
        官网首页的性能分修回来了：移动端 63 → 92。

        改动（都在官网仓库，没有推送）：
        1. Hero 图转 AVIF，640 / 1280 / 1920 三档写 srcset，加了 preload 与 fetchpriority="high"，2.3 MB → 三档合计 312 KB。
        2. 字体改成 preload + font-display: swap，只留 400 与 600 两个字重，用 size-adjust 对齐了回退字体。
        3. 客服挂件改成点了「联系我们」才加载，按钮位置先放同尺寸占位。

        验证：
        ```
        $ npx lighthouse http://localhost:4173 --preset=perf --form-factor=mobile（3 次取中位）
        Performance 92 | FCP 1.1 s | LCP 1.9 s | TBT 140 ms | CLS 0.02 | Speed Index 1.8 s
        $ npm test
        Tests: 31 passed, 31 total
        $ npm run lint
        ✔ No problems
        ```
        改前改后的 Lighthouse 对比截图发到手机了。
        """
}
#endif
