import CueStore
import SwiftUI

/// 一节的第一行（`NoteLine`，同并起来的那一行）：醒来原因的图标（叫醒它的会话出错是出错的那个）、原因（叫醒它的会话、任务、提醒是墨色的名字，点了去那里；
/// 几处时点开列出来选），行末几点。原因只画图标，几段间隔一个点，可点的末尾一个箭头。
struct CueWakeTitle: View {
    let header: CueWakeHeader
    let at: Date
    let quiet: Bool
    /// 接在图标后面的那句话（只有图标时）
    let said: String?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(Navigation.self) private var navigation
    #endif

    var body: some View {
        NoteLine(time: at) {
            if header.failed { FailureMark() } else { Image(header.wake.icon) }
        } label: {
            if let said {
                Text(said).font(Typography.secondary).foregroundStyle(palette.ink2).lineLimit(2).accessibilityLabel("\(header.wake.reason)，\(said)")
            } else {
                reason
            }
        }
    }

    /// 名字太长时只截名字，前后的话留全。
    private var words: some View {
        HStack(spacing: 4) {
            if let name = header.name { Text(name).fontWeight(.medium).foregroundStyle(palette.ink) }
            if let trail = header.trail { Text(trail).foregroundStyle(palette.ink2).fixedSize() }
            if quiet {
                if header.name != nil { Dot().foregroundStyle(palette.ink3) }
                Text("没动手").foregroundStyle(palette.ink3).fixedSize()
            }
            if !header.targets.isEmpty { Image(.forward).font(.system(size: 8, weight: .semibold)).foregroundStyle(palette.ink3) }
        }
        .lineLimit(1)
        .menuLabel([header.wake.reason, header.name, header.trail, quiet ? "没动手" : nil].compactMap(\.self).joined(separator: "，"))
    }

    @ViewBuilder private var reason: some View {
        let label = words.contentShape(.rect)
        switch header.targets.count {
        case 0: label
        case 1: Button { open(header.targets[0].target) } label: { label }.buttonStyle(PressStyle(.inline))
        default:
            Menu {
                ForEach(header.targets, id: \.title) { place in Button(place.title) { open(place.target) } }
            } label: { label }
            .menuStyle(.button).buttonStyle(PressStyle(.inline)).menuIndicator(.hidden)
        }
    }

    private func open(_ target: CueWakeHeader.Target) {
        switch target {
        case .session(let session):
            #if os(macOS)
            workspace.show(.session(session.sessionID))
            #else
            navigation.openSession(session.id, sessionID: session.sessionID, store: services.store)
            #endif
        case .task(let id):
            workspace.openTask(id: id)
        case .memory:
            workspace.cue.showsMemory = true
        }
    }
}
