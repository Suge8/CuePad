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
    @Environment(\.palette) private var palette

    var body: some View {
        NoteLine(time: at) {
            if header.failed { FailureMark() } else { Image(header.wake.icon) }
        } label: {
            if let said {
                Text(said).font(Typography.secondary).foregroundStyle(palette.ink2).lineLimit(2).accessibilityLabel("\(header.reason)，\(said)")
            } else {
                reason
            }
        }
    }

    /// 名字、后面的话与"没动手"排成一段字，按这个先后：窄处（iPhone）名字先读全，后面的话折到下一行，不截名字去留"子代理卡住了 · 没动手"。
    /// "没动手"与前面隔一个点，一行放不下时它自起一行、不带点（点不落在行首）。几点按自己的宽排在行末、对着第一行（`NoteLine`）。
    private var words: some View {
        Group {
            if quiet, header.name != nil {
                ViewThatFits(in: .horizontal) {
                    phrase(quietAfter: Dotted.separator).lineLimit(1)
                    phrase(quietAfter: "\n").lineLimit(3)
                }
            } else {
                phrase(quietAfter: "").lineLimit(2)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .menuLabel([header.reason, header.name, header.trail, quiet ? "没动手" : nil].compactMap(\.self).joined(separator: "，"))
    }

    private func phrase(quietAfter gap: String) -> Text {
        var line = AttributedString()
        func add(_ text: String, _ color: Color, after: String = " ", medium: Bool = false) {
            var part = AttributedString(line.characters.isEmpty ? text : after + text)
            part.foregroundColor = color
            if medium { part.font = Typography.caption.weight(.medium) }
            line += part
        }
        if let name = header.name { add(name, palette.ink, medium: true) }
        if let trail = header.trail { add(trail, palette.ink2) }
        if quiet { add("没动手", palette.ink3, after: gap) }
        let chevron = Text(Image(.forward)).font(.system(size: 8, weight: .semibold)).foregroundStyle(palette.ink3)
        return Text("\(Text(line))\(header.targets.isEmpty ? Text("") : Text(" \(chevron)"))")
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
            workspace.openSession(session.id, sessionID: session.sessionID)
        case .task(let id):
            workspace.openTask(id: id)
        case .memory:
            workspace.cue.showsMemory = true
        }
    }
}
