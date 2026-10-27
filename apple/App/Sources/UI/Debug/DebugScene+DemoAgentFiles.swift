#if DEBUG && os(macOS)
import CuePi
import CueStore
import Foundation

extension DebugScene {
    /// 把演示的技能与规则写成文件，由本机照常扫（`AgentLibraryKeeper`）：只写进 `xc.sh` 给隔离实例换到库里的各家目录
    /// （`CUEPAD_AGENTS_DIR` 等，`app_env.py`）与演示项目绑的文件夹（`DemoLibrary.demoHome`，也在隔离库里），没换走（真实位置）就什么都不写。
    /// 目录里已有东西就不再写（重开、整理过的样子留着）。
    /// 该整理的样子：Claude Code 旧目录里两个技能、write-swift 与圆桌的 load-test 没给 Claude Code 补上链接、全局与 CuePad 各有一个 release、
    /// uilane 没有名字与说明、Codex 技能目录里一个空目录、Claude Code 与 Pi 的系统提示各写一份全局规则、个人网站另有一份不同的 CLAUDE.md；
    /// `-CuePadAgentLibrary clean` 时都已收好。
    static func seedAgentFiles() {
        let environment = ProcessInfo.processInfo.environment
        guard let sharedPath = environment["CUEPAD_AGENTS_DIR"], let claudePath = environment[AgentKind.claudeCode.facts.homeVariable],
              let piPath = environment[AgentKind.pi.facts.homeVariable], let codexPath = environment[AgentKind.codex.facts.homeVariable],
              let library = environment[LibraryLocation.environmentKey], sharedPath.hasPrefix(library + "/"),
              DemoLibrary.demoHome.hasPrefix(library + "/")
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
            write(DemoAgentLibrary.skillText(name, description), directory.appending(path: "\(name)/SKILL.md"))
        }

        for item in DemoAgentLibrary.global {
            let directory = item.group.isEmpty ? skills : skills.appending(path: item.group)
            skill(item.name, item.description, in: directory)
            if clean || item.name != "write-swift" { link(claude.appending(path: "skills/\(item.name)"), to: directory.appending(path: item.name)) }
        }
        let projects = URL(filePath: DemoLibrary.demoHome, directoryHint: .isDirectory).appending(path: "Project")
        let cuepad = projects.appending(path: "cuepad"), atlas = projects.appending(path: "atlas"), homepage = projects.appending(path: "homepage")
        write(DemoAgentLibrary.cuepadRules, cuepad.appending(path: "AGENTS.md"))
        link(cuepad.appending(path: "CLAUDE.md"), to: cuepad.appending(path: "AGENTS.md"))
        for (name, description) in DemoAgentLibrary.cuepadSkills where clean || name != "release" {
            skill(name, description, in: cuepad.appending(path: ".agents/skills"))
            link(cuepad.appending(path: ".claude/skills/\(name)"), to: cuepad.appending(path: ".agents/skills/\(name)"))
        }
        skill("load-test", DemoAgentLibrary.loadTest, in: atlas.appending(path: ".agents/skills"))
        if clean { link(atlas.appending(path: ".claude/skills/load-test"), to: atlas.appending(path: ".agents/skills/load-test")) }
        write(DemoAgentLibrary.homepageRules, homepage.appending(path: "AGENTS.md"))
        write(DemoAgentLibrary.sharedRules, shared.appending(path: "AGENTS.md"))
        for file in [pi.appending(path: "AGENTS.md"), codex.appending(path: "AGENTS.md")] { link(file, to: shared.appending(path: "AGENTS.md")) }
        write(DemoAgentLibrary.piSystem, pi.appending(path: "SYSTEM.md"))
        if clean {
            link(claude.appending(path: "CLAUDE.md"), to: shared.appending(path: "AGENTS.md"))
            link(homepage.appending(path: "CLAUDE.md"), to: homepage.appending(path: "AGENTS.md"))
            return
        }
        write(DemoAgentLibrary.homepageClaude, homepage.appending(path: "CLAUDE.md"))
        write(DemoAgentLibrary.cuepadRelease, cuepad.appending(path: ".agents/skills/release/SKILL.md"))
        link(cuepad.appending(path: ".claude/skills/release"), to: cuepad.appending(path: ".agents/skills/release"))
        write(DemoAgentLibrary.globalRelease, skills.appending(path: "release/SKILL.md"))
        link(claude.appending(path: "skills/release"), to: skills.appending(path: "release"))
        write(DemoAgentLibrary.claudeRules, claude.appending(path: "CLAUDE.md"))
        skill("notion-export", String(localized: "把 Notion 页面导出成 Markdown", table: "Demo"), in: claude.appending(path: "skills"))
        skill("pdf", String(localized: "读写与合并 PDF", table: "Demo"), in: claude.appending(path: "skills"))
        write(DemoAgentLibrary.uilane, skills.appending(path: "operations/uilane/SKILL.md"))
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
