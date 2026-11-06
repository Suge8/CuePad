#if os(macOS)
import CueStore
import Foundation

/// 写给 Agent 的技能：CuePad 是什么、什么时候发预览、发什么、怎么发、做 HTML 页给手机看的约定（只写在这里），其余让 Agent 看 `--help`（命令行唯一的文档）。
/// 只写一份，在几家共读的 `~/.agents/skills/cuepad`（Claude Code 另有一个链到它的链接，`AgentIntegration`），正文各家通用。
/// 正文写 App 里 `cuepad` 的绝对路径，不用先把命令装进 PATH；App 被移动后路径变了，它就成了旧版，启动时重写。
/// 末尾的标记行写着为哪几家接入的（`kinds(in:)`）：几家共读一份文件，各家接没接入只记在这里。
enum AgentSkill {
    static let name = "cuepad"
    static let fileName = "SKILL.md"
    /// 标记行的开头；用它区分"CuePad 写的"与同名的用户文件（旧版写在各家目录里的副本也以它开头，只是不带接入的几家）
    static let ownershipMarker = "<!-- 由 CuePad 写入"
    private static let kindsPrefix = "（接入："

    static func text(cuepad: URL, for kinds: Set<AgentKind>) -> String {
        let command = shellQuoted(cuepad.path)
        let lines = [
            "description: 需要用户看一眼或拍板时用：把真东西（文档、改动、网页、PDF、图片、录屏）作为预览发到用户手机上的 CuePad；用户提到 CuePad、灵感、任务时也用：读写其中的灵感与任务。CuePad 是用户记灵感、管任务、指挥 Agent 的 App。",
            "---",
            "用户多在手机上的 CuePad 里看这个对话：除了你回答的文字，用户只看得到你发的预览和工具结果里的图，本机路径他打不开。要他看的东西作为预览发过去，回答里说一句发了什么。",
            "",
            "什么时候发：只在要他看一眼或拍板时——做出的页面、文档、方案、界面效果。纯代码改动不发，在回答里说改了什么；不为证明做完了而截图。",
            "",
            "发什么：发真东西，不发它的截图。文档发 .md（手机上排好版），要他过目的代码改动发 `git diff` 存成的 .diff（显示成增删对照），页面发 .html，还有 PDF、图片、录屏；截图只在要他看界面本身长什么样时发。",
            "",
            "怎么发：`\(command) show <文件…> --title <标题>…`。用户看到的是标题、不是文件名：按文件的先后每个一句，说清这是什么、看哪里，用和用户对话的语言、约 20 字以内（如 `--title \"改后：会话列表的分组标题\"`）。一次给几个文件是同一张卡，点开后左右切换。他回复里的 `预览「标题」：……` 说的就是你发的那一份。",
            "",
            "做 HTML 页给手机看时：",
            "- 手机顶栏已显示标题：页面里不写标题、页眉、导语和说明页脚，内容直接开始。",
            "- 按手机宽度排版，跟随深浅色（`prefers-color-scheme`）。",
            "- 能用原生控件（`button`、`input`、`select`、`details`）就不自绘。",
            "- 单个文件、不联网：样式与脚本写进同一个 HTML，图片用 `data:` 地址内联。",
            "",
            "其余命令（灵感、任务、搜索）：`\(command) --help`。",
            "在沙箱里跑命令时，资料库在沙箱外：写入的命令（show、add、done、move 等）申请在沙箱外运行。",
        ]
        let listed = AgentKind.allCases.filter(kinds.contains).map(\.rawValue).joined(separator: ", ")
        return (["---", "name: \(name)"] + lines + ["\(ownershipMarker)\(kindsPrefix)\(listed)），升级时整文件覆盖 -->", ""]).joined(separator: "\n")
    }

    /// 是 CuePad 写的就给出标记行里接入的几家（旧版的副本没有这一段，是空的）；不是为 nil。
    static func kinds(in text: String) -> Set<AgentKind>? {
        guard let marker = text.range(of: ownershipMarker) else { return nil }
        let rest = text[marker.upperBound...]
        guard rest.hasPrefix(kindsPrefix), let end = rest.firstIndex(of: "）") else { return [] }
        return Set(rest[rest.index(rest.startIndex, offsetBy: kindsPrefix.count)..<end].split(separator: ", ").compactMap { AgentKind(rawValue: String($0)) })
    }

    /// 路径里有空格等字符时 Agent 的 shell 会拆开它。
    static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) } ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
