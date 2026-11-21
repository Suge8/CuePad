#if os(macOS)
import CryptoKit
import CueStore
import Foundation

public struct PiPaths: Sendable, Equatable {
    public var agentDirectory: URL
    /// 桥 socket 目录。`sun_path` 上限 104 字节，所以不用 `$TMPDIR`。
    public var socketDirectory: URL

    public var sessionsDirectory: URL { agentDirectory.appending(path: "sessions", directoryHint: .isDirectory) }
    public var binDirectory: URL
    public var isExplicit: Bool

    public init(
        agentDirectory: URL? = nil,
        socketDirectory: URL? = nil,
        binDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.agentDirectory = agentDirectory ?? Self.defaultAgentDirectory(environment)
        self.socketDirectory = socketDirectory ?? Self.socketDirectory(environment: environment)
        let binOverride = environment["CUEPAD_BIN_DIR"].flatMap { $0.isEmpty ? nil : URL(filePath: UserHome.expanding($0), directoryHint: .isDirectory) }
        self.binDirectory = binDirectory ?? binOverride
            ?? UserHome.directory.appending(path: ".local/bin", directoryHint: .isDirectory)
        let agentGiven = agentDirectory != nil || !(environment[PiRuntime.facts.homeVariable] ?? "").isEmpty
        isExplicit = agentGiven && (binDirectory != nil || binOverride != nil)
    }

    public var launchEnvironment: [String: String] {
        var environment = ["CUEPAD_PI_SOCKET_DIR": socketDirectory.path]
        if !isDefaultAgentDirectory {
            environment[PiRuntime.facts.homeVariable] = agentDirectory.path
        }
        return environment
    }

    public static func socketDirectory(environment: [String: String], isolatedLibrary: URL? = nil) -> URL {
        if let given = environment["CUEPAD_PI_SOCKET_DIR"], !given.isEmpty { return URL(filePath: given, directoryHint: .isDirectory) }
        let suffix = isolatedLibrary.map { "-" + Insecure.SHA1.hash(data: Data($0.standardizedFileURL.path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined() } ?? ""
        return URL(filePath: "/tmp/cuepad-\(getuid())\(suffix)", directoryHint: .isDirectory)
    }

    private var isDefaultAgentDirectory: Bool {
        agentDirectory.standardizedFileURL == Self.defaultAgentDirectory([:]).standardizedFileURL
    }

    private static func defaultAgentDirectory(_ environment: [String: String]) -> URL {
        if let dir = environment[PiRuntime.facts.homeVariable], !dir.isEmpty {
            return URL(filePath: UserHome.expanding(dir), directoryHint: .isDirectory)
        }
        return UserHome.directory.appending(path: ".pi/agent", directoryHint: .isDirectory)
    }
}
#endif
