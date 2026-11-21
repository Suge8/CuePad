import Foundation

actor ActivityDiagnosticRecorder {
    private let archive: DiagnosticArchive

    init(archive: DiagnosticArchive) {
        self.archive = archive
    }

    func record(_ event: ActivityDiagnosticReport.Event) throws {
        let file = archive.url(DiagnosticArchive.activity)
        var report = FileManager.default.fileExists(atPath: file.path)
            ? try JSONDecoder.diagnostics.decode(ActivityDiagnosticReport.self, from: Data(contentsOf: file))
            : ActivityDiagnosticReport()
        report.append(event)
        try archive.store(activity: JSONEncoder.diagnostics.encode(report))
    }
}
