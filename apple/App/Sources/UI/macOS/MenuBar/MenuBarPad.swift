#if os(macOS)
import CueStore
import SwiftUI

/// 菜单栏面板：Pi 状态（点开会话是它的详情，与侧栏同一份）+ 一张随手记的小稿纸；↩ 存为所选项目的卡片，⌘↩ 直接发出，⌥↩ 换行。
/// 资料库读到之前没有稿纸；读不出来时说明原因并给"重试"。
struct MenuBarPad: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var project: UUID?
    @FocusState private var focused: Bool

    private static let sessionLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let sessions = PiSessionState.inListOrder(services.pi.sessions.map {
                PiSessionState.live($0, hostID: services.hostID, projectID: workspace.sessionProjects[$0.id])
            }).prefix(Self.sessionLimit)
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(sessions, id: \.sessionID) { session in
                        PiSessionRow(
                            session: session, project: workspace.catalog?.project(session.projectID),
                            nameFont: .system(size: 13, weight: .medium), lineFont: .system(size: 11.5))
                            .sessionDetailRow(session.sessionID)
                    }
                }
            }
            if workspace.isLibraryReady {
                capture
            } else if let failure = workspace.catalogFailure {
                VStack(alignment: .leading, spacing: 8) {
                    Label("读不出资料库", systemImage: "exclamationmark.triangle").font(.system(size: 13, weight: .medium))
                    Text(failure).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                    Button("重试") { workspace.retryCatalog() }
                }
                .foregroundStyle(palette.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .frame(width: 360)
        .glass(in: .rect(cornerRadius: 22))
        .modifier(SessionDetailHost(arrowEdge: .leading))
        .onAppear {
            project = services.settings.currentProject
            focused = true
        }
        #if DEBUG
        // 截图演示：面板先于启动参数选好项目出现，这里跟上参数指定的项目
        .onChange(of: services.settings.currentProject) { _, current in
            if DebugScene.scene == "menubar" { project = current }
        }
        #endif
        .modifier(SessionProjectsTracker(workspace: workspace))
    }

    @ViewBuilder private var capture: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        TextField("记下想法…", text: $text, axis: .vertical)
                .accessibilityLabel("记下想法")
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineSpacing(4)
            .lineLimit(4...8)
            .focused($focused)
            .onSubmit(save)
            .foregroundStyle(palette.ink)
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .paper(radius: 12)
            .overlay(alignment: .bottomTrailing) {
                if let notice = workspace.notice {
                    Text(notice.text).font(.system(size: 11.5))
                        .foregroundStyle(notice.isError ? palette.failure : palette.ink3)
                        .padding(8)
                        .transition(.opacity)
                }
            }
            .animation(Motion.quick, value: workspace.notice)
        HStack(spacing: 8) {
            Menu {
                ForEach(workspace.catalog?.projects ?? []) { item in Button(item.name) { project = item.id } }
                Button("未归档") { project = nil }
            } label: {
                // 看得出能点：图标 + 名称 + 上下箭头，按下有反馈
                HStack(spacing: 5) {
                    ProjectGlyph(project: current, size: 12)
                    Text(current?.name ?? "未归档").lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).accessibilityHidden(true)
                }
                .padding(.horizontal, 8).frame(height: 26)
                .background(.primary.opacity(0.06), in: .capsule)
                .contentShape(.capsule)
            }
            .menuStyle(.button).buttonStyle(PressStyle()).menuIndicator(.hidden).fixedSize()
            .foregroundStyle(.primary)
            .accessibilityLabel("记入 \(current?.name ?? "未归档")")
            Spacer()
            if !empty {
                Button("↩ 存为卡片", action: save).buttonStyle(PressStyle()).foregroundStyle(.secondary).fixedSize()
                    .transition(.opacity)
                SendControl(project: project, compact: true) { send($0) }
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
        .font(.system(size: 12))
        .animation(Motion.snappy, value: empty)
    }

    private var current: Project? { workspace.catalog?.project(project) }

    private func save() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        text = ""
        let project = project
        workspace.attempt { _ = try await workspace.createCard(body: body, in: project) }
    }

    private func send(_ choice: AppServices.Destination) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Task { if await workspace.send(body, via: choice) { text = "" } }
    }
}
#endif
