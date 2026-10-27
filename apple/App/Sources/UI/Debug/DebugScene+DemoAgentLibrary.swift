#if DEBUG
import CueStore
import Foundation

extension DebugScene {
    /// 演示的技能与规则（配 `-CuePadDemo YES`）：手机上看的是演示的 Mac Studio 报来的快照（各家都接了，`seedMacAgents`），这里替它写一份；
    /// Mac 上看的是本机照文件扫出的（`AgentLibraryKeeper`），这里把同一套内容写成隔离目录里的文件（`seedAgentFiles`）。
    /// 默认是该整理的样子（散落的、Claude Code 读不到的、空目录、同名的、格式不对的、另写了一份的全局规则）；`-CuePadAgentLibrary clean` 是整理好了的样子。
    static func seedAgentLibrary(_ services: AppServices) async throws {
        #if os(macOS)
        try seedAgentFiles()
        #endif
        let store = services.store
        let projects = try await store.projects()
        func project(_ name: String) -> UUID? { projects.first { $0.name == name }?.id }
        let host = "demo-mac"
        let clean = defaults.string(forKey: "CuePadAgentLibrary") == "clean"
        let library = DemoAgentLibrary(
            home: String(DemoLibrary.demoHome.dropLast()), clean: clean,
            cuepad: project("CuePad"), atlas: project(String(localized: "圆桌", table: "Demo")),
            homepage: project(String(localized: "个人网站", table: "Demo"))
        )
        _ = try await store.recordAgentLibrary(library.library(host: host), texts: library.texts)
    }
}

struct DemoAgentLibrary {
    let home: String
    let clean: Bool
    let cuepad: UUID?
    let atlas: UUID?
    let homepage: UUID?

    private var root: String { home + "/.agents/skills" }
    private func ago(_ hours: Double) -> Date { .now.addingTimeInterval(-hours * 3600) }

    func library(host: String) -> AgentLibrary {
        AgentLibrary(
            hostID: host, home: home, skills: skills.map(\.skill), instructions: instructions.map(\.instruction), tidies: clean ? [] : tidies,
            selfManaged: [SelfManagedSkills(agent: .claudeCode, count: 13), SelfManagedSkills(agent: .codex, count: 5)],
            agents: [.pi, .claudeCode, .codex], modifiedAt: .now)
    }

    /// 各份文件的正文（`LibraryFileText`）：列出的技能与规则，加合并要比的各家那几份。
    var texts: [String: String] {
        var texts: [String: String] = [:]
        for (skill, text) in skills { texts[skill.textPath] = text }
        for (instruction, text) in instructions { texts[instruction.path] = text }
        texts[home + "/.claude/CLAUDE.md"] = Self.claudeRules
        texts[home + "/Project/homepage/CLAUDE.md"] = Self.homepageClaude
        return texts
    }

    private static func skill(
        _ name: String, _ scope: LibraryScope, group: String = "", path: String, text: String, problem: SkillProblem? = nil, unseenBy: [AgentKind] = []
    ) -> (skill: LibrarySkill, text: String) {
        let skill = LibrarySkill(
            name: name, scope: scope, group: group, path: path, description: SkillDocument(text).description ?? "", hash: LibraryEdit.base(of: text),
            problem: problem, unseenBy: unseenBy)
        return (skill, text)
    }

    private func instruction(
        _ kind: LibraryInstruction.Kind, _ path: String, text: String?, hours: Double?, readers: [AgentKind] = [], links: [String] = []
    ) -> (instruction: LibraryInstruction, text: String?) {
        (LibraryInstruction(kind: kind, path: path, hash: text.map(LibraryEdit.base), modifiedAt: hours.map(ago), readers: readers, links: links), text)
    }

    private func source(_ origin: InstructionSource.Origin, _ path: String, _ text: String, hours: Double) -> InstructionSource {
        InstructionSource(origin: origin, path: path, hash: LibraryEdit.base(of: text), modifiedAt: ago(hours))
    }

    /// 演示的 Mac Studio 照手机发来的整理与改文件改它的快照（`-CuePadDemoMac YES`，`runDemoMac`）：整理了的那几件不在了（补上链接的各家都读得到，
    /// 去重留下的那份之外的不在了），文件照基准写（快照里已不是手机看到的那一版就退回"Mac 上刚改过"，同真的 Mac）。不是这两种请求为 nil。
    static func apply(_ request: DeliveryRequest, store: CueStore) async -> DeliveryOutcome? {
        do {
            return try await applying(request, store: store)
        } catch {
            return .failed(ShownText(error))
        }
    }

