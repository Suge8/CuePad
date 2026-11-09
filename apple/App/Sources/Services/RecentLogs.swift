import CueStore
import Foundation
import OSLog

/// 这个进程自己写下的、子系统是 App 身份的日志（`OSLogStore` 只读本进程这次运行的，读不到上次的），一行一条、旧的在前。
/// 标成私密的值系统已换成 `<private>`，照原样，不绕开。读一次要扫这段时间本进程的全部日志，在主线程以外调。
nonisolated enum RecentLogs {
    /// "把最近日志发到 Mac"取多久：够覆盖一次复现，又不至于在上限里被截掉大半。
    static let window: TimeInterval = 15 * 60
    /// 超过就丢最早的：一条诊断记录连字段不超过 1MB（`DeviceDiagnostic.maxBytes`）。
    static let maxBytes = 512 * 1024

    /// `title` 写在第一行（哪种日志、哪个版本），其后是时间段与条数。
    static func text(from start: Date, to end: Date = .now, title: String) throws -> String {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: start), matching: NSPredicate(format: "subsystem == %@", AppIdentity.id))
        var lines: [String] = [], bytes = 0
        for case let entry as OSLogEntryLog in entries {
            guard entry.date <= end else { break }
            guard entry.date >= start else { continue }
            let line = "\(entry.date.formatted(stamp)) \(level(entry.level)) [\(entry.category)] \(entry.composedMessage)"
            lines.append(line)
            bytes += line.utf8.count + 1
        }
        var dropped = 0
        while bytes > maxBytes, !lines.isEmpty {
            bytes -= lines.removeFirst().utf8.count + 1
            dropped += 1
        }
        let span = "\(start.formatted(stamp)) – \(end.formatted(stamp))"
        let head = "# \(title) | \(span) | \(lines.count) 条" + (dropped > 0 ? "（超过上限，丢了最早的 \(dropped) 条）" : "")
        return ([head] + lines).joined(separator: "\n") + "\n"
    }

    private static let stamp = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(3))",
        timeZone: .current, calendar: Calendar(identifier: .gregorian))

    private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "Debug"
        case .info: "Info"
        case .notice: "Notice"
        case .error: "Error"
        case .fault: "Fault"
        default: "Default"
        }
    }
}
