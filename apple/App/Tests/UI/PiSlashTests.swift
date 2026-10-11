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

/// 上下文用量条：已用比例决定颜色档位，文案写已用与剩余；压缩后到下一次回答前没有读数、不画。
struct PiContextMeterTests {
    private func meter(_ tokens: Int, window: Int = 200_000) -> PiContextMeter {
        PiContextMeter(PiContextUsage(tokens: tokens, window: window))!
    }

}
