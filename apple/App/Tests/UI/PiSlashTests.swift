import CueStore
import Foundation
import Testing
@testable import CuePad

/// 回复框里的斜杠命令：输入 "/" 弹出的面板列哪些（过滤与排序）、输入框里的内容算不算一条命令、
/// 命令带上的卡片怎么并进参数；上下文用量条的读数。
@MainActor
struct PiSlashTests {
    private func command(_ name: String, _ source: PiCommandSource, summary: String? = nil, hint: String? = nil) -> PiSlashCommand {
        PiSlashCommand(name: name, summary: summary, source: .known(source), hint: hint)
    }

    private var commands: [PiSlashCommand] {
        [
            command("compact", .builtin, summary: "压缩上下文", hint: "[说明]"),
            command("reload", .builtin, summary: "重新载入扩展"),
            command("review", .extension, summary: "审查改动"),
            command("greet", .prompt, summary: "问好"),
            command("skill:review", .skill, summary: "按清单审查"),
            command("skill:deploy", .skill),
        ]
    }

    @Test func 刚输入斜杠时列全部_内置在前_其次扩展_模板_技能() {
        #expect(PiSlash.matches("/", in: commands)?.map(\.name) == ["compact", "reload", "review", "greet", "skill:review", "skill:deploy"])
    }

    @Test func 过滤_名字开头的在前_名字里含有的其次_说明里含有的最后() {
        #expect(PiSlash.matches("/re", in: commands)?.map(\.name) == ["reload", "review", "greet", "skill:review"])
        #expect(PiSlash.matches("/skill:de", in: commands)?.map(\.name) == ["skill:deploy"])
        #expect(PiSlash.matches("/压缩", in: commands)?.map(\.name) == ["compact"])  // 说明里含有
        #expect(PiSlash.matches("/COMP", in: commands)?.map(\.name) == ["compact"])  // 不分大小写
    }

    @Test func 没有匹配时是空列表_不是斜杠开头或已经在写参数时没有面板() {
        #expect(PiSlash.matches("/zzz", in: commands)?.isEmpty == true)
        #expect(PiSlash.matches("", in: commands) == nil)
        #expect(PiSlash.matches("hello /x", in: commands) == nil)
        #expect(PiSlash.matches(" /compact", in: commands) == nil)
        #expect(PiSlash.matches("/compact 精简点", in: commands) == nil)
        #expect(PiSlash.matches("/compact\n", in: commands) == nil)
    }

    @Test func 选中一条命令_输入框里变成斜杠加名字加空格() {
        #expect(PiSlash.insertion(for: commands[0]) == "/compact ")
    }

    @Test func 输入框里是一条已知命令才算命令_参数原样带上() {
        func line(_ text: String, attachments: [Outbox] = [], images: [PickedImage] = []) -> String? {
            var draft = ComposerDraft()
            draft.text = text
            draft.attachments = attachments
            draft.images = images
            return PiSlash.line(of: draft, in: commands)
        }
        #expect(line("/compact") == "/compact")
        #expect(line("  /greet   world \n") == "/greet   world")
        #expect(line("/nope") == nil)
        #expect(line("请 /compact") == nil)
        #expect(line("/") == nil)
        // 交给 Agent 带着卡片：卡片文字接在参数后面
        #expect(line("/greet 这件事", attachments: [Outbox(content: "修好登录")]) == "/greet 这件事\n\n修好登录")
        #expect(line("/greet", attachments: [Outbox(content: "修好登录"), Outbox(content: "再看日志")]) == "/greet\n\n修好登录\n\n再看日志")
    }

    @Test func 命令带图片时不算命令() {
        var draft = ComposerDraft()
        draft.text = "/greet"
        draft.attachments = [Outbox(content: "![](cuepad://img/abc)")]
        #expect(PiSlash.line(of: draft, in: commands) == nil)
    }
}

/// 上下文用量条：已用比例决定颜色档位，文案写已用与剩余；压缩后到下一次回答前未知。
struct PiContextMeterTests {
    @Test(arguments: [
        (21_000, PiContextMeter.Level.roomy),
        (139_999, .roomy),
        (140_000, .tight),
        (179_999, .tight),
        (180_000, .critical),
        (230_000, .critical),
    ])
    func 档位随已用比例变紧(tokens: Int, level: PiContextMeter.Level) {
        #expect(PiContextMeter(PiContextUsage(tokens: tokens, window: 200_000)).level == level)
    }

    @Test func 读数_比例夹在0到1_剩余不为负() {
        let over = PiContextMeter(PiContextUsage(tokens: 230_000, window: 200_000))
        #expect(over.fraction == 1 && over.remaining == 0)
        let fresh = PiContextMeter(PiContextUsage(tokens: 0, window: 200_000))
        #expect(fresh.fraction == 0 && fresh.remaining == 200_000)
    }

    /// 用量条旁写百分比；悬停与读屏先说这是上下文，快满了时说可以压缩。
    @Test func 用量条旁的百分比与说明() {
        #expect(PiContextMeter(PiContextUsage(tokens: 42_000, window: 200_000)).percent == "21%")
        #expect(PiContextMeter(PiContextUsage(tokens: nil, window: 200_000)).percent == "—")
        #expect(PiContextMeter(PiContextUsage(tokens: 42_000, window: 200_000)).help.visible == "上下文 · 已用 21% · 剩 158k tokens")
        #expect(PiContextMeter(PiContextUsage(tokens: 172_000, window: 200_000)).help.visible == "上下文 · 已用 86% · 剩 28k tokens · 快满了，可以压缩")
    }

    @Test func 文案_已用百分比加剩余_大数写k和M() {
        #expect(PiContextMeter(PiContextUsage(tokens: 42_000, window: 200_000)).summary.visible == "已用 21% · 剩 158k tokens")
        #expect(PiContextMeter(PiContextUsage(tokens: 195_500, window: 200_000)).summary.visible == "已用 98% · 剩 4.5k tokens")
        #expect(PiContextMeter(PiContextUsage(tokens: 999_000, window: 1_000_000)).summary.visible == "已用 100% · 剩 1k tokens")
        #expect(PiContextMeter(PiContextUsage(tokens: 300_000, window: 1_200_000)).summary.visible == "已用 25% · 剩 900k tokens")
        #expect(PiContextMeter(PiContextUsage(tokens: 800, window: 1_000_000)).summary.visible == "已用 0% · 剩 999k tokens")
        #expect(PiContextMeter(PiContextUsage(tokens: 0, window: 2_000_000)).summary.visible == "已用 0% · 剩 2M tokens")
    }

    @Test func 接近上限才建议压缩() {
        #expect(!PiContextMeter(PiContextUsage(tokens: 159_999, window: 200_000)).suggestsCompact)
        #expect(PiContextMeter(PiContextUsage(tokens: 160_000, window: 200_000)).suggestsCompact)
    }

    @Test func 压缩后未知_不画比例_文案说明会在下次回答后更新() {
        let unknown = PiContextMeter(PiContextUsage(tokens: nil, window: 200_000))
        #expect(unknown.level == .unknown && unknown.fraction == nil && unknown.remaining == nil && !unknown.suggestsCompact)
        #expect(unknown.summary.visible == "刚压缩过 · 下次回答后更新（窗口 200k tokens）")
    }
}
