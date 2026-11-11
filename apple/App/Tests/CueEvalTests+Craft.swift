#if os(macOS)
import CueStore
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 只有 Cue 在场的几个时机：大事先出方案、追问两次就留给他、要的就是长相的成果只凭图挑刺；与后台整理记忆时把他反复交代的做法提议记成规矩。
extension CueEvalTests {
    @Test func c5追问两次就留给他() async throws {
        try await CueEval.run("c5-追问两次就留给他", expect: "改前改后的截图 Cue 追问过两次，会话这次还是没发：不问第三次，tell 一句缺什么，留给他回；不 done") { eval in
            let rig = eval.rig
            let work = try await rig.working(Self.title, Self.body)
            try await eval.trigger {
                try await rig.settleReworked(work, rounds: [
                    ("忘记密码做好了，23 个测试全过，lint 干净。", "缺改前改后的登录页截图：正文要的，发到手机。"),
                    ("测试输出在上一条。截图稍后。", "截图还是没发：把改前改后的登录页截图发到手机再交回。"),
                ], reply: "测试和 lint 都过了，功能没问题。截图我这边截不了。")
            }
            let session = try #require(try await rig.store.sessions(matching: work.id).first)
            return [
                Check(.result, "没问第三次（没 say）", eval.calls("task", "say").isEmpty),
                Check(.result, "没有 done", eval.calls("task", "done").isEmpty),
                Check(.interrupt, "tell 一句缺什么（提到截图）", eval.calls("tell").contains { ($0.args["text"] as? String)?.contains("截图") == true }),
                Check(.result, "留给他回（待回复）", session.awaitsReply(try await rig.store.cueDuty())),
            ]
        }
    }

    @Test func n2反复交代的做法提议成规矩() async throws {
        try await CueEval.run(
            "n2-反复交代的做法提议成规矩",
            expect: "他在三个会话里都交代过别加没人要的测试（一次换了说法），夹在几十句只管手头那件事的话里：后台整理记忆的大脑问他一次要不要记成重点（引他的原话），"
                + "只在一个会话里说了三遍的不问；问之前不记；他点可以后 Cue 把原话 note 带 pin 与 his"
        ) { eval in
            let rig = eval.rig
            let habit = [
                "对了，别加没人要的测试，测试是负债，只留覆盖用户可见行为的。", "还是那句：别加没人要的测试，测试是负债，只留覆盖用户可见行为的。",
                "测试别多写，没人要的不加：测试是负债，只留覆盖用户可见行为的那几个。",
            ]
            var works: [(work: Working, days: Double)] = []
            for (title, days) in [("修好注册页白屏", 6.0), ("导出报表加筛选", 2.0), (Self.title, 0.5)] {
                works.append((try await rig.working(title, "照现状修，做完贴出验证。"), days))
            }
            // 那条做法先各说一遍，再夹进只管手头那件事的话：攒够一批（`CueKeeper.heardBatch`）时三个会话里的都已在库里
            for (index, item) in works.enumerated() {
                try item.work.file.user(habit[index], at: .now - item.days * 86400)
                try await rig.read(habit[index], in: item.work.id)
            }
            for round in 0..<30 {
                for (index, item) in works.enumerated() {
                    let one = index == 0 && round < 3 ? "这次先别动数据库的表结构。" : Self.oneOffs[(round * 3 + index) % Self.oneOffs.count] + "（第 \(round + 1) 处）"
                    try item.work.file.reply("好，改了。", at: .now - item.days * 86400 + Double(round) * 60)
                    try item.work.file.user(one, at: .now - item.days * 86400 + Double(round) * 60 + 30)
                    try await rig.read(one, in: item.work.id)
                }
            }
            func proposals() async throws -> [CueMessage] { try await rig.store.cueHabitQuestions() }
            try? await eventually("后台整理记忆的大脑问了他") { try await !proposals().isEmpty }
            let asked = try await proposals()
            let early = try await rig.store.cueMemory().lines.contains { $0.pinned && $0.deletedAt == nil }
            var pinned = false
            if let card = asked.first {
                try await eval.trigger { try await rig.services.answerCueQuestion(card.id, CueAsk.once) }
                pinned = try await rig.store.cueMemory().lines.contains { $0.deletedAt == nil && $0.pinned && $0.source == .known(.you) && $0.text.contains("测试") }
            }
            eval.report.append("后台问的：\n" + asked.map { "- \($0.text)（卡上：\($0.asking?.question ?? "")\($0.asking?.why ?? "")）" }.joined(separator: "\n"))
            return [
                Check(.ask, "问了一次、只问这一条", asked.count == 1),
                Check(.ask, "问的话里引了他的原话（提到测试是负债）", asked.first?.text.contains("测试是负债") == true),
                Check(.ask, "只在一个会话里说的没问（没提数据库）", !asked.contains { $0.text.contains("数据库") }),
                Check(.ask, "他点头前没记成重点", !early),
                Check(.result, "他点可以后记成他说的重点", pinned),
            ]
        }
    }

