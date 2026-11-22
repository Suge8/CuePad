import CueStore
import SwiftUI

/// Cue 自己开口带你（`CueGuide`）：左边是它说的，右边是你能做的那一下，同对话里它在左、你在右。
struct CueWelcome: View {
    let intro: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL
    @State private var model = CueSettingsModel()

    var body: some View {
        let settings = model.settings ?? .empty
        let guide = CueGuide.of(settings, here: workspace.localHost, canHear: workspace.cue.canHear, services: services)
        CueSpeech(lines: model.settings == nil ? [] : lines(guide)) { actions(guide, settings) }
            .cueSettings(model)
    }

    private func lines(_ guide: CueGuide) -> [CueGuide.Line] {
        let lines = guide.lines(name: workspace.cue.name, intro: intro)
        return lines + (model.failure.map { [CueGuide.Line(text: $0, failed: true)] } ?? [])
    }

    @ViewBuilder private func actions(_ guide: CueGuide, _ settings: CueSettings) -> some View {
        switch guide {
        case .ready:
            CueStarters()
        case .waiting:
            EmptyView()
        case .enable(let host):
            enabling(host, settings.hosts(here: workspace.localHost))
        #if os(iOS)
        case .offline(let status):
            if status == .noAccount {
                Button(SyncSummary.settingsTitle) { openURL(SyncSummary.settings) }.buttonStyle(ControlButtonStyle(kind: .primary))
            }
        case .install:
            ShareLink(item: CueSettings.macDownload) { Label("发出 Mac 版的下载链接", icon: .share) }
                .buttonStyle(ControlButtonStyle(kind: .primary))
        case .agents:
            EmptyView()
        #endif
        }
    }

    private func enabling(_ host: CueSettings.Host?, _ hosts: [CueSettings.Host]) -> some View {
        VStack(alignment: .trailing, spacing: Spacing.item) {
            HStack(spacing: Spacing.item) {
                if model.enabling != nil { Spinner(.small) }
                if let host {
                    Button(title(host)) { enable(on: host) }.buttonStyle(ControlButtonStyle(kind: .primary))
                } else {
                    hostMenu(hosts, title: String(localized: "选一台 Mac"), kind: .primary)
                }
            }
            let others = hosts.filter { $0.id != host?.id }
            if host != nil, !others.isEmpty { hostMenu(others, title: String(localized: "选别的 Mac"), kind: .glass) }
        }
        .disabled(model.enabling != nil)
    }

    private func title(_ host: CueSettings.Host) -> LocalizedStringResource {
        if !host.isHere { return "在「\(host.name)」上启用" }
        return host.usable ? "在这台 Mac 上启用" : "接入 Agent"
    }

    private func enable(on host: CueSettings.Host) {
        #if os(macOS)
        if host.isHere, !host.usable {
            workspace.showsSetup = true
            return
        }
        #endif
        model.choose(host, services)
    }

    private func hostMenu(_ hosts: [CueSettings.Host], title: String, kind: ControlButtonStyle.Kind) -> some View {
        CueHostMenu(hosts: hosts, use: .enable { enable(on: $0) }, accessibilityLabel: title) {
            HStack(spacing: Spacing.glyph) {
                Text(title)
                Chevron(.expand)
            }
            .modifier(ControlSurface(kind: kind))
        }
    }
}

/// Cue 一句一句说出来：与对话里它说的同一种气泡、同一种出字（`MarkdownText` 的 `.newest`），说完了右边才给你那一下。
/// 冷启动时等开门、它落回云上才开口（`CueOpening`）；之后再来，话已经摆在那。说着时步子变了：相同的开头留着，后面的收回，接着说新的。
struct CueSpeech<Actions: View>: View {
    let lines: [CueGuide.Line]
    @ViewBuilder var actions: Actions
    @State private var said: [CueGuide.Line] = []
    @State private var waited = false
    @State private var talking = false
    @State private var reveals = RevealLedger()
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 一句的字都落下后到下一句冒出来的停顿（前一句的最后几个字还在显影）：像换了口气，不是一口气念完。
    private static var breath: Double { 0.28 }

    private struct Script: Equatable {
        let lines: [CueGuide.Line]
        let open: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CueBubble.joinedGap) {
            ForEach(Array(said.enumerated()), id: \.element) { index, line in
                bubble(line, joined: index > 0).transition(arrival)
            }
            if !said.isEmpty, said == lines, !talking {
                actions
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, Spacing.group)
                    .transition(arrival)
            }
        }
        .environment(\.revealLedger, reveals)
        .debugSettling(said != lines || talking)
        .task(id: Script(lines: lines, open: CueOpening.shared.phase == .open)) { await speak() }
    }

    private var arrival: AnyTransition {
        reduceMotion ? .opacity : .offset(y: Motion.Surface.shift).combined(with: .opacity)
    }

    private func speak() async {
        guard CueOpening.shared.phase == .open else { return waited = true }
        let kept = zip(said, lines).prefix { $0 == $1 }.count
        let paced = !reduceMotion && (waited || !said.isEmpty)
        talking = paced
        withAnimation(Motion.fade) { said.removeLast(said.count - kept) }
        for line in lines.dropFirst(kept) {
            withAnimation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion)) { said.append(line) }
            if paced { guard await pause(.seconds(Double(line.text.count) / Motion.Reveal.pace + Self.breath)) else { return } }
        }
        withAnimation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion)) { talking = false }
    }

    private func pause(_ duration: Duration) async -> Bool {
        do { try await Task.sleep(for: duration) } catch { return false }
        return true
    }

    private func bubble(_ line: CueGuide.Line, joined: Bool) -> some View {
        BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.glyph) {
                    if line.busy { Spinner(.small) }
                    if line.failed {
                        Text(line.text).font(Typography.reading).foregroundStyle(palette.failure)
                    } else {
                        MarkdownText(source: line.text, reveal: .newest).equatable()
                    }
                }
                if let detail = line.detail {
                    Text(detail).font(Typography.meta).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .cueBubble(joined: joined)
        }
    }
}
