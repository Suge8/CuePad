#if DEBUG
import CueStore
import SwiftUI

/// `-CuePadScene rail -CuePadRailForm phone|wide|narrow`：正式会话条的隔离验收场景，默认 phone。
/// 写 15 个真实会话：两拍板、一待回复、一出错、各步态与子代理；不是 UI 假状态。不要配 CuePadDemo，使用新的隔离库。
/// 右侧只记组件发出的打开意图与系统拖放收到的会话 id；不调用 Workspace 导航。`-CuePadRailEmpty YES` 验空列占位。
struct DebugSessionRail: View {
    let workspace: Workspace
    @State private var event = "—"
    @Environment(\.palette) private var palette

    private var form: SessionRail.Form {
        switch DebugScene.defaults.string(forKey: "CuePadRailForm") {
        case "wide": .wide
        case "narrow": .narrow
        default: .phone
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SessionRail(data: workspace.services.liveSessions.rail, form: form, pulse: workspace.pulse) { session, opening in
                event = "\(opening == .leading ? "leading" : "primary"): \(session.sessionID)"
            }
            .frame(height: 650)
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "SessionRail · \(Int(form.width)) pt").font(Typography.bodyStrong)
                Text(verbatim: event).font(Typography.body).accessibilityIdentifier("rail-event")
                Color.clear.contentShape(.rect)
                    .dropDestination(for: DraggedSession.self) { items, _ in
                        guard let item = items.first else { return false }
                        event = "drop: \(item.sessionID)"
                        return true
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(palette.desk)
        .environment(workspace)
    }
}

extension DebugScene {
    static func seedRailIfAsked(_ services: AppServices) async {
        guard scene == "rail", !defaults.bool(forKey: "CuePadRailEmpty") else { return }
        await running("会话条验收数据") {
            let store = services.store, host = "rail-mac", boot = "rail-boot"
            try await store.recordMacPresence(host: host, bootID: boot) { true }
            _ = try await store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
            try await store.setCueState(.settled, hostID: host, bootID: boot)
            let recorder = PiStateRecorder(store: store, hostID: host, bootID: boot)
            let samples: [(String, AgentKind, PiWorkState)] = [
                ("notes-edit", .claudeCode, .waitingForUser), ("release", .codex, .waitingForUser), ("docs", .codex, .settled),
                ("billing", .opencode, .error), ("atlas", .pi, .tool), ("review", .codex, .delegating),
                ("cuepad", .claudeCode, .thinking), ("migrate", .pi, .compacting), ("homepage", .codex, .tool),
                ("scratch", .codex, .thinking), ("gateway", .claudeCode, .tool), ("keychain", .grok, .thinking),
                ("rename", .dsh, .compacting), ("relay", .pi, .thinking), ("landing-copy", .pi, .tool)
            ]
            for (index, sample) in samples.enumerated() {
                let (id, agent, state) = sample
                let start = Date.now.addingTimeInterval(Double(index - samples.count) * 60)
                let question = state == .waitingForUser
                    ? PiQuestion(promptID: nil, kind: .unknown("editor"), text: String(localized: "编辑提交说明", table: "Demo")) : nil
                let helpers = state == .delegating ? ["billing", "sync"].map {
                    PiSubagentState(name: $0, role: "review", phase: .known(.running), action: "", startedAt: start)
                } : []
                _ = try await recorder.update(
                    sessionID: id, state: state, failure: state == .error ? .quota : nil, title: id, directory: id, question: question,
                    times: PiTimes(stateSince: start, busySince: state.isWorking ? start : nil), subagents: helpers, agent: agent)
                try await store.writePiTranscript(PiTranscript(
                    sessionID: id, messages: [], recap: PiRecap(lastPrompt: "README", lastReply: state == .settled ? "README.md" : nil)))
            }
            try await store.leaveToYou("docs")
        }
    }
}
#endif
