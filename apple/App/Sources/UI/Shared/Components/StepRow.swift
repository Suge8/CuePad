import CueStore
import SwiftUI

/// 清单里的一步，点开在原位看里面：命令全文或改动，下面是输出的末尾（`ToolCallDetail`）。
/// 会话所在的 Mac 上当场回会话文件取；别的设备上请那台 Mac 取了写在这一步上（做完的一轮才行：在跑的那一轮还不是一条回答，没处写）。
struct StepRow: View {
    let item: ChatMessage.Tools.Item
    let session: SessionState
    /// 做完的一轮里的这一步：哪条回答的第几项；在跑的一轮为 nil。
    let place: (message: UUID, index: Int)?
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatStay) private var stay
    @State private var opened: Opened?

    enum Opened: Equatable { case loading, ready(ToolCallDetail), missing(String) }

    var body: some View {
        if item.calls != nil, services.holdsSteps(of: session) || place != nil {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: toggle) { row(open: opened != nil) }
                    .buttonStyle(PressStyle())
                    .accessibilityExpanded(opened != nil)
                switch opened {
                // 取到了却是空的：这一步没有命令、改动与文字输出（看了一张图、搜了一下网）
                case .ready(let detail): if detail.isEmpty { note(Text("这一步没有更多内容")) } else { StepWell(detail: detail) }
                case .missing(let why): note(Text(why))
                // 本机读是毫秒级的，读的那一下不另画；向 Mac 取要几秒
                case .loading: if !services.holdsSteps(of: session) { note(Text("正在从 Mac 取").shimmering()) }
                case nil: EmptyView()
                }
            }
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: opened)
            .task {
                // 等画面就绪、对话贴到最新处之后再点：和人点的时机一样
                guard let place, DebugHooks.preset.stepOpen == place.index, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                toggle()
            }
            .onChange(of: item.detail) { if opened == .loading, let detail = item.detail { opened = .ready(detail) } }
        } else {
            row(open: nil)
        }
    }

    private func note(_ text: some View) -> some View {
        text.font(Typography.caption).foregroundStyle(palette.ink3).padding(.vertical, Spacing.hair).noteGlyph(.indent).transition(.opacity)
    }

    private func row(open: Bool?) -> some View {
        ToolRow(icon: RoundProcess.icon(item.kind), target: Text(item.target), truncation: item.kind == .command ? .tail : .middle) {
            if item.failed {
                Text("失败").font(Typography.caption).foregroundStyle(palette.failure)
            } else if item.added != nil || item.removed != nil {
                Text(Chat.diffLabel(added: item.added, removed: item.removed)).font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3)
            }
            if let open { DisclosureChevron(open: open) }
        }
        .contentShape(.rect)
    }

    private func toggle() {
        guard opened == nil else {
            stay?(false)
            return opened = nil
        }
        stay?(true)
        if let detail = item.detail { return opened = .ready(detail) }
        opened = .loading
        Task {
            do {
                #if os(macOS)
                if services.holdsSteps(of: session) {
                    let detail = try await AppServices.stepDetail(item.calls ?? [], of: session.sessionID, in: services.store, runtimes: services.runtimes)
                    if opened == .loading { opened = .ready(detail) }
                    return
                }
                #endif
                guard let place else { return }
                try await services.fetchStep(place.index, of: place.message, in: session)
                // Mac 办完了，写上的详情随同步稍后到（`onChange`）；这之间那条回答被重读改写的话它就没了，不一直等
                try await Task.sleep(for: .seconds(10))
                if opened == .loading { opened = .missing(String(localized: "详情没同步过来，再点一次")) }
            } catch {
                if opened == .loading { opened = .missing(ShownText(error).text) }
            }
        }
    }
}

private struct StepWell: View {
    let detail: ToolCallDetail
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            if let command = detail.command {
                Text(command).foregroundStyle(palette.ink).selectable()
            }
            if let diff = detail.diff {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(Self.runs(diff).enumerated()), id: \.offset) { _, run in
                        Text(run.text).foregroundStyle(run.sign == " " ? palette.ink2 : palette.ink).selectable()
                            .padding(.horizontal, Spacing.item).padding(.vertical, Spacing.tight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(run.sign == "-" ? palette.diffRemoved : run.sign == "+" ? palette.diffAdded : .clear)
                    }
                }
                .clipShape(.rect(cornerRadius: Radius.chip))
            }
            if !detail.output.isEmpty {
                if detail.command != nil || detail.diff != nil { palette.hair.frame(height: 1) }
                if detail.clipped {
                    Text("更早的输出未显示").font(Typography.caption).foregroundStyle(palette.ink3)
                }
                Text(detail.output).foregroundStyle(palette.ink2).selectable()
            }
        }
        .font(Typography.codeNote)
        .fixedSize(horizontal: false, vertical: true)
        .padding(Spacing.group)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.fill, in: .rect(cornerRadius: Radius.block))
        .padding(.vertical, Spacing.tight)
        .noteGlyph(.indent)
        .transition(.opacity)
    }

    /// 连着的同一种行并成一块，一块一个底色；段与段之间（`@@`）空一行。
    private static func runs(_ diff: String) -> [(sign: Character, text: String)] {
        var runs: [(sign: Character, rows: [String])] = []
        for row in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let hunk = row.hasPrefix("@@")
            let sign: Character = hunk ? " " : row.first.flatMap { "+-".contains($0) ? $0 : nil } ?? " "
            let shown = hunk ? "" : (sign == "-" ? "− " : sign == "+" ? "+ " : "  ") + (row.first == sign ? row.dropFirst() : row[...])
            if runs.last?.sign == sign { runs[runs.count - 1].rows.append(shown) } else { runs.append((sign, [shown])) }
        }
        return runs.map { ($0.sign, $0.rows.joined(separator: "\n")) }
    }
}
