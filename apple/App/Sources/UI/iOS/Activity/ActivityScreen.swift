#if os(iOS)
import CueStore
import CueSync
import SwiftUI

/// Pi：只回答"每个会话在做什么、现在到哪了、结果或卡点是什么"。一张列表按要你注意的先后排
/// （等你确认 → 出错 → 工作中 → 空闲 → 已结束），点开看近况、回复。发出的请求只在会话近况里看。
struct ActivityScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var sessions: [PiSessionState]?

    var body: some View {
        ScrollView {
            if let sessions {
                VStack(alignment: .leading, spacing: 12) {
                    if !services.syncStatus.reachesMac { SyncHint(status: services.syncStatus).padding(.horizontal, 4) }
                    if sessions.isEmpty {
                        ContentUnavailableView {
                            Label("还没有 Pi 会话", systemImage: "terminal")
                        } description: {
                            Text("在 Mac 的终端运行 pi，会话就会出现在这里")
                        }
                        .padding(.top, 40)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                                if index > 0 { Divider().padding(.leading, 44) }
                                SessionRow(session: session)
                            }
                        }
                        .paper(radius: 16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .animation(Motion.quick, value: sessions.map(\.id))
                .animation(Motion.quick, value: sessions.map(\.state))
            }
        }
        .background(palette.desk)
        .bottomEdgeFade()
        .navigationTitle("Pi")
        .refreshable { await services.syncNow() }
        .observing(services.store, [.piSessionStates], into: $sessions, onError: workspace.fail) {
            PiSessionState.inListOrder(try $0.piSessionStates())
        }
    }
}

/// 一个会话三层：左边状态标；名字与时长；在哪 · 状态词（带色）；一句进度或结果（没有不占行）。已结束的整行更淡。
private struct SessionRow: View {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        let project = workspace.catalog?.project(session.projectID)
        Button { navigation.push(.session(session.id)) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                PiStateDot(state: session.state, size: 8)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(session.title).font(.headline).foregroundStyle(palette.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        PiElapsed(session: session)
                    }
                    HStack(spacing: 4) {
                        if let place = PiPlace.name(of: session, project: project) {
                            Text("\(place) ·").foregroundStyle(palette.ink3).lineLimit(1)
                        }
                        Text(session.state.label).fontWeight(.medium).foregroundStyle(session.state.tint(palette))
                    }
                    .font(.subheadline)
                    if let progress = PiProgress.line(of: session) {
                        Text(progress).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(session.state == .known(.ended) ? 0.6 : 1)
            .contentShape(.rect)
        }
        .buttonStyle(RowPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("看近况、回复")
    }
}

nonisolated extension SyncStatus {
    /// 此刻同步能把请求送到 Mac、把 Mac 上的 Pi 状态带回来：已连上或正在连接。
    /// 其余状态（没开 iCloud、不可用、暂停、出错、空间不足）都到不了，界面写明原因。
    var reachesMac: Bool {
        switch self {
        case .starting, .idle, .syncing: true
        default: false
        }
    }
}

/// 同步到不了 Mac 时的一行轻提示（Pi 页顶部、回复框里）：哪里不通；详情与处理在设置里。
struct SyncHint: View {
    let status: SyncStatus
    @Environment(\.palette) private var palette

    var body: some View {
        let summary = SyncSummary(status)
        Label("\(summary.title) · 看到的可能不是最新，也发不到 Mac", systemImage: summary.symbol)
            .font(.footnote).foregroundStyle(palette.ink3)
            .lineLimit(2)
    }
}
#endif
