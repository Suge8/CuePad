import SwiftUI

#if os(iOS)
struct LastCrashRow: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showing = LastCrashRow.opensAtStart

    var body: some View {
        if let report = services.diagnostics.latest {
            Button { showing = true } label: {
                LabeledContent {
                    Text(report.date.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(palette.ink3)
                } label: {
                    Label { Text(report.kind.label) } icon: { FailureMark() }.foregroundStyle(palette.ink)
                }
            }
            .buttonStyle(PressStyle())
            .panel(isPresented: $showing) { CrashReportView(report: report) }
        }
    }

    private static var opensAtStart: Bool { DebugHooks.preset.crashSheet }
}
#endif

/// 复制的是每种只留要点的摘要（`DiagnosticSummary`），完整原文作文件分享，不进剪贴板。
struct CrashReportView: View {
    let report: CrashReport
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private var summary: String { DiagnosticSummary.text(services.diagnostics.reports) }
    private var files: [URL] { Array(Set(services.diagnostics.reports.map(\.file))).sorted().map(services.diagnostics.archive.url) }
    private var lines: [String] { report.trail + report.frames.map(\.text) }

    #if os(iOS)
    @Environment(\.closePanel) private var close

    var body: some View {
        NavigationStack {
            list
                .navigationTitle(report.kind.label)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { close() } } }
        }
    }
    #else
    var body: some View {
        SettingPopover(title: report.kind.label, width: 420) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Spacing.group, verticalSpacing: 6) {
                ForEach(facts, id: \.0.key) { title, value in
                    GridRow {
                        Text(title).foregroundStyle(palette.ink3)
                        Text(value.visible).foregroundStyle(palette.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if !lines.isEmpty {
                Text(lines.joined(separator: "\n")).font(Typography.meta.monospaced()).foregroundStyle(palette.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Spacing.item).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.fill, in: .rect(cornerRadius: Radius.chip))
            }
            HStack(spacing: Spacing.item) {
                ExportDiagnosticsButton(text: summary)
                ShareLink(items: files) { Text(Self.share) }
            }
            .buttonStyle(ControlButtonStyle(size: .compact))
            Text(Self.note).font(Typography.meta).foregroundStyle(palette.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif

    private var facts: [(LocalizedStringResource, Dotted)] {
        var facts: [(LocalizedStringResource, Dotted)] = [("时间", Dotted(report.shownDate))]
        if let exception = report.exception { facts.append(("异常", Dotted(exception + (report.signal.map { "（\($0)）" } ?? "")))) }
        // 有人话的不再列原文（终止原因原文一长段，占满整页）：原文在导出的摘要里
        if let explanation = report.explanation { facts.append(("含义", Dotted(explanation))) } else if let reason = report.reason { facts.append(("原因", Dotted(reason))) }
        if let app = report.app { facts.append(("版本", app)) }
        return facts
    }

    private static let note: LocalizedStringResource = "存在这台设备上，连着 iCloud 时经你自己的 iCloud 送到你的 Mac，不经别人。要发给别人时，导出诊断复制每次出事的要点；要完整原文时，再分享原始文件。"
    private static let share: LocalizedStringResource = "分享原始文件…"

    #if os(iOS)
    private var list: some View {
        List {
            Section {
                ForEach(facts, id: \.0.key) { title, value in
                    LabeledContent { Text(value).foregroundStyle(palette.ink3).multilineTextAlignment(.trailing).textSelection(.enabled) } label: { Text(title) }
                }
            }
            if !report.trail.isEmpty {
                Section("卡住前") {
                    ForEach(Array(report.trail.enumerated()), id: \.offset) { _, line in Text(verbatim: line).font(Typography.meta.monospaced()) }
                }
            }
            if !report.frames.isEmpty {
                Section(report.kind == .crash ? "崩溃线程" : "主线程") {
                    ForEach(Array(report.frames.enumerated()), id: \.offset) { _, frame in Text(verbatim: frame.text).font(Typography.meta.monospaced()) }
                }
            }
            Section {
                ExportDiagnosticsButton(text: summary)
                ShareLink(items: files) { Text(Self.share) }
            } footer: {
                Text(Self.note)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .listRowBackground(palette.paper)
        .scrollContentBackground(.hidden)
        .background(palette.desk)
    }
    #endif
}
