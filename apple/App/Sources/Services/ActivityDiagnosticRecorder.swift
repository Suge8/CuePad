import Foundation

/// 实时活动取证那一份文件（`DiagnosticArchive.activity`）只经这里改：读、追加、写回串行，同时到的两条不互相覆盖。
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
