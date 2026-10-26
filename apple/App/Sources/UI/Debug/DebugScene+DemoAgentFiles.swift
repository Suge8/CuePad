#if DEBUG && os(macOS)
import Foundation

extension DebugScene {
    /// 把演示的技能与说明写成文件，由本机照常扫（`AgentLibraryKeeper`）：只写进 `xc.sh` 给隔离实例换到库里的各家目录
    /// （`CUEPAD_AGENTS_DIR` 等，`app_env.py`），没换走（真实位置）就什么都不写。目录里已有东西就不再写（重开、整理过的样子留着）。
    /// 有要整理的样子：Claude Code 旧目录里两个技能、write-swift 没给 Claude Code 链上、uilane 没有名字与说明、Codex 技能目录里一个空目录、
    /// Claude Code 与 Pi 的系统提示各写一份全局规则；`-CuePadAgentLibrary clean` 时都已收好。
    static func seedAgentFiles() {
        let environment = ProcessInfo.processInfo.environment
        guard let sharedPath = environment["CUEPAD_AGENTS_DIR"], let claudePath = environment["CLAUDE_CONFIG_DIR"],
              let piPath = environment["PI_CODING_AGENT_DIR"], let codexPath = environment["CODEX_HOME"],
              sharedPath.contains("/.derived/")
        else { return }
        let shared = URL(filePath: sharedPath, directoryHint: .isDirectory)
        guard !FileManager.default.fileExists(atPath: shared.appending(path: "skills").path) else { return }
        let claude = URL(filePath: claudePath, directoryHint: .isDirectory)
        let pi = URL(filePath: piPath, directoryHint: .isDirectory)
        let codex = URL(filePath: codexPath, directoryHint: .isDirectory)
        let clean = defaults.string(forKey: "CuePadAgentLibrary") == "clean"
        let skills = shared.appending(path: "skills")

        func write(_ text: String, _ file: URL) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        func link(_ file: URL, to target: URL) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.createSymbolicLink(atPath: file.path, withDestinationPath: relative(target, from: file.deletingLastPathComponent()))
        }
        func skill(_ name: String, _ description: String, in directory: URL) {
            write("---\nname: \(name)\ndescription: \(description)\n---\n\n\(description)\n", directory.appending(path: "\(name)/SKILL.md"))
        }

        for item in DemoAgentLibrary.global {
            let directory = item.group.isEmpty ? skills : skills.appending(path: item.group)
            skill(item.name, item.description, in: directory)
            if clean || item.name != "write-swift" { link(claude.appending(path: "skills/\(item.name)"), to: directory.appending(path: item.name)) }
        }
        write(DemoAgentLibrary.sharedRules, shared.appending(path: "AGENTS.md"))
        for file in [pi.appending(path: "AGENTS.md"), codex.appending(path: "AGENTS.md")] { link(file, to: shared.appending(path: "AGENTS.md")) }
        write(DemoAgentLibrary.piSystem, pi.appending(path: "SYSTEM.md"))
        if clean {
            link(claude.appending(path: "CLAUDE.md"), to: shared.appending(path: "AGENTS.md"))
            return
        }
        write(DemoAgentLibrary.claudeRules, claude.appending(path: "CLAUDE.md"))
        skill("notion-export", String(localized: "把 Notion 页面导出成 Markdown", table: "Demo"), in: claude.appending(path: "skills"))
        skill("pdf", String(localized: "读写与合并 PDF", table: "Demo"), in: claude.appending(path: "skills"))
        write(String(localized: "# uilane\n\n界面泳道图。\n", table: "Demo"), skills.appending(path: "operations/uilane/SKILL.md"))
        try? FileManager.default.createDirectory(at: codex.appending(path: "skills/codex-primary-runtime"), withIntermediateDirectories: true)
    }

    /// 从 `directory` 到 `target` 的相对路径（两者都是绝对路径）：链接跟着整个隔离库搬也不断。
    private static func relative(_ target: URL, from directory: URL) -> String {
        let from = directory.standardizedFileURL.pathComponents, to = target.standardizedFileURL.pathComponents
        let common = zip(from, to).prefix { $0 == $1 }.count
        return (Array(repeating: "..", count: from.count - common) + to.dropFirst(common)).joined(separator: "/")
    }
}
#endif
