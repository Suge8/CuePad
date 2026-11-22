import Foundation

nonisolated struct DiagnosticArchive: Sendable {
    let directory: URL
    static let keep = 10
    static let keepLogs = 3
    static let logSuffix = ".log"
    static let activity = "activity.json"

    func store(_ json: Data) throws {
        guard let first = CrashReport.reports(file: "", json: json).first else { return }
        try write(json, as: Self.name(date: first.date, kind: first.kind.rawValue, suffix: ".json"))
    }

    func store(_ note: FreezeNote) throws {
        let data = try JSONEncoder.diagnostics.encode(FreezeNote.File(cuepadFreeze: note))
        try write(data, as: Self.name(date: note.start, kind: CrashReport.Kind.freeze.rawValue, suffix: ".json"))
    }

    @discardableResult
    func store(log: String, at date: Date, kind: String) throws -> String {
        let name = Self.name(date: date, kind: kind, suffix: Self.logSuffix)
        try write(Data(log.utf8), as: name)
        return name
    }

    func store(activity report: Data) throws {
        try write(report, as: Self.activity)
    }

    func reports() -> [CrashReport] {
        files().compactMap(\.reports).flatMap { $0 }.sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }

    func names() -> [String] { files().map(\.name) }

    private func files() -> [(name: String, reports: [CrashReport]?)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (String, [CrashReport]?)? in
            if name.hasSuffix(Self.logSuffix) || name == Self.activity { return (name, nil) }
            guard name.hasSuffix(".json") else { return nil }
            let reports = (try? Data(contentsOf: url(name))).map { CrashReport.reports(file: name, json: $0) } ?? []
            return reports.isEmpty ? nil : (name, reports)
        }
        .sorted { $0.0 > $1.0 }
    }

    func modified() -> [String: Date] {
        Dictionary(uniqueKeysWithValues: names().map { ($0, (try? url($0).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) })
    }

    func url(_ id: String) -> URL { directory.appending(path: id) }

    private func write(_ data: Data, as name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(name), options: .atomic)
    }

    func tidy() {
        let all = files().filter { $0.name != Self.activity }
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
