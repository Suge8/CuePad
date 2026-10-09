import CueStore
import Foundation

/// 改会话名：发一条 Pi 的内置斜杠命令 `/name <新名>`（投送方式 `command`，与回复框里的斜杠命令同一条路，已结束的会话 Mac 先在后台恢复）。
/// 会话名只来自 Pi（会话记录的 `title`，规则 `PiSessionName`），界面不另存；改名在路上时行上的名字由这条请求推出（`title`）。
nonisolated enum PiRename {
    private static let prefix = "/name "

    /// 新名写成的命令；只留一行（Pi 的会话名是单行），空的是 nil。
    static func line(_ name: String) -> String? {
        let name = name.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : prefix + name
    }

    /// 这条请求要改成的名字；不是改名的为 nil（回复框里手打的 /name 也算）。
    static func name(in request: DeliveryRequest) -> String? {
        guard request.mode == .known(.command), request.content.hasPrefix(prefix) else { return nil }
        let name = request.content.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// 此刻显示的会话名：发给它的最近一条（`request`）是改名、还在路上时是新名；送到了而会话记录在那之后还没写过
    /// （Pi 改了名、Mac 还没同步过来）也是新名；之后、以及没改成时以会话记录为准。
    static func title(of session: PiSessionState, request: DeliveryRequest?) -> String {
        guard let request, let name = name(in: request) else { return session.title }
        switch request.status.known {
        case .pending, .executing: return name
        case .succeeded: return session.modifiedAt > (request.completedAt ?? request.createdAt) ? session.title : name
        case .failed, nil: return session.title
        }
    }
}

extension AppServices {
    /// 让 Pi 把会话改名（写一条发给它所在 Mac 的命令请求，立即上传）。新名为空时不写。
    @discardableResult
    func rename(_ session: PiSessionState, to name: String) async throws -> DeliveryRequest {
        guard let line = PiRename.line(name) else { throw CueStoreError.blankDeliveryContent }
        return try await requestMacDelivery(line, to: session, mode: .command)
    }
}