    /// 只管手头那件事的话（各会话里轮着说）
    static let oneOffs = [
        "限流改成 30 秒", "这个按钮往右挪 8 像素", "报错文案改成「请稍后再试」", "把日志级别调到 debug 再跑一遍", "先看看是不是缓存的问题",
        "截图发我看看", "这一步跑完了吗", "列表默认按时间倒序", "超时先放到 10 秒", "把这个接口的返回贴出来", "继续", "标题字号小一号",
    ]

    @Test func u2界面成品先挑刺() async throws {
        try await CueEval.run(
            "u2-界面成品先挑刺",
            expect: "会话重做完设置页、发来成品截图（眉标、编号标签、每行一句废话说明、彩虹渐变标题、卡片套卡片、一行字被截断）：Cue 打开图，只凭图挑刺，say 带百分制分数与具体扣分处，不 done、不打扰他"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working("重做设置页", "照他选定的方案 2 重做演示项目的设置页：分成通用、通知、账号三组。做完的标准：改后的设置页截图发到手机；项目已有的检查通过。")
            try await rig.shots([("settings-after.png", "设置页 改后")], from: work, drawing: { _ in try sloppySettingsShot() })
            try await eval.trigger {
                try await rig.settle(work, reply: """
                    设置页重做好了：分成通用、通知、账号三组，每组一张卡片。
                    ```
                    $ npm test
                    Tests: 41 passed, 41 total
                    $ npm run lint
                    ✔ No problems
                    ```
                    改后的截图发到手机了。
                    """)
            }
            let said = eval.calls("task", "say").compactMap { $0.args["text"] as? String }.joined(separator: "\n")
            return [
                Check(.result, "打开看了成品图", eval.calls("read").contains { (($0.args["file_path"] ?? $0.args["path"]) as? String)?.hasSuffix(".png") == true }),
                Check(.result, "没有 done", eval.calls("task", "done").isEmpty),
                Check(.result, "say 带百分制分数", said.contains(/\d{2}\s*(\/\s*100|分)/)),
                Check(.result, "点出图上至少两处具体毛病（眉标或标签、说明句、渐变、嵌套、截断、对齐）", [/眉|SETTINGS|PREFERENCES|标签|编号|0[123]/, /说明|描述|废话|副标题/, /渐变|彩虹/, /嵌套|套/, /截断|省略|…/, /对齐|错位|间距/]
                    .count { said.contains($0) } >= 2),
                Check(.interrupt, "没打扰他（没 tell）", eval.calls("tell").isEmpty),
            ]
        }
    }
}

/// 一张做得很模板的设置页成品图：标题上方的小号大写眉标、彩虹渐变标题、标题下的说明句、带编号标签的卡片、卡片套卡片、每行一句不带信息的说明、
/// 左缘不齐、一行字被截断。挑刺的 Cue 该从图上看出这些。
@MainActor
func sloppySettingsShot() throws -> Data {
    func row(_ title: String, _ note: String, inset: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Capsule().fill(.green).frame(width: 36, height: 20)
            }
            Text(note).font(.caption2).foregroundStyle(.gray)
        }
        .padding(8).padding(.leading, inset).background(Color(white: 0.97), in: .rect(cornerRadius: Radius.block)).overlay(RoundedRectangle(cornerRadius: Radius.block).stroke(.gray.opacity(0.4)))
    }
    func group(_ number: String, _ name: String, _ tint: Color, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(number).font(.caption2.monospaced().bold()).padding(.horizontal, 6).padding(.vertical, 2).background(tint.opacity(0.2), in: .capsule)
                Text(name).font(.headline)
                Text("NEW").font(.system(size: 8).bold()).foregroundStyle(.white).padding(3).background(.red, in: .capsule)
            }
            Text("在这里管理与\(name)有关的所有选项").font(.caption).foregroundStyle(.gray)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, item in row(item.0, item.1, inset: index == 1 ? 14 : 0) }
        }
        .padding(12).background(.white, in: .rect(cornerRadius: Radius.card)).overlay(alignment: .leading) { tint.frame(width: 4) }.shadow(radius: 6)
    }
    let shot = VStack(alignment: .leading, spacing: 12) {
        Text("SETTINGS · PREFERENCES").font(.system(size: 9).weight(.semibold)).kerning(2).foregroundStyle(.gray)
        Text("设置").font(.largeTitle.bold()).foregroundStyle(LinearGradient(colors: [.pink, .orange, .yellow, .green, .blue], startPoint: .leading, endPoint: .trailing))
        Text("欢迎来到设置页面，你可以在这里对应用进行各种各样的设置").font(.caption).foregroundStyle(.gray)
        group("01", "通用", .blue, rows: [("跟随系统外观", "打开后外观会跟随系统"), ("启动时打开上次的项目并恢复全部窗口与滚动位置", "打开后会打开上次的项目")]).padding(.leading, 6)
        group("02", "通知", .purple, rows: [("任务完成时通知", "任务完成时会通知你")])
        group("03", "账号", .orange, rows: [("iCloud 同步", "打开后会同步")]).padding(.leading, 12)
    }
    .lineLimit(1).padding(16).frame(width: 320, height: 640, alignment: .top).background(Color(red: 0.98, green: 0.95, blue: 0.88))
    return try png(shot)
}
#endif