    private static func applying(_ request: DeliveryRequest, store: CueStore) async throws -> DeliveryOutcome? {
        guard request.tidyOrders != nil || request.libraryEdit != nil else { return nil }
        guard var library = try await store.agentLibrary(host: request.hostID) else { return .failed(ShownText(AgentLibraryError.tidyGone)) }
        let paths = library.skills.map(\.textPath) + library.instructions.map(\.path) + library.tidies.flatMap { $0.sources.map(\.path) }
        var texts = try await store.agentLibraryTexts(host: request.hostID, paths: paths)
        if let orders = request.tidyOrders {
            let ids = Set(orders.map(\.tidy))
            let kept = Set(orders.compactMap(\.keep))
            let dropped = library.tidies.filter { ids.contains($0.id) }.flatMap { tidy -> [String] in
                if case .duplicate(_, let copies) = tidy.kind { copies.map(\.path).filter { !kept.contains($0) } } else { [] }
            }
            library.tidies.removeAll { ids.contains($0.id) }
            for skill in library.skills where dropped.contains(skill.path) { texts[skill.textPath] = nil }
            library.skills.removeAll { dropped.contains($0.path) }
            if ids.contains("unlinked/claude") {
                library.skills = library.skills.map {
                    LibrarySkill(name: $0.name, scope: $0.scope, group: $0.group, path: $0.path, description: $0.description, hash: $0.hash, problem: $0.problem)
                }
            }
        }
        if let edit = request.libraryEdit {
            guard let entry = library.file(edit.file) else { return .failed(ShownText(AgentLibraryError.gone)) }
            guard LibraryEdit.base(of: entry.hash == nil ? nil : texts[entry.textPath]) == edit.base else {
                return .failed(ShownText(AgentLibraryError.changedOnMac))
            }
            texts[entry.textPath] = edit.text
            let hash = LibraryEdit.base(of: edit.text)
            switch edit.file {
            case .instruction(let kind):
                let index = library.instructions.firstIndex { $0.kind == kind }!
                let old = library.instructions[index]
                library.instructions[index] = LibraryInstruction(
                    kind: old.kind, path: old.path, hash: hash, modifiedAt: .now, readers: old.readers, links: old.links)
            case .skill(let path):
                let index = library.skills.firstIndex { $0.path == path }!
                let old = library.skills[index]
                library.skills[index] = LibrarySkill(
                    name: old.name, scope: old.scope, group: old.group, path: old.path, description: SkillDocument(edit.text).description ?? "",
                    hash: hash, modifiedAt: .now, unseenBy: old.unseenBy)
            }
        }
        _ = try await store.recordAgentLibrary(library, texts: texts)
        return .succeeded
    }

    /// 画面直接打开的那份文件（`-CuePadScene instruction|skill|duplicate`）：全局规则（给了项目是它的规则）、write-swift、同名的全局 release。
    static func file(scene: String, project: UUID?) -> LibraryFile? {
        #if os(macOS)
        let root = (ProcessInfo.processInfo.environment["CUEPAD_AGENTS_DIR"] ?? "") + "/skills"
        #else
        let root = DemoLibrary.demoHome + ".agents/skills"
        #endif
        return switch scene {
        case "instruction": .instruction(project.map(LibraryInstruction.Kind.project) ?? .global)
        case "skill": .skill(root + "/development/write-swift")
        case "duplicate": .skill(root + "/release")
        default: nil
        }
    }

    // MARK: 技能

