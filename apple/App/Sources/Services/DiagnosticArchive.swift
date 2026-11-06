import Foundation

/// 诊断存档：MetricKit 交来的崩溃、卡死、CPU 与磁盘写入异常（原始 JSON），与本机记下的主线程卡住（`FreezeNote`），
/// 存进一个文件夹（资料库目录下的 `Diagnostics`），只留最近 `keep` 份。不联网、不上传；用户在设置页"导出诊断"发来。
/// 每份的时间以内容为准（`CrashReport.date`），文件名是那一刻的 UTC（按名字排即按时间排）：整理时名字跟内容对不上的改名，
/// 同一份重复送达（`didReceive` 与 `pastDiagnosticPayloads`）只留一份。
nonisolated struct DiagnosticArchive: Sendable {
    let directory: URL
    static let keep = 10

    /// 存一份 `MXDiagnosticPayload.jsonRepresentation()`；没有任何诊断内容的包不存。
    func store(_ json: Data) throws {
        guard let report = CrashReport(id: "", json: json) else { return }
        try write(json, as: Self.name(report))
        tidy()
    }

    /// 写下（或更新）一条主线程卡住。卡住时主线程不动，由看守线程写：只写自己那一个文件，整理留给主线程的下一次 `store`。
    func store(_ note: FreezeNote) throws {
        let data = try JSONEncoder.diagnostics.encode(FreezeNote.File(cuepadFreeze: note))
        try write(data, as: Self.name(date: note.start, kind: .freeze))
    }

    /// 存档里的诊断，新的在前；读不出来的文件跳过。
    func reports() -> [CrashReport] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { name in (try? Data(contentsOf: url(name))).flatMap { CrashReport(id: name, json: $0) } }
            .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    func url(_ id: String) -> URL { directory.appending(path: id) }

    private func write(_ data: Data, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(name), options: .atomic)
    }

    /// 名字按内容改正（旧版把本地时间当 UTC 命名的就此改对），同名的只留一份，超过 `keep` 的删掉。
    private func tidy() {
        let files = FileManager.default
        var kept = 0
        for report in reports() {
            let name = Self.name(report)
            if kept == Self.keep || (report.id != name && files.fileExists(atPath: url(name).path)) {
                try? files.removeItem(at: url(report.id))
                continue
            }
            if report.id != name { try? files.moveItem(at: url(report.id), to: url(name)) }
            kept += 1
        }
    }

    private static func name(_ report: CrashReport) -> String { name(date: report.date, kind: report.kind) }

    /// 文件名里的时间：UTC，冒号换成短横。
    private static func name(date: Date, kind: CrashReport.Kind) -> String {
        "\(Date.ISO8601FormatStyle(timeZone: .gmt).format(date).replacing(":", with: "-"))-\(kind.rawValue).json"
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
