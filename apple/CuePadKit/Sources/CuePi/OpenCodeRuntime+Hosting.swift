#if os(macOS)
import CueStore
import Foundation
import OSLog

extension OpenCodeRuntime {
    public func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID {
        let connection = try await ensureService()
        struct Create: Encodable { var location: OpenCodeLocation }
        let data = try await connection.client.call(
            "POST", "/api/session", body: Create(location: OpenCodeLocation(directory: directory.path(percentEncoded: false))))
        let info = try JSONDecoder().decode(OpenCodeData<OpenCodeSessionInfo>.self, from: data).data
        let id = try await host(info, connection) {
            $0.hosted = true
            $0.launchToken = launchToken
        }
        let sessionID = info.id
        do {
            return try await configure(opened: id, name: name, model: model, thinking: thinking, on: bridge)
        } catch {
            // 配不上时结束只让它下线，会话还在服务里：开会话失败的不留，从服务里删掉
            _ = try? await connection.client.call("DELETE", "/api/session/\(sessionID)")
            throw error
        }
    }

    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        let connection = try await ensureService()
        let online = sessions[session.id]?.online == true
        let info: OpenCodeSessionInfo
        do {
            info = try await connection.client.get(OpenCodeData<OpenCodeSessionInfo>.self, "/api/session/\(session.id)").data
        } catch let error as OpenCodeAPIError where error.status == 404 {
            throw PiBridgeError.unknownSession(session.id)
        }
        return try await host(info, connection) { if !online { $0.hosted = true } }
    }

    /// 让 CuePad 托管的会话上线；已经在线的（比如终端里正开着）不算托管。
    func host(_ info: OpenCodeSessionInfo, _ connection: Connection, _ body: (inout Tracked) -> Void) async throws -> PiSession.ID {
        guard self.connection === connection else { throw PiBridgeError.sessionEnded }
        var tracked = sessions[info.id] ?? Tracked(info: info)
        tracked.online = true
        ended[info.id] = nil
        body(&tracked)
        sessions[info.id] = tracked
        listed?.insert(info.id)
        try await catalog(info.location.directory, connection.client)
        publish(info.id)
        return bridgeID(info.id, connection)
    }

    /// 连着的服务；没开就把它拉起来，等连上、拉完快照。
    func ensureService() async throws -> Connection {
        if connection == nil {
            try await launchService()
            refresh()
        }
        // 起服务期间登记文件的变化可能已经让它连上、拉完快照
        if let connection, connection.ready { return connection }
        let id = UUID()
        let timeout = Task { [weak self] in
            guard (try? await Task.sleep(for: AgentTimeouts.launch)) != nil else { return }
            self?.waiters.removeValue(forKey: id)?.resume(throwing: AgentRuntimeError.launchTimedOut(.opencode))
        }
        defer { timeout.cancel() }
        return try await withCheckedThrowingContinuation { waiters[id] = $0 }
    }

    /// `opencode service start`：起后台服务、写好登记文件才返回（实测约 0.2 秒）。服务自成一个会话（不在这条命令的进程组里，
    /// 超时结束整组碰不到它），标准输入输出指到 /dev/null（不握着这边的管道）：实测 2.0.25。
    private func launchService() async throws {
        guard let executable = await opencode() else { throw AgentRuntimeError.notInstalled(.opencode) }
        let locator = await locate()
        // 服务常驻，它起的工具也用这个 PATH
        let environment = locator.environment(launching: executable, overrides: paths.environment)
        guard let result = await ChildProcess.run(executable, ["service", "start"], environment: environment, timeout: AgentTimeouts.launch, collect: false)
        else { throw AgentRuntimeError.launchTimedOut(.opencode) }
        guard result.status == 0 else { throw AgentRuntimeError.launchFailed(.opencode, "opencode service start 退出码 \(result.status)") }
        startedService = (executable, environment)
    }
}
#endif