    static let global: [(group: String, name: String, description: String)] = [
        ("creative", "copywriting", String(localized: "写落地页、发布说明与商店文案", table: "Demo")),
        ("creative", "gpt-image", String(localized: "生成插图、海报与图标", table: "Demo")),
        ("creative", "video", String(localized: "剪产品演示短片", table: "Demo")),
        ("development", "better-test", String(localized: "验证改动，只留覆盖用户可见行为的测试", table: "Demo")),
        ("development", "pr", String(localized: "写 PR 描述", table: "Demo")),
        ("development", "prototype", String(localized: "做原型回答设计问题", table: "Demo")),
        ("development", "write-swift", String(localized: "Swift 6.2 的并发规则与新写法", table: "Demo")),
        ("development", "writing-for-agents", String(localized: "写给 Agent 读的文档", table: "Demo")),
        ("frontend", "ui-craft", String(localized: "新建、打磨或审查界面", table: "Demo")),
        ("frontend", "ui-picks", String(localized: "按场景挑可移植的界面组件", table: "Demo")),
        ("operations", "better-browser-use", String(localized: "操作与调试网页", table: "Demo")),
        ("operations", "ssh", String(localized: "连服务器执行命令、传文件", table: "Demo")),
        ("workflow", "implement", String(localized: "实现一张工单并逐条实测", table: "Demo")),
        ("workflow", "research", String(localized: "找一手资料调查问题", table: "Demo")),
        ("", "web-search", String(localized: "联网搜索与取正文", table: "Demo")),
    ]

    /// SKILL.md 的样子（同 `seedAgentFiles` 写出的）。
    static func skillText(_ name: String, _ description: String) -> String {
        "---\nname: \(name)\ndescription: \(description)\n---\n\n\(description)\n"
    }

    private var skills: [(skill: LibrarySkill, text: String)] {
        var global = Self.global.map { item in
            Self.skill(
                item.name, .global, group: item.group, path: item.group.isEmpty ? "\(root)/\(item.name)" : "\(root)/\(item.group)/\(item.name)",
                text: Self.skillText(item.name, item.description), unseenBy: !clean && item.name == "write-swift" ? [.claudeCode] : [])
        }
        if !clean {
            global.append(Self.skill("release", .global, path: root + "/release", text: Self.globalRelease))
            global.append(Self.skill("uilane", .global, group: "operations", path: root + "/operations/uilane", text: Self.uilane, problem: .unreadable))
        }
        var project: [(skill: LibrarySkill, text: String)] = []
        if let cuepad {
            project += Self.cuepadSkills.map {
                Self.skill($0.0, .project(cuepad), path: "\(home)/Project/cuepad/.agents/skills/\($0.0)", text: Self.skillText($0.0, $0.1))
            }
            if !clean { project.append(Self.skill("release", .project(cuepad), path: Self.cuepadReleasePath(home), text: Self.cuepadRelease)) }
        }
        if let atlas {
            project.append(Self.skill(
                "load-test", .project(atlas), path: "\(home)/Project/atlas/.agents/skills/load-test",
                text: Self.skillText("load-test", Self.loadTest), unseenBy: clean ? [] : [.claudeCode]))
        }
        return global + project
    }

    static func cuepadReleasePath(_ home: String) -> String { home + "/Project/cuepad/.agents/skills/release" }
    static let uilane = String(localized: "# uilane\n\n界面泳道图。\n", table: "Demo")

    static let cuepadSkills = [
        ("xc", String(localized: "经 xc.sh 构建、测试与截图", table: "Demo")),
        ("release", String(localized: "签名、公证、发布新版本", table: "Demo")),
        ("strings", String(localized: "补齐界面的英文", table: "Demo")),
    ]
    static let loadTest = String(localized: "多 Agent 调度压测", table: "Demo")
    static let globalRelease = String(localized: "---\nname: release\ndescription: 发布新版本\n---\n\n打 tag，推送，等 CI 绿。", table: "Demo")
    static let cuepadRelease = String(
        localized: "---\nname: release\ndescription: 签名、公证、发布新版本\n---\n\n只在干净检出运行 xc.sh release。\n\n公证完再推 appcast。", table: "Demo")

    // MARK: 规则

    static let cuepadRules = String(localized: "# CuePad\n\nSwift 原生应用。构建、测试、截图只经 apple/scripts/xc.sh。", table: "Demo")
    static let homepageRules = String(localized: "# 个人网站\n\nAstro 静态站，部署前先跑 pnpm build。", table: "Demo")
    static let homepageClaude = String(localized: "# 个人网站\n\n图片放 public/img，用 webp。", table: "Demo")

    static let sharedRules = String(localized: """
        # 原则

        用当下最新最轻的做法，代码、文档、测试都是负债，每一行都要有理由。

        # 协作

        先查代码与一手资料再下结论；用户的说法和自己的记忆都要验证。

        # 回复

        默认中文，删去客套与重复。
        """, table: "Demo")

