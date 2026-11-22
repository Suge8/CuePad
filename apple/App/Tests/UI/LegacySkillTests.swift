#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct LegacySkillTests {
    private struct Places {
        let app: TestApp
        var agents: URL { app.directory.appending(path: "agents") }
        var skill: URL { agents.appending(path: "skills/cuepad/SKILL.md") }
        var claudeLink: URL { app.directory.appending(path: "claude/skills/cuepad") }
        nonisolated static let hosted = "6f1c0d2e-0000-4000-8000-000000000002", terminal = "6f1c0d2e-0000-4000-8000-000000000001"

        func write(_ text: String) throws {
            try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: skill, atomically: true, encoding: .utf8)
        }

        func linkClaude() throws {
            try FileManager.default.createDirectory(at: claudeLink.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(atPath: claudeLink.path, withDestinationPath: "../../agents/skills/cuepad")
        }

        func claudeSessions() async throws {
            let project = app.directory.appending(path: "claude/projects/-work-x")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            for id in [Self.hosted, Self.terminal] {
                let stamp = "2026-10-14T01:00:00.000Z"
                let lines = [
                    #"{"type":"user","uuid":"u1","sessionId":"\#(id)","cwd":"/work/x","timestamp":"\#(stamp)","message":{"role":"user","content":"修一下登录"}}"#,
                    #"{"type":"assistant","uuid":"a1","sessionId":"\#(id)","cwd":"/work/x","timestamp":"\#(stamp)","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"修好了"}]}}"#,
                ]
                try (lines.joined(separator: "\n") + "\n").write(to: project.appending(path: "\(id).jsonl"), atomically: true, encoding: .utf8)
            }
            let recorder = app.services.stateRecorder
            try await recorder.update(sessionID: Self.hosted, state: .settled, launchToken: "launch-1", hosted: true, agent: .claudeCode)
            try await recorder.end(sessionID: Self.hosted)
        }

        func launch() async throws -> Set<String> {
            app.services.start()
            let store = app.services.store
            _ = try await eventually(store, { try $0.chatMessages(of: Self.hosted) }) { !$0.isEmpty }
            return Set(try await store.indexedSessions().filter { $0.agent == .claudeCode }.map(\.id))
        }
    }

    private func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

    @Test func 启动时旧技能记着的接入进设置_终端里的会话照读_技能文件与链接删掉() async throws {
        let app = TestApp(), places = Places(app: app)
        try places.write("---\nname: cuepad\n---\n怎么发预览……\n<!-- 由 CuePad 写入（接入：pi, claude, someday），升级时整文件覆盖 -->\n")
        try places.linkClaude()
        let notes = app.directory.appending(path: "claude/skills/notes.md")
        try "用户自己的".write(to: notes, atomically: true, encoding: .utf8)
        try await places.claudeSessions()
        defer { app.services.cancelBackgroundWork() }

        _ = try await places.launch()

        #expect(app.services.settings.connectedAgents == [.pi, .claudeCode], "不认识的家略去")
        _ = try await eventually(app.services.store, { Set(try $0.indexedSessions().filter { $0.agent == .claudeCode }.map(\.id)) }) {
            $0 == [Places.hosted, Places.terminal]
        }
        #expect(!exists(places.skill) && !exists(places.claudeLink))
        #expect(!exists(places.agents), "因此变空的目录一并删掉")
        #expect(exists(notes), "Claude Code 技能目录里别的不动")
        #expect(AppSettings(defaults: app.preferences.reopened(), launchArguments: [:]).connectedAgents == [.pi, .claudeCode], "记在设置里，重开还在")
    }

    enum Foreign: String, CaseIterable, Sendable {
        case ownText, unreadable, onlyLink
    }

    @Test(arguments: Foreign.allCases)
    func 不是CuePad写的同名文件不碰_也不算接入(_ foreign: Foreign) async throws {
        let app = TestApp(), places = Places(app: app)
        switch foreign {
        case .ownText:
            try places.write("---\nname: cuepad\n---\n我自己的\n")
        case .unreadable:
            try places.write("<!-- 由 CuePad 写入（接入：claude），升级时整文件覆盖 -->\n")
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: places.skill.path)
        case .onlyLink:
            try places.linkClaude()
        }
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: places.skill.path) }
        try await places.claudeSessions()
        defer { app.services.cancelBackgroundWork() }

        #expect(try await places.launch() == [Places.hosted], "终端里开的不读")
        #expect(app.services.settings.connectedAgents.isEmpty)
        #expect(exists(places.skill) == (foreign != .onlyLink))
        #expect(exists(places.claudeLink) == (foreign == .onlyLink))
    }
}
#endif
