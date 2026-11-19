#if os(macOS)
import Foundation

/// CuePad 起的每个托管会话都带的一段常驻指引，各家在自己的 Runtime 里按会话追加进系统提示；什么时候发、发什么、网页怎么做只在 `cuepad show --help`，活预览在 `cuepad live --help`。
/// 写 App 里 `cuepad` 的绝对路径：不用先把命令装进 PATH，App 移动后新起的会话跟着新路径。
public enum SessionBrief {
    public static func text(cuepad: URL) -> String {
        let command = shellQuoted(cuepad.path)
        return "用户在 CuePad 里看这个对话，可能在手机上、也可能在电脑上，本机路径在手机上打不开。要他看的文件用 `\(command) show <文件…> --title <标题>…` 发到 CuePad，两边都能看；第一次用前先看 `\(command) show --help`。本机起的网页服务要他看，用 `\(command) live` 开在他 Mac 上。"
    }

    /// 路径里有空格等字符时 Agent 的 shell 会拆开它。
    static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) } ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
