import CueStore
import SwiftUI

/// "Cue 记得什么"（Cue 页"⋯"打开的弹层）：没忘掉的记忆分两组，"一直记着"（钉住的）与其他，各按时间从新到旧；
/// 每条能钉住或取消、能忘掉；最上面一行你自己记一条（记为你记的）。一条超过 `CueMemoryLine.maxBytes` 字节时就地说明、不写。
struct CueMemoryPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @State private var memory: CueMemory?
    @State private var text = ""
    @FocusState private var adding: Bool

    private var title: String { "\(workspace.cue.name) 记得什么" }
    private var kept: [CueMemoryLine] { (memory?.lines ?? []).filter { $0.deletedAt == nil }.reversed() }
    private var tooLong: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > CueMemoryLine.maxBytes }

    var body: some View {
        content
            .observing(services.store, into: $memory, onError: workspace.fail) { try $0.cueMemory() }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                field
                let pinned = kept.filter(\.pinned), others = kept.filter { !$0.pinned }
                if !pinned.isEmpty { group("一直记着", pinned) }
                if !others.isEmpty { group(pinned.isEmpty ? nil : "其他", others) }
                if memory != nil, kept.isEmpty {
                    Text("还没记住什么。你说过的要紧事，它会自己记下").font(Typography.secondary).foregroundStyle(palette.ink3)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
            .padding(20)
        }
        .animation(Motion.quick, value: kept.map(\.id))
        .animation(Motion.quick, value: kept.map(\.pinned))
    }

    private var field: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(palette.ink2).accessibilityHidden(true)
                TextField("记一条", text: $text).textFieldStyle(.plain).font(Typography.body)
                    .focused($adding)
                    .onSubmit(add)
                    .accessibilityLabel("记一条")
            }
            .padding(.horizontal, 14).frame(minHeight: 44)
            .paper(radius: 12)
            if tooLong {
                Text("一条最多 \(CueMemoryLine.maxBytes) 字节，拆成几条记").font(Typography.meta).foregroundStyle(palette.failure)
            }
        }
    }

    private func group(_ name: String?, _ lines: [CueMemoryLine]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name { Text(name).font(Typography.label).foregroundStyle(palette.ink3).padding(.leading, 4).accessibilityAddTraits(.isHeader) }
            VStack(spacing: 0) { ForEach(lines) { row($0) } }
                .padding(4)
                .paper(radius: 12)
        }
    }

    private func row(_ line: CueMemoryLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(line.text).font(Typography.body).foregroundStyle(palette.ink).fixedSize(horizontal: false, vertical: true)
                    .selectable()
                Text(Dotted(line.source == .known(.you) ? "你记的" : nil, DateLabel.short(line.createdAt)))
                    .font(Typography.meta).foregroundStyle(palette.ink3)
            }
            Spacer(minLength: 8)
            Button(line.pinned ? "不再一直记着" : "一直记着", systemImage: line.pinned ? "pin.fill" : "pin") {
                workspace.pinCueLine(line.id, !line.pinned)
            }
            .foregroundStyle(line.pinned ? palette.ink : palette.ink3)
            .modifier(RowIcon())
            Button("忘掉", systemImage: "xmark") { workspace.forgetCueLine(line.id) }
                .foregroundStyle(palette.ink3)
                .modifier(RowIcon())
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .transition(.opacity)
    }

    private struct RowIcon: ViewModifier {
        func body(content: Content) -> some View {
            content.labelStyle(.iconOnly).font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28).contentShape(.rect)
                .buttonStyle(PressStyle(.button))
                #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
                #endif
        }
    }

    private func add() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !tooLong else { return }
        workspace.attempt {
            try await workspace.noteCueLine(line)
            text = ""
            adding = true
        }
    }

    #if os(macOS)
    private var content: some View {
        VStack(spacing: 10) {
            PanelHeader(title)
            list
        }
        .padding(.top, 18)
        .frame(width: 480).frame(maxHeight: 600)
        .background(palette.desk)
    }
    #else
    private var content: some View {
        NavigationStack {
            list
                .background(palette.desk)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { close() } }
                }
        }
        .presentationDetents([.large])
    }
    #endif
}
