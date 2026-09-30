#if os(iOS)
import CueStore
import SwiftUI

nonisolated private struct OutboxData: Sendable {
    var sessions: [PiSessionState]
    var projects: [UUID: Project]
}

/// 发到 Mac：选一个 Pi 会话与发送方式，写一条投送请求；随后在同一面板里看它从"等 Mac 接手"到送达或失败。
/// 关掉面板不影响投送，进度仍在活动页。
struct SendToMacSheet: View {
    let outbox: Navigation.Outbox
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var data: OutboxData?
    @State private var chosen: String?
    @State private var chosenMode: DeliveryMode?
    @State private var sentID: UUID?
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Group {
                if let sentID {
                    DeliveryProgress(id: sentID, retry: { self.sentID = nil }, close: { dismiss() })
                } else {
                    chooser
                }
            }
            .deskBackground()
            .navigationTitle("发到 Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        .presentationDetents([.large])
        .observing(services.store, [.piSessionStates, .projects], into: $data, onError: workspace.fail) { store in
            let order = try store.piSessionStates().sorted { $0.state.urgency > $1.state.urgency }
            return OutboxData(sessions: order, projects: Dictionary(uniqueKeysWithValues: try store.projects().map { ($0.id, $0) }))
        }
    }

    private var hasImages: Bool { !CardText(outbox.content).images.isEmpty }

    /// 选中的会话：用户选过的 → 预选的 → 卡片所在项目的 → 第一个。
    private var session: PiSessionState? {
        guard let sessions = data?.sessions else { return nil }
        for id in [chosen, outbox.session].compactMap({ $0 }) {
            if let match = sessions.first(where: { $0.sessionID == id }) { return match }
        }
        return sessions.first { $0.projectID != nil && $0.projectID == outbox.project } ?? sessions.first
    }

    private var modes: [DeliveryMode] {
        session.map { MacDelivery.modes(for: $0.state, hasImages: hasImages) } ?? []
    }

    /// 会话状态变了（比如开始干活）时，原来选的方式可能不再可用：换成当前可用的第一个。
    private var mode: DeliveryMode? {
        chosenMode.flatMap { modes.contains($0) ? $0 : nil } ?? modes.first
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭", systemImage: "xmark", role: .cancel) { dismiss() }
        }
        if sentID == nil {
            ToolbarItem(placement: .confirmationAction) {
                Button("发送", systemImage: "paperplane.fill", action: send)
                    .buttonStyle(.glassProminent)
                    .disabled(session == nil || mode == nil || sending)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    @ViewBuilder private var chooser: some View {
        Form {
            Section {
                ContentPreview(content: outbox.content)
            }
            if let data {
                if services.sync == nil { Section { SyncOffNote().listRowInsets(EdgeInsets()) } }
                if data.sessions.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "Mac 上没有运行中的 Pi 会话", systemImage: "terminal",
                            description: Text("在 Mac 上启动 Pi 后再试"))
                    }
                } else {
                    Section {
                        ForEach(data.sessions) { item in sessionRow(item, project: item.projectID.flatMap { data.projects[$0] }) }
                    } header: {
                        Text("Pi 会话")
                    }
                    if let mode, modes.count > 1 {
                        Section {
                            Picker("方式", selection: Binding(get: { mode }, set: { chosenMode = $0 })) {
                                ForEach(modes, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets())
                        } footer: {
                            Text(mode.explanation)
                        }
                    } else if let mode {
                        Section { } footer: { Text(mode.explanation) }
                    }
                }
            }
        }
    }

