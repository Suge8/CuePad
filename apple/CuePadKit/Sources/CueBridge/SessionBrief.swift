#if os(macOS)
import Foundation

public enum SessionBrief {
    public static func text(cuepad: URL) -> String {
        let command = shellQuoted(cuepad.path)
        return "用户在 CuePad 里看这个对话，可能在手机上、也可能在电脑上，本机路径在手机上打不开。要他看的文件用 `\(command) show <文件…> --title <标题>…` 发到 CuePad，两边都能看；第一次用前先看 `\(command) show --help`。本机起的网页服务要他看，用 `\(command) live` 开在他 Mac 上（手机与 Mac 在同一个网络时也看得到），开着的页面你也能自己看、点，见 `\(command) live --help`。iOS 模拟器里跑着的应用要他看、上手试，用 `\(command) live sim`；你在做的 Mac 应用用 `\(command) live app`。别的会话可能也在这个项目里干活：动手前用 `\(command) task list` 看哪些任务已有会话在做（列表里标着 ← 会话「…」在做），不重复做；接下一件任务就 `\(command) task start <id>` 认领。任务由他在 CuePad 里点完成，或由 Cue 判定做完；他点完成时，在做这件任务的会话没别的任务就跟着休眠。他随手记的想法是灵感，用 `\(command) search` 查。"
    }

    static func shellQuoted(_ path: String) -> String {
        path.allSatisfy { $0.isLetter || $0.isNumber || "/._-+".contains($0) } ? path : "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
