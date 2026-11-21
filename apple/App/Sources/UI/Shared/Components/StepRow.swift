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
    @Environment(\.chatStay) private var stay
    @State private var opened: Opened?
    @State private var key = UUID()
    @State private var fetching: UUID?

    enum Opened: Equatable { case loading, ready(ToolCallDetail), missing(String) }

    var body: some View {
        if item.calls != nil, services.holdsSteps(of: session) || message != nil {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: toggle) { row(open: opened != nil) }
                    .buttonStyle(PressStyle(.inline))
                    .accessibilityExpanded(opened != nil)
                switch opened {
                case .ready(let detail): if detail.isEmpty { note(Text("这一步没有更多内容")) } else { StepWell(detail: detail) }
                case .missing(let why): note(Text(why))
                case .loading: if !services.holdsSteps(of: session) { note(Text("正在从 Mac 取").shimmering()) }
                case nil: EmptyView()
                }
            }
            .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: opened)
            .task {
                guard message != nil, DebugHooks.preset.stepOpen == index, (try? await Task.sleep(for: .seconds(2))) != nil else { return }
                toggle()
            }
            .onChange(of: item.detail) { if opened == .loading, let detail = item.detail { opened = .ready(detail) } }
            .onDisappear { if opened != nil { stay?(key, false) } }
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

    private func toggle() {
        guard opened == nil else {
            stay?(key, false)
            fetching = nil
            return opened = nil
        }
        stay?(key, true)
        if let detail = item.detail { return opened = .ready(detail) }
        opened = .loading
        fetching = UUID()
    }

    private func fetch() async {
        do {
            #if os(macOS)
            if services.holdsSteps(of: session) {
                let detail = try await AppServices.stepDetail(item.calls ?? [], of: session.sessionID, in: services.store, runtimes: services.runtimes)
                if opened == .loading { opened = .ready(detail) }
                return
            }
            #endif
            guard let message else { return }
            try await services.fetchStep(index, of: message, in: session)
            try await Task.sleep(for: .seconds(10))
            if opened == .loading { opened = .missing(String(localized: "详情没同步过来，再点一次")) }
        } catch is CancellationError {
        } catch {
            if opened == .loading { opened = .missing(ShownText(error).text) }
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
                        Text(run.text).foregroundStyle(run.kind.changed ? palette.ink : palette.ink2).selectable()
                            .padding(.horizontal, Spacing.item).padding(.vertical, Spacing.tight)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(run.kind.wash(palette))
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
