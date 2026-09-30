#if os(iOS)
import CueStore
import SwiftUI

/// 标签栏上方常驻的随手记栏：点一下打开随手记面板，记入当前位置（项目页记入该项目，其余进未归档）。
struct CaptureAccessory: View {
    @Environment(Navigation.self) private var navigation
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        Button { navigation.startCapture() } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil").accessibilityHidden(true)
                Text(placement == .inline ? "记一笔" : "记下想法…").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("随手记")
        .accessibilityHint(navigation.captureProject == nil ? "记入未归档" : "记入当前项目")
    }
}

/// 随手记面板：写一段文字存为卡片。位置默认来自打开它的页面，可以当场换。
struct CaptureSheet: View {
    let initialProject: UUID?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var text = ""
    @State private var project: UUID?
    @State private var projects: [Project]?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("记下想法…", text: $text, axis: .vertical)
                    .font(.body)
                    .lineLimit(4...12)
                    .focused($focused)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .paper(radius: 14)
                Menu {
                    Button("未归档") { project = nil }
                    Divider()
                    ForEach(projects ?? []) { item in Button(item.name) { project = item.id } }
                } label: {
                    HStack(spacing: 6) {
                        Text("记入").foregroundStyle(.secondary)
                        ProjectGlyph(project: current, size: 13)
                        Text(current?.name ?? "未归档")
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).accessibilityHidden(true)
                    }
                    .font(.subheadline)
                    .frame(minHeight: 44)
                }
                .accessibilityLabel("记入 \(current?.name ?? "未归档")")
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(palette.desk)
            .navigationTitle("随手记")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("存为卡片", action: save)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            project = initialProject
            focused = true
        }
        .observing(services.store, [.projects], into: $projects) { try $0.projects() }
    }

    private var current: Project? { projects?.first { $0.id == project } }

    private func save() {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let project = project
        workspace.attempt {
            _ = try await workspace.createCard(body: body, in: project)
            workspace.say("已存为卡片")
        }
        dismiss()
    }
}
#endif
