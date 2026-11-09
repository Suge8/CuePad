import Foundation

/// MetricKit 交来的原始 JSON、本机记下的主线程卡住（`FreezeNote`）与最近日志（`RecentLogs`）存进资料库目录下的 `Diagnostics`，只留最近 `keep` 份，
/// 其中日志至多 `keepLogs` 份（按几次"把最近日志发到 Mac"也挤不掉崩溃）。经你自己的 iCloud 送到你的 Mac（`DiagnosticOutbox`），删掉的云上也删；
/// 用户在设置页"导出诊断"发给别人。
/// 文件名以那一份的时刻（UTC）开头，按名字排就是按时间排：每份的时间以内容为准（`CrashReport.date`），同一份重复送达（`didReceive` 与
/// `pastDiagnosticPayloads`）写进同一个文件，只留一份。
/// 整理（`tidy`）只在主线程做（`Diagnostics` 每次重读存档前），看守线程写卡住记录时不碰别的文件。
nonisolated struct DiagnosticArchive: Sendable {
    let directory: URL
    static let keep = 10
    static let keepLogs = 3
    static let logSuffix = ".log"

    /// 存一份 `MXDiagnosticPayload.jsonRepresentation()`；没有任何诊断内容的包不存。
    func store(_ json: Data) throws {
        guard let first = CrashReport.reports(file: "", json: json).first else { return }
        try write(json, as: Self.name(date: first.date, kind: first.kind.rawValue, suffix: ".json"))
    }

    /// 写下（或更新）一条主线程卡住。卡住时主线程不动，由看守线程写：只写自己那一个文件。
    func store(_ note: FreezeNote) throws {
        let data = try JSONEncoder.diagnostics.encode(FreezeNote.File(cuepadFreeze: note))
        try write(data, as: Self.name(date: note.start, kind: CrashReport.Kind.freeze.rawValue, suffix: ".json"))
    }

    /// 存一份日志；`kind` 是 log（手动发的最近日志）或 freeze-log（卡住前后那一段，与卡住记录同一个时刻开头）。返回文件名。
    @discardableResult
    func store(log: String, at date: Date, kind: String) throws -> String {
        let name = Self.name(date: date, kind: kind, suffix: Self.logSuffix)
        try write(Data(log.utf8), as: name)
        return name
    }

    func reports() -> [CrashReport] {
        files().compactMap(\.reports).flatMap { $0 }.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    /// 存档里留着的全部文件名（诊断与日志），新的在前；解析不出诊断的 JSON 不算。
    func names() -> [String] { files().map(\.name) }

    private func files() -> [(name: String, reports: [CrashReport]?)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (String, [CrashReport]?)? in
            if name.hasSuffix(Self.logSuffix) { return (name, nil) }
            guard name.hasSuffix(".json") else { return nil }
            let reports = (try? Data(contentsOf: url(name))).map { CrashReport.reports(file: name, json: $0) } ?? []
            return reports.isEmpty ? nil : (name, reports)
        }
        .sorted { $0.0 > $1.0 }
    }

    /// 每个文件（同 `names`）最后改写的时刻。
    func modified() -> [String: Date] {
        Dictionary(uniqueKeysWithValues: names().map { ($0, (try? url($0).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) })
    }

    func url(_ id: String) -> URL { directory.appending(path: id) }

    private func write(_ data: Data, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(name), options: .atomic)
    }

    func tidy() {
        let all = files()
        let logs = all.filter { $0.reports == nil }.map(\.name)
        let dropped = Set(logs.dropFirst(Self.keepLogs))
        for name in all.map(\.name).filter({ !dropped.contains($0) }).dropFirst(Self.keep) + dropped {
            try? FileManager.default.removeItem(at: url(name))
        }
    }

    private static func name(date: Date, kind: String, suffix: String) -> String {
        "\(Date.ISO8601FormatStyle(timeZone: .gmt).format(date).replacing(":", with: "-"))-\(kind)\(suffix)"
    }
}

extension JSONEncoder {
    nonisolated static var diagnostics: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    nonisolated static var diagnostics: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
