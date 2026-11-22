import CueStore
import SwiftUI

struct StepRow: View {
    let item: ChatMessage.Tools.Item
    let session: SessionState
    let message: UUID?
    let index: Int
    @Environment(\.palette) private var palette
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opened: Opened?
    @State private var fetching: UUID?

    enum Opened: Equatable { case loading, ready(ToolCallDetail), missing(String) }

    var body: some View {
        if item.calls != nil, services.holdsSteps(of: session) || message != nil {
            Fold(open: Binding { opened != nil } set: { $0 ? open() : close() }) {
                row(open: opened != nil)
            } content: {
                switch opened {
                case .ready(let detail): if beyondTitle(detail).isEmpty { note(Text("这一步没有更多内容")) } else { StepDetail(detail: beyondTitle(detail)) }
                case .missing(let why): note(Text(why))
                case .loading: if !services.holdsSteps(of: session) { note(Text("正在从 Mac 取").shimmering()) }
                case nil: EmptyView()
                }
            }
            .task {
                guard message != nil, DebugHooks.preset.stepOpen == index, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                open()
            }
            .onChange(of: item.detail) { if let detail = item.detail { land(.ready(detail), over: .missing(Self.late)) } }
            .task(id: fetching) { if fetching != nil { await fetch() } }
        } else {
            row(open: nil)
        }
    }

    private func note(_ text: some View) -> some View {
        text.font(Typography.caption).foregroundStyle(palette.ink3).padding(.vertical, Spacing.hair).noteGlyph(.indent).transition(.opacity)
    }

    private func row(open: Bool?) -> some View {
        ToolRow(icon: RoundProcess.icon(item.kind), target: Text(item.target), truncation: item.kind == .command ? .tail : .middle, wraps: titleIsCommand) {
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

    private var titleIsCommand: Bool {
        if case .ready(let detail) = opened { detail.command?.trimmingCharacters(in: .whitespacesAndNewlines) == item.target } else { false }
    }

    private func beyondTitle(_ detail: ToolCallDetail) -> ToolCallDetail {
        var rest = detail
        if titleIsCommand { rest.command = nil }
        return rest
    }

    private static var late: String { String(localized: "详情没同步过来，再点一次") }

    private func land(_ fetched: Opened, over waited: Opened = .loading) {
        guard opened == .loading || opened == waited else { return }
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { opened = fetched }
    }

    private func fetch() async {
        do {
            #if os(macOS)
            if services.holdsSteps(of: session) {
                let detail = try await AppServices.stepDetail(item.calls ?? [], of: session.sessionID, in: services.store, runtimes: services.runtimes)
                try Task.checkCancellation()
                land(.ready(detail))
                return
            }
            #endif
            guard let message else { return }
            try await services.fetchStep(index, of: message, in: session)
            try await Task.sleep(for: .seconds(10))
            land(.missing(Self.late))
        } catch is CancellationError {
        } catch {
            land(.missing(ShownText(error).text))
        }
    }
}

private struct StepDetail: View {
    let detail: ToolCallDetail
    @Environment(\.palette) private var palette
    @State private var earlierOpen = false
    @State private var long = false
    @ScaledMetric(relativeTo: .caption) private var tail: CGFloat = 192

    var body: some View {
        NoteThread {
            VStack(alignment: .leading, spacing: Spacing.item) {
                if let command = detail.command { Text(command).foregroundStyle(palette.ink).selectable() }
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

    @ViewBuilder private var output: some View {
        let dropped = Text("更早的输出未显示").font(Typography.caption).foregroundStyle(palette.ink3)
        let text = Text(detail.output).foregroundStyle(palette.ink2).selectable().fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: Bool.self) { [tail] in $0.size.height > tail } action: { long = $0 }
        if long {
            Fold(open: $earlierOpen) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
                    Text("更早的输出").font(Typography.caption).foregroundStyle(palette.ink3)
                    DisclosureChevron(open: earlierOpen)
                }
                .frame(minHeight: Note.lineHeight).contentShape(.rect)
            } content: {
                if earlierOpen, detail.clipped { dropped.padding(.bottom, Spacing.item).transition(.opacity) }
                text.frame(maxHeight: earlierOpen ? nil : tail, alignment: .bottom).clipped().fadesEdge(.top, when: !earlierOpen)
            }
        } else {
            if detail.clipped { dropped }
            text
        }
    }

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
