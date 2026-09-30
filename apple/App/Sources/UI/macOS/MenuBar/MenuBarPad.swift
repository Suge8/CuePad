#if os(macOS)
import CueStore
import SwiftUI

/// 菜单栏面板：Pi 状态 + 一张随手记的小稿纸；↩ 存为所选项目的卡片，⌘↩ 直接发出，⌥↩ 换行。
struct MenuBarPad: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var project: UUID?
    @State private var projects: [Project]?
    @FocusState private var focused: Bool

    private static let sessionLimit = 4

    var body: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: 12) {
            let sessions = services.pi.sessions.prefix(Self.sessionLimit)
            if !sessions.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(sessions) { session in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 8) {
                                PiDot(state: session.state, size: 6).frame(width: 12)
                                Text(Workspace.sessionName(session)).font(.system(size: 13, weight: .medium))
                                Spacer()
                                Text(session.state.label).font(.system(size: 12))
                                    .foregroundStyle(session.state.needsAttention ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            }
                            PiDetail(state: session.state, size: 11.5).padding(.leading, 20)
                        }
                    }
                }
            }
            TextField("记下想法…", text: $text, axis: .vertical)
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
                            .foregroundStyle(notice.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .padding(8)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.quick, value: workspace.notice)
            HStack(spacing: 8) {
                Menu {
                    ForEach(projects ?? []) { item in Button(item.name) { project = item.id } }
                    Button("未归档") { project = nil }
                } label: {
                    HStack(spacing: 4) {
                        ProjectGlyph(project: current, size: 12)
                        Text(current?.name ?? "未归档").lineLimit(1)
                    }
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .foregroundStyle(.secondary)
                Spacer()
                Button("↩ 存为卡片", action: save).buttonStyle(PressStyle()).foregroundStyle(.secondary).disabled(empty).fixedSize()
                SendControl(project: project, compact: true, disabled: empty) { send($0) }
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 360)
        .glass(in: .rect(cornerRadius: 22))
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
        .observing(services.store, [.projects], into: $projects) { try $0.projects() }
        .observing(services.store, [.projectDirectories], into: directories) { try $0.projectDirectories() }
    }

    private var current: Project? { projects?.first { $0.id == project } }

    private var directories: Binding<[UUID: String]?> {
        Binding(get: { workspace.directories }, set: { workspace.directories = $0 })
    }

    private func save() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        text = ""
        let project = project
        workspace.attempt { _ = try await workspace.createCard(body: body, in: project) }
    }

    private func send(_ choice: SendChoice) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        Task { if await workspace.send(body, via: choice) { text = "" } }
    }
}
#endif