    static let claudeRules = String(localized: """
        # 原则

        用当下最新最轻的做法，代码、文档、测试都是负债，每一行都要有理由。

        # Git

        不是自己创建的检出里不用 reset、stash、push --force。

        # 回复

        默认中文，删去客套与重复。
        """, table: "Demo")

    static let piSystem = String(localized: """
        你是 Pi Agent。

        # 原则

        用当下最新最轻的做法，代码、文档、测试都是负债，每一行都要有理由。

        # 工具

        互不依赖的调用放在同一轮里并发完成。
        """, table: "Demo")

    private var instructions: [(instruction: LibraryInstruction, text: String?)] {
        let agents: [AgentKind] = [.pi, .claudeCode, .codex]
        var list = [
            instruction(
                .global, home + "/.agents/AGENTS.md", text: Self.sharedRules, hours: 26, readers: clean ? agents : [.pi, .codex],
                links: [home + "/.pi/agent/AGENTS.md", home + "/.codex/AGENTS.md"] + (clean ? [home + "/.claude/CLAUDE.md"] : [])),
            instruction(.piSystem, home + "/.pi/agent/SYSTEM.md", text: Self.piSystem, hours: 24 * 9, readers: [.pi]),
        ]
        if let cuepad {
            list.append(instruction(
                .project(cuepad), home + "/Project/cuepad/AGENTS.md", text: Self.cuepadRules, hours: 3, readers: agents,
                links: [home + "/Project/cuepad/CLAUDE.md"]))
        }
        if let atlas { list.append(instruction(.project(atlas), home + "/Project/atlas/AGENTS.md", text: nil, hours: nil)) }
        if let homepage {
            list.append(instruction(
                .project(homepage), home + "/Project/homepage/AGENTS.md", text: Self.homepageRules, hours: 24 * 4,
                readers: clean ? agents : [.pi, .codex], links: clean ? [home + "/Project/homepage/CLAUDE.md"] : []))
        }
        return list
    }

    // MARK: 该整理的

    private var tidies: [LibraryTidy] {
        let claude = home + "/.claude/skills"
        var list = [
            LibraryTidy(id: "stray", kind: .stray([
                SkillMove(skill: SkillEntry(name: "notion-export", scope: .global, path: claude + "/notion-export"), to: root + "/notion-export"),
                SkillMove(skill: SkillEntry(name: "pdf", scope: .global, path: claude + "/pdf"), to: root + "/pdf"),
            ])),
            LibraryTidy(id: "unlinked/claude", kind: .unlinked(agent: .claudeCode, skills:
                [SkillEntry(name: "write-swift", scope: .global, path: root + "/development/write-swift")]
                    + (atlas.map { [SkillEntry(name: "load-test", scope: .project($0), path: home + "/Project/atlas/.agents/skills/load-test")] } ?? []))),
        ]
        if let cuepad {
            list.append(LibraryTidy(id: "duplicate/release", kind: .duplicate(name: "release", copies: [
                SkillEntry(name: "release", scope: .global, path: root + "/release"),
                SkillEntry(name: "release", scope: .project(cuepad), path: Self.cuepadReleasePath(home)),
            ])))
        }
        list.append(LibraryTidy(id: "empty", kind: .empty([home + "/.codex/skills/codex-primary-runtime"])))
        list.append(LibraryTidy(id: "global-instructions", kind: .globalInstructions([
            source(.shared, home + "/.agents/AGENTS.md", Self.sharedRules, hours: 26),
            source(.agent(.claudeCode), home + "/.claude/CLAUDE.md", Self.claudeRules, hours: 24 * 2),
            source(.piSystem, home + "/.pi/agent/SYSTEM.md", Self.piSystem, hours: 24 * 9),
        ])))
        if let homepage {
            let folder = home + "/Project/homepage"
            list.append(LibraryTidy(id: "project-claude/\(homepage.uuidString)", kind: .projectClaude(project: homepage, sources: [
                source(.shared, folder + "/AGENTS.md", Self.homepageRules, hours: 24 * 4),
                source(.agent(.claudeCode), folder + "/CLAUDE.md", Self.homepageClaude, hours: 24 * 20),
            ])))
        }
        return list
    }
}
#endif
