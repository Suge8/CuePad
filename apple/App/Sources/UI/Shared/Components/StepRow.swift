import CueStore
import SwiftUI

/// 清单里的一步，点开在原位看里面：命令全文或改动，下面是输出的末尾（`ToolCallDetail`）。
/// 会话所在的 Mac 上当场回会话文件取；别的设备上请那台 Mac 取了写在这一步上、随同步回来（做完的一轮才行，`CueStore.requestStep`）。
struct StepRow: View {
    let item: ChatMessage.Tools.Item
    let session: SessionState
    /// 做完的一轮是哪条回答；在跑的一轮为 nil。
    let message: UUID?
    let index: Int
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened: Opened?
    /// 这一次点开要去取（每点开一次换一个）：取的任务随这一行走，行没了、收起了就不再等。
    @State private var fetching: UUID?

    enum Opened: Equatable { case loading, ready(ToolCallDetail), missing(String) }

    var body: some View {
        if item.calls != nil, services.holdsSteps(of: session) || message != nil {
            Fold(open: Binding { opened != nil } set: { $0 ? open() : close() }) {
                row(open: opened != nil)
            } content: {
                switch opened {
                // 取到了却是空的：这一步没有命令、改动与文字输出（看了一张图、搜了一下网）
                case .ready(let detail): if detail.isEmpty { note(Text("这一步没有更多内容")) } else { StepDetail(detail: detail, shown: item.target) }
                case .missing(let why): note(Text(why))
                // 本机读是毫秒级的，读的那一下不另画；向 Mac 取要几秒
                case .loading: if !services.holdsSteps(of: session) { note(Text("正在从 Mac 取").shimmering()) }
                case nil: EmptyView()
                }
            }
            .task {
                // 等画面就绪、对话贴到最新处之后再点：和人点的时机一样
                guard message != nil, DebugHooks.preset.stepOpen == index, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                open()
            }
            .onChange(of: item.detail) { if let detail = item.detail { land(.ready(detail)) } }
            .task(id: fetching) { if fetching != nil { await fetch() } }
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

    private func open() {
        if let detail = item.detail { return opened = .ready(detail) }
        opened = .loading
        fetching = UUID()
    }

    private func close() {
        fetching = nil
        opened = nil
    }

    private func land(_ fetched: Opened) {
        guard opened == .loading else { return }
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { opened = fetched }
    }

    private func fetch() async {
        do {
            #if os(macOS)
            if services.holdsSteps(of: session) {
                let detail = try await AppServices.stepDetail(item.calls ?? [], of: session.sessionID, in: services.store, runtimes: services.runtimes)
                land(.ready(detail))
                return
            }
            #endif
            guard let message else { return }
            try await services.fetchStep(index, of: message, in: session)
            // Mac 办完了，写上的详情随同步稍后到（`onChange`）；这之间那条回答被重读改写的话它就没了，不一直等
            try await Task.sleep(for: .seconds(10))
            land(.missing(String(localized: "详情没同步过来，再点一次")))
        } catch is CancellationError {
        } catch {
            land(.missing(ShownText(error).text))
        }
    }
}

private struct StepDetail: View {
    let detail: ToolCallDetail
    let shown: String
    @Environment(\.palette) private var palette
    @State private var earlierOpen = false

    var body: some View {
        let command = detail.command.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) == shown ? nil : $0 }
        NoteThread {
            VStack(alignment: .leading, spacing: Spacing.item) {
                if let command { Text(command).foregroundStyle(palette.ink).selectable() }
                if let diff = detail.diff {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(Self.runs(diff).enumerated()), id: \.offset) { _, run in
                            Text(run.text).foregroundStyle(run.kind.changed ? palette.ink : palette.ink2).selectable()
                                .padding(.horizontal, Spacing.item).padding(.vertical, Spacing.tight)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(run.kind.wash(palette))
                        }
                    }
                    .clipShape(.rect(cornerRadius: Radius.chip))
                }
                if !detail.output.isEmpty { output }
            }
            .font(Typography.codeNote)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.tight)
        }
    }

    /// 命令的结论在最后：先露末尾几行，更早的点开才往上长。
    @ViewBuilder private var output: some View {
        let rows = detail.output.split(separator: "\n", omittingEmptySubsequences: false)
        let earlier = rows.dropLast(Self.tail)
        let dropped = Text("更早的输出未显示").font(Typography.caption).foregroundStyle(palette.ink3)
        if earlier.isEmpty {
            if detail.clipped { dropped }
            Text(detail.output).foregroundStyle(palette.ink2).selectable()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Fold(open: $earlierOpen) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                        Text("更早的输出").font(Typography.caption).foregroundStyle(palette.ink3)
                        DisclosureChevron(open: earlierOpen)
                    }
                    .frame(minHeight: Note.lineHeight).contentShape(.rect)
                } content: {
                    if earlierOpen {
                        VStack(alignment: .leading, spacing: Spacing.item) {
                            if detail.clipped { dropped }
                            Text(earlier.joined(separator: "\n")).foregroundStyle(palette.ink2).selectable()
                        }
                        .transition(.opacity)
                    }
                }
                Text(rows.suffix(Self.tail).joined(separator: "\n")).foregroundStyle(palette.ink2).selectable()
                    .fadesEdge(.top, when: !earlierOpen)
            }
        }
    }

    private static let tail = 12

    /// 连着的同一种行并成一块，一块一个底色；段与段之间（`@@`）空一行。Mac 只交来一串 `+`/`-` 行、几段用 `@@` 隔开（没有文件抬头），按一段来读。
    private static func runs(_ diff: String) -> [(kind: UnifiedDiff.Line.Kind, text: String)] {
        let source = diff.hasPrefix("@@") || diff.hasPrefix("diff ") || diff.hasPrefix("--- ") ? diff : "@@\n" + diff
        var runs: [(kind: UnifiedDiff.Line.Kind, rows: [String])] = []
        for line in UnifiedDiff(source).lines {
            let row: String
            switch line.kind {
            case .file: continue
            case .hunk where runs.isEmpty: continue
            case .hunk: row = ""
            case .note: row = line.text
            case .context: row = "  " + line.text
            case .added, .removed: row = line.kind.sign + " " + line.text
            }
            let kind: UnifiedDiff.Line.Kind = line.kind.changed ? line.kind : .context
            if let last = runs.last, last.kind.sign == kind.sign { runs[runs.count - 1].rows.append(row) } else { runs.append((kind, [row])) }
        }
        return runs.map { ($0.kind, $0.rows.joined(separator: "\n")) }
    }
}