    private func sessionRow(_ item: PiSessionState, project: Project?) -> some View {
        Button {
            chosen = item.sessionID
        } label: {
            HStack(spacing: 12) {
                PiDot(state: item.state)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title).font(.body.weight(.medium)).foregroundStyle(palette.ink)
                        if project != nil, project?.id == outbox.project {
                            Text("本项目").font(.caption2.weight(.medium)).foregroundStyle(palette.ink2)
                                .padding(.horizontal, 6).padding(.vertical, 2).background(palette.fill, in: .capsule)
                        }
                    }
                    Text([project?.name, item.summary].compactMap { $0 }.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(item.state == .known(.waitingForUser) ? .orange : palette.ink3).lineLimit(1)
                }
                Spacer(minLength: 8)
                if item.sessionID == session?.sessionID {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(palette.ink)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(item.sessionID == session?.sessionID ? .isSelected : [])
    }

    private func send() {
        guard let session, let mode, !sending else { return }
        sending = true
        let content = outbox.content, card = outbox.card, task = outbox.task
        Task {
            defer { sending = false }
            do {
                let request = try await services.requestMacDelivery(content, to: session, mode: mode, card: card, task: task)
                withAnimation(Motion.quick) { sentID = request.id }
            } catch {
                workspace.fail(error)
            }
        }
    }
}

/// 要发的内容：标题、摘要、图片数。
private struct ContentPreview: View {
    let content: String
    @Environment(\.palette) private var palette

    var body: some View {
        let text = CardText(content)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(text.title.nonEmpty ?? "图片").font(.headline).foregroundStyle(palette.ink).lineLimit(2)
                if !text.preview.isEmpty { Text(text.preview).font(.footnote).foregroundStyle(palette.ink2).lineLimit(2) }
                if text.images.count > 0 {
                    Label("\(text.images.count) 张图片", systemImage: "photo").font(.caption).foregroundStyle(palette.ink3)
                }
            }
            Spacer(minLength: 0)
            if let image = text.images.first { Thumbnail(hash: image, height: 52, radius: 8).frame(width: 64) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// 请求的进度：跟随 Store 里那条请求的状态。送达后片刻自动关闭。
private struct DeliveryProgress: View {
    let id: UUID
    let retry: () -> Void
    let close: () -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var request: DeliveryRequest??

    private static let closeDelay: Duration = .seconds(1.2)

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            symbol
                .font(.system(size: 44, weight: .semibold))
                .frame(height: 56)
            Text(title).font(.title3.weight(.semibold)).foregroundStyle(palette.ink).multilineTextAlignment(.center)
            if let detail { Text(detail).font(.subheadline).foregroundStyle(palette.ink2).multilineTextAlignment(.center) }
            if status == .failed {
                HStack(spacing: 12) {
                    Button("关闭", action: close).buttonStyle(.bordered)
                    Button("重试", action: retry).buttonStyle(.glassProminent)
                }
                .padding(.top, 6)
            }
            Spacer()
            if status == .pending || status == .executing {
                Text("可以关掉，进度在「活动」里").font(.footnote).foregroundStyle(palette.ink3)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .animation(Motion.quick, value: status)
        .sensoryFeedback(trigger: status) { _, next in
            switch next {
            case .succeeded: .success
            case .failed: .error
            default: nil
            }
        }
        .accessibilityElement(children: .combine)
        .observing(services.store, [.deliveryRequests], id: id, into: $request, onError: workspace.fail) { [id] in
            try $0.deliveryRequest(id)
        }
        .task(id: status) {
            guard status == .succeeded else { return }
            try? await Task.sleep(for: Self.closeDelay)
            close()
        }
    }

    /// 请求被 Mac 清理掉（已完成很久）也算送达。
    private var status: DeliveryStatus? {
        switch request {
        case .none: nil
        case .some(.none): .succeeded
        case .some(.some(let request)): request.status.known
        }
    }

    private var target: String { request??.target.name ?? "Pi" }

    @ViewBuilder private var symbol: some View {
        switch status {
        case .succeeded: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.scale.combined(with: .opacity))
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        default: ProgressView().controlSize(.large)
        }
    }

    private var title: String {
        switch status {
        case .succeeded: "已发到 \(target)"
        case .failed: "没能发出"
        case .executing: "Mac 正在发给 \(target)…"
        default: "等 Mac 接手…"
        }
    }

    private var detail: String? {
        switch status {
        case .failed: request??.resultDetail ?? "Mac 没有说明原因"
        case .pending, .none: "Mac 上的 CuePad 需要开着"
        default: nil
        }
    }
}
#endif
