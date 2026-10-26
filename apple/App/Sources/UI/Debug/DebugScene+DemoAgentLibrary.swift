#if DEBUG
import CueStore
import Foundation

extension DebugScene {
    /// 演示的技能与说明（配 `-CuePadDemo YES`）：手机上看的是演示的 Mac Studio 报来的快照（各家都接了，`seedMacAgents`），这里替它写一份；
    /// Mac 上看的是本机照文件扫出的（`AgentLibraryKeeper`），这里把同一套内容写成隔离目录里的文件（`seedAgentFiles`）。
    /// 默认是有要整理的样子（散落的、Claude Code 看不见的、同名的、格式不对的、各写一份的全局规则）；`-CuePadAgentLibrary clean` 是整理好了的样子。
    static func seedAgentLibrary(_ services: AppServices) async {
        #if os(macOS)
        seedAgentFiles()
        #endif
        let store = services.store
        let projects = (try? await store.projects()) ?? []
        func project(_ name: String) -> UUID? { projects.first { $0.name == name }?.id }
        let host = "demo-mac"
        let clean = defaults.string(forKey: "CuePadAgentLibrary") == "clean"
        let library = DemoAgentLibrary(
            home: String(DemoLibrary.demoHome.dropLast()), clean: clean,
            cuepad: project("CuePad"), atlas: project(String(localized: "圆桌", table: "Demo")),
            homepage: project(String(localized: "个人网站", table: "Demo"))
        ).library(host: host)
        _ = try? await store.recordAgentLibrary(library)
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
            hostID: host, home: home, skills: skills, instructions: instructions, tidies: clean ? [] : tidies,
            selfManaged: [SelfManagedSkills(agent: .claudeCode, count: 13), SelfManagedSkills(agent: .codex, count: 5)],
            agents: [.pi, .claudeCode, .codex], modifiedAt: .now)
    }

    /// 演示的 Mac Studio 照手机发来的整理与改说明改它的快照（`-CuePadDemoMac YES`，`runDemoMac`）：整理了的那几件不在了（链上了的各家都看得见），
    /// 说明照基准写（快照里已不是手机看到的那一版就退回"Mac 上刚改过"，同真的 Mac）。不是这两种请求为 nil。
    static func apply(_ request: DeliveryRequest, store: CueStore) async -> DeliveryOutcome? {
        guard request.tidyOrders != nil || request.instructionEdit != nil else { return nil }
        guard var library = try? await store.agentLibrary(host: request.hostID) else { return .failed(ShownText(AgentLibraryError.tidyGone)) }
        if let orders = request.tidyOrders {
            let ids = Set(orders.map(\.tidy))
            library.tidies.removeAll { ids.contains($0.id) }
            if ids.contains("unlinked") {
                library.skills = library.skills.map {
                    LibrarySkill(name: $0.name, description: $0.description, scope: $0.scope, group: $0.group, path: $0.path)
                }
            }
        }
        if let edit = request.instructionEdit {
            guard let index = library.instructions.firstIndex(where: { $0.kind == edit.instruction }), library.instructions[index].base == edit.base
            else { return .failed(ShownText(AgentLibraryError.changedOnMac)) }
            let old = library.instructions[index]
            library.instructions[index] = LibraryInstruction(
                kind: old.kind, path: old.path, text: edit.text, modifiedAt: .now, readers: old.readers, links: old.links)
        }
        _ = try? await store.recordAgentLibrary(library)
        return .succeeded
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

    private var skills: [LibrarySkill] {
        let global = Self.global.map { item in
            LibrarySkill(
                name: item.name, description: item.description, scope: .global, group: item.group,
                path: item.group.isEmpty ? "\(root)/\(item.name)" : "\(root)/\(item.group)/\(item.name)",
                unseenBy: !clean && item.name == "write-swift" ? [.claudeCode] : [])
        }
        var project: [LibrarySkill] = []
        if let cuepad {
            project += Self.cuepadSkills.map { LibrarySkill(name: $0.0, description: $0.1, scope: .project(cuepad), group: "", path: "\(home)/Project/cuepad/.agents/skills/\($0.0)") }
        }
        if let atlas {
            project.append(LibrarySkill(
                name: "load-test", description: Self.loadTest, scope: .project(atlas), group: "",
                path: "\(home)/Project/atlas/.agents/skills/load-test", unseenBy: clean ? [] : [.claudeCode]))
        }
        return global + project
    }

    static let cuepadSkills = [
        ("xc", String(localized: "经 xc.sh 构建、测试与截图", table: "Demo")),
        ("release", String(localized: "签名、公证、发布新版本", table: "Demo")),
        ("strings", String(localized: "补齐界面的英文", table: "Demo")),
    ]
    static let loadTest = String(localized: "多 Agent 调度压测", table: "Demo")
    static let globalRelease = String(localized: "---\nname: release\ndescription: 发布新版本\n---\n\n打 tag，推送，等 CI 绿。", table: "Demo")
    static let cuepadRelease = String(
        localized: "---\nname: release\ndescription: 签名、公证、发布新版本\n---\n\n只在干净检出运行 xc.sh release。\n\n公证完再推 appcast。", table: "Demo")

    // MARK: 说明

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

    private var instructions: [LibraryInstruction] {
        let agents: [AgentKind] = [.pi, .claudeCode, .codex]
        var list = [
            LibraryInstruction(
                kind: .global, path: home + "/.agents/AGENTS.md", text: Self.sharedRules, modifiedAt: ago(26),
                readers: clean ? agents : [.pi, .codex],
                links: [home + "/.pi/agent/AGENTS.md", home + "/.codex/AGENTS.md"] + (clean ? [home + "/.claude/CLAUDE.md"] : [])),
            LibraryInstruction(kind: .piSystem, path: home + "/.pi/agent/SYSTEM.md", text: Self.piSystem, modifiedAt: ago(24 * 9), readers: [.pi]),
        ]
        if let cuepad {
            list.append(LibraryInstruction(
                kind: .project(cuepad), path: home + "/Project/cuepad/AGENTS.md",
                text: Self.cuepadRules, modifiedAt: ago(3),
                readers: agents, links: [home + "/Project/cuepad/CLAUDE.md"]))
        }
        if let atlas {
            list.append(LibraryInstruction(kind: .project(atlas), path: home + "/Project/atlas/AGENTS.md", text: nil, modifiedAt: nil))
        }
        if let homepage {
            list.append(LibraryInstruction(
                kind: .project(homepage), path: home + "/Project/homepage/AGENTS.md",
                text: Self.homepageRules, modifiedAt: ago(24 * 4),
                readers: clean ? agents : [.pi, .codex], links: clean ? [home + "/Project/homepage/CLAUDE.md"] : []))
        }
        return list
    }

    // MARK: 要整理

    private var tidies: [LibraryTidy] {
        let claude = home + "/.claude/skills"
        var list = [
            LibraryTidy(id: "stray", kind: .stray([
                SkillMove(skill: SkillEntry(name: "notion-export", scope: .global, path: claude + "/notion-export"), to: root + "/notion-export"),
                SkillMove(skill: SkillEntry(name: "pdf", scope: .global, path: claude + "/pdf"), to: root + "/pdf"),
            ])),
            LibraryTidy(id: "unlinked", kind: .unlinked(
                [SkillEntry(name: "write-swift", scope: .global, path: root + "/development/write-swift")]
                    + (atlas.map { [SkillEntry(name: "load-test", scope: .project($0), path: home + "/Project/atlas/.agents/skills/load-test")] } ?? []))),
        ]
        if let cuepad {
            list.append(LibraryTidy(id: "duplicate/release", kind: .duplicate(name: "release", copies: [
                SkillCopy(skill: SkillEntry(name: "release", scope: .global, path: root + "/release"),
                          text: Self.globalRelease, modifiedAt: ago(24 * 30)),
                SkillCopy(skill: SkillEntry(name: "release", scope: .project(cuepad), path: home + "/Project/cuepad/.agents/skills/release"),
                          text: Self.cuepadRelease, modifiedAt: ago(5)),
            ])))
        }
        list.append(LibraryTidy(id: "malformed/" + root + "/operations/uilane", kind: .malformed(
            SkillEntry(name: "uilane", scope: .global, path: root + "/operations/uilane"), .unreadable)))
        list.append(LibraryTidy(id: "global-instructions", kind: .globalInstructions([
            InstructionSource(origin: .shared, path: home + "/.agents/AGENTS.md", text: Self.sharedRules, modifiedAt: ago(26)),
            InstructionSource(origin: .agent(.claudeCode), path: home + "/.claude/CLAUDE.md", text: Self.claudeRules, modifiedAt: ago(24 * 2)),
            InstructionSource(origin: .piSystem, path: home + "/.pi/agent/SYSTEM.md", text: Self.piSystem, modifiedAt: ago(24 * 9)),
        ])))
        if let homepage {
            let folder = home + "/Project/homepage"
            list.append(LibraryTidy(id: "project-claude/\(homepage.uuidString)", kind: .projectClaude(project: homepage, sources: [
                InstructionSource(origin: .shared, path: folder + "/AGENTS.md", text: Self.homepageRules, modifiedAt: ago(24 * 4)),
                InstructionSource(origin: .agent(.claudeCode), path: folder + "/CLAUDE.md", text: Self.homepageClaude, modifiedAt: ago(24 * 20)),
            ])))
        }
        return list
    }
}
#endif
