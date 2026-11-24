import CueSync
import SwiftUI

/// 更新钮：侧栏底下那排（手机在页头那一排）。有一版下好了、点了在等会断的会话做完、要你在 Sparkle 的窗里确认，
/// 或这台旧到停了同步时才出现，点开挨着它长出气泡，主钮就是下一步。平时不占位，不弹窗。
struct UpdateButton: View {
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var detail = BubbleSwitch()

    var body: some View {
        let offer = UpdateOffer(services)
        ZStack {
            if let offer {
                Button { detail.toggle() } label: { UpdateGlyph(offer: offer) }
                    .help(Text(offer.title))
                    .accessibilityLabel(Text(offer.title))
                    .bubble($detail) { UpdateDetail(offer: offer) { detail.open = false } }
                    .transition(Motion.pop(reduceMotion: reduceMotion))
            }
        }
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: offer)
    }
}

private struct UpdateGlyph: View {
    let offer: UpdateOffer
    @Environment(\.palette) private var palette

    var body: some View {
        Label { Text(offer.title) } icon: { Image(.updates).foregroundStyle(offer.blocksSync ? palette.waiting : palette.signature) }
    }
}

/// 更新钮此刻代表的事，从更新器（Mac）与同步状态推出来，不另存。
enum UpdateOffer: Equatable {
    #if os(macOS)
    case update(UpdateService.State, blocksSync: Bool)
    #endif
    /// 这台旧到停了同步，新版还没下好（手机：去 TestFlight 更新）
    case behind

    init?(_ services: AppServices) {
        let behind = services.syncing.state.status == .outdated
        #if os(macOS)
        if let state = services.updates.state {
            self = .update(state, blocksSync: behind)
            return
        }
        #endif
        guard behind else { return nil }
        self = .behind
    }

    var blocksSync: Bool {
        switch self {
        #if os(macOS)
        case .update(_, let blocks): blocks
        #endif
        case .behind: true
        }
    }

    var title: LocalizedStringResource {
        switch self {
        #if os(macOS)
        case .update(.waiting(_, let busy), _): "等 \(busy) 个 Agent 做完再装"
        case .update: "新版已就绪"
        #endif
        case .behind: "这台的 CuePad 要更新"
        }
    }
}

private struct UpdateDetail: View {
    let offer: UpdateOffer
    let close: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(offer.title).font(Typography.secondaryBold).foregroundStyle(palette.ink)
                ForEach(lines, id: \.self) { Text($0).font(Typography.meta).foregroundStyle(palette.ink2) }
            }
            if let step {
                Button(step) {
                    close()
                    act()
                }
                .buttonStyle(ControlButtonStyle(kind: .primary, size: .compact))
            }
        }
        .fixedSize()
        .padding(Spacing.block)
    }

    private var lines: [String] {
        var lines: [String] = []
        switch offer {
        #if os(macOS)
        case .update(.ready(let version), _), .update(.confirm(let version), _): lines.append("CuePad \(version.name)")
        case .update(.waiting, _): lines.append(String(localized: "它们空下来就自动重启更新"))
        #endif
        case .behind: lines.append(String(localized: "别的设备已用新版，这台更新后接着同步"))
        }
        #if os(macOS)
        if case .update(.confirm, _) = offer { lines.append(String(localized: "这一版要你确认后安装")) }
        if case .update(_, true) = offer { lines.append(String(localized: "更新后接着同步")) }
        if offer == .behind { lines.append(String(localized: "新版下好后在这里装")) }
        #endif
        return lines
    }

    private var step: LocalizedStringResource? {
        switch offer {
        #if os(macOS)
        case .update(.ready, _): "重启更新"
        case .update(.waiting, _): "现在就装"
        case .update(.confirm, _): "安装…"
        case .behind: nil
        #else
        case .behind: "在 TestFlight 里更新"
        #endif
        }
    }

    private func act() {
        #if os(macOS)
        services.updates.act()
        #else
        openURL(SyncSummary.update)
        #endif
    }
}
