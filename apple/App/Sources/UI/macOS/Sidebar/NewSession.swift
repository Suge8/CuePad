#if os(macOS)
import CueStore
import SwiftUI

/// Agent 分组标题旁与 Agent 整页右上的 +：在本机后台开一个新会话（窗口内浮层，同其他弹层；系统 popover 从页面右侧的 + 弹出时会伸到窗口外）。
/// 开好后关掉表单、在内容区打开新会话的整页。
struct NewSessionButton: View {
    @Binding var showing: Bool
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("新会话", systemImage: "plus") { showing = true }
            .labelStyle(.iconOnly).buttonStyle(.borderless)
            .help("开一个新的 Agent 会话")
            .panel(isPresented: $showing) {
                NewSessionForm { id in
                    showing = false
                    workspace.show(.session(id))
                }
            }
    }
}

/// 新会话开在哪：只列项目（项目目录的顺序）；目录只由项目绑定推出，没绑文件夹的项目也列，选中时就地选文件夹。
struct NewSessionForm: View {
    let opened: (String) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var chosen: String?
    @State private var prompt = ""
    @State private var stage = Stage.idle

    private enum Stage: Equatable {
        case idle
        /// 请求发出，等这台 Mac 启动 Pi。
        case opening
        /// Pi 已启动，等它连上（连上后表单关掉、打开新会话）。
        case connecting
        case failed(String)
    }

    private static let width: CGFloat = 340
    private static let listHeight: CGFloat = 240

    var body: some View {
        let places = ProjectFolders.launchPlaces(
            projects: workspace.catalog?.projects ?? [], bindings: workspace.catalog?.bindings ?? [], host: workspace.localHost)
        // 没选过时默认当前项目
        let place = places.first { $0.id == chosen } ?? places.first { $0.project.id == workspace.currentProject } ?? places.first
        VStack(alignment: .leading, spacing: 12) {
            Text("新会话").font(Typography.bodyStrong).foregroundStyle(palette.ink)
            if places.isEmpty {
                Text("还没有项目：先新建一个项目，再给它选文件夹，就能在里面开会话。")
                    .font(Typography.secondary).foregroundStyle(palette.ink3).fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 2) { ForEach(places) { row($0, selected: $0.id == place?.id) } }
                }
                .frame(maxHeight: Self.listHeight).fixedSize(horizontal: false, vertical: true)
                TextField("开场的话（可不填）", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...5)
                    .onSubmit { if let place, place.binding != nil, stage != .opening { start(place) } }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .paper(radius: 10)
                    .accessibilityLabel("开场的话")
            }
            HStack(spacing: 8) {
                switch stage {
                case .idle:
                    Text(place.map { $0.binding == nil ? "「\($0.project.name)」还没有文件夹" : "在后台开，不占终端" } ?? "在后台开，不占终端")
                        .font(Typography.meta).foregroundStyle(palette.ink3)
                case .opening:
                    Spinner(.small)
                    Text("正在开…").font(Typography.meta).foregroundStyle(palette.ink3)
                case .connecting:
                    Spinner(.small)
                    Text("等 Agent 连上…").font(Typography.meta).foregroundStyle(palette.ink3)
                case .failed(let reason):
                    Text(reason).font(Typography.meta).foregroundStyle(palette.failure).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let place, place.binding == nil {
                    // 选好文件夹后项目目录刷新，这一处就换成"开始"
                    Button("选文件夹…") { workspace.chooseFolder(for: place.project) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    // ↩ 开始（浮层开着时 ⌘ 组合键只交给主菜单，⌘↩ 到不了这里），换行用 ⌥↩
                    Button("开始") { place.map(start) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(place == nil || stage == .opening)
                }
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: Self.width)
        .background(palette.desk)
    }

    private func row(_ place: ProjectFolders.LaunchPlace, selected: Bool) -> some View {
        Button { chosen = place.id } label: {
            HStack(spacing: 8) {
                ProjectGlyph(project: place.project, size: 13)
                Text(place.project.name).foregroundStyle(place.binding == nil ? palette.ink2 : palette.ink).lineLimit(1)
                if place.binding == nil {
                    Image(systemName: "folder.badge.questionmark").font(Typography.meta).foregroundStyle(palette.ink3)
                        .help("还没有文件夹").accessibilityLabel("还没有文件夹")
                }
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark").foregroundStyle(palette.ink2).accessibilityHidden(true) }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(selected ? palette.selection : .clear, in: .rect(cornerRadius: 7))
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.98))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func start(_ place: ProjectFolders.LaunchPlace) {
        stage = .opening
        let words = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                let id = try await workspace.startSession(
                    in: place.project.id, prompt: words.isEmpty ? nil : words, title: place.project.name) { stage = .connecting }
                stage = .idle
                opened(id)
            } catch {
                stage = .failed(error.localizedDescription)
            }
        }
    }
}
#endif
