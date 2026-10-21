#if os(macOS)
import CueStore
import Foundation

/// 写给 Agent 的技能：CuePad 是什么、怎么把文件发到手机、做 HTML 页给手机看的约定（只写在这里），其余让 Agent 看 `--help`（命令行唯一的文档）。
/// 正文写 App 里 `cuepad` 的绝对路径，不用先把命令装进 PATH；App 被移动后路径变了，它就成了旧版，启动时重写。
/// Codex 默认在沙箱里跑命令，资料库在沙箱外，写入要申请。
enum AgentSkill {
    static let name = "cuepad"
    static let fileName = "SKILL.md"
    /// 文件末尾的标记行；用它区分"CuePad 写的"与同名的用户文件
    static let ownershipMarker = "<!-- 由 CuePad 写入"

    static func text(for kind: AgentKind, cuepad: URL) -> String {
        let command = shellQuoted(cuepad.path)
        let lines = [
            "description: 交付能看的成果（截图、录屏、网页、PDF、文稿）给用户验收，或用户提到 CuePad、灵感、任务时用：把文件发到用户手机上的 CuePad，读写其中的灵感与任务。CuePad 是用户记灵感、管任务、指挥 Agent 的 App。",
            "---",
            "用户多在手机上看你的成果，本机路径（如 /tmp/x.png）他打不开。做完时把能看的成果发到手机，回答里说一句发了什么；指挥你的 Cue 也在那里核对。",
            "",
            "发到手机：`\(command) show <文件…> --title <标题>…`。用户看到的是标题、不是文件名：按文件的先后每个一句，说清这是什么、看哪里，用和用户对话的语言、约 20 字以内（如 `--title \"深色：会话列表的分组标题\"`）。一次给几个文件是同一张卡，点开后左右切换。",
            "",
            "做 HTML 页给手机看时：",
            "- 手机顶栏已显示标题：页面里不写标题、页眉、导语和说明页脚，内容直接开始。",
            "- 按手机宽度排版，跟随深浅色（`prefers-color-scheme`）。",
            "- 能用原生控件（`button`、`input`、`select`、`details`）就不自绘。",
            "- 单个文件、不联网：样式与脚本写进同一个 HTML，图片用 `data:` 地址内联。",
            "",
            "其余命令（灵感、任务、搜索）：`\(command) --help`。",
        ] + (kind == .codex ? ["资料库在沙箱外：写入的命令（show、add、done、move 等）申请在沙箱外运行。"] : [])
        return (["---", "name: \(name)"] + lines + ["\(ownershipMarker)，升级时整文件覆盖 -->", ""]).joined(separator: "\n")
    }

    /// 路径里有空格等字符时 Agent 的 shell 会拆开它。
    static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) } ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
