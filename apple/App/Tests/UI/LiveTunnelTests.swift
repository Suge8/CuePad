import CryptoKit
import Foundation
import Network
import Testing
@testable import CuePad

/// 隧道本身（两端各一份 `LiveTunnel`）：同一把 PSK 握得上、协商的是带前向保密的那一套，错的密钥与票据进不来。iOS 模拟器与 Mac 上都跑。
@Suite struct LiveTunnelTests {
    let key = SymmetricKey(size: .bits256)
    let ticket = Data((0..<16).map { _ in UInt8.random(in: 0...255) })

    private func server(key: SymmetricKey) async throws -> (LiveTunnel.Server, UInt16) {
        let ticket = ticket
        let server = try LiveTunnel.Server(key: key) { request in request.ticket == ticket ? .probe : .ticket }
        return (server, try await server.start())
    }

    private func probe(port: UInt16, key: SymmetricKey, ticket: Data) async throws -> (LiveTunnel.Answer?, UInt16?) {
        let connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: LiveTunnel.parameters(key: key))
        defer { connection.cancel() }
        try await connection.established(within: .seconds(5))
        let suite = (connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata)
            .map { sec_protocol_metadata_get_negotiated_tls_ciphersuite($0.securityProtocolMetadata).rawValue }
        try await connection.write(LiveTunnel.Request(ticket: ticket, host: "", port: 0).encoded)
        return (try await connection.read(1).first.flatMap(LiveTunnel.Answer.init), suite)
    }

    @Test func 同一把密钥握得上_协商ECDHE_PSK_CHACHA20_票据认得才放行() async throws {
        let (server, port) = try await server(key: key)
        defer { server.cancel() }
        let (answer, suite) = try await probe(port: port, key: key, ticket: ticket)
        #expect(suite == 0xCCAC)
        #expect(answer == .open)
        let (other, _) = try await probe(port: port, key: key, ticket: Data(count: 16))
        #expect(other == .ticket)
    }

    /// 验过票、还在连开发服务与写放行的这一会儿，手机走了、票据作废：这一条不放行，也不留在隧道口的账上。
    @Test func 验票之后_登记之前票据作废_这条不放行() async throws {
        let holder = Holder(), ticket = ticket
        let server = try LiveTunnel.Server(key: key) { request in
            guard request.ticket == ticket else { return .ticket }
            holder.server?.keep([])
            // 连回隧道口自己：只要有个在听的口
            return .open(host: "127.0.0.1", port: holder.port)
        }
        holder.server = server
        holder.port = try await server.start()
        defer { server.cancel() }
        let connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: holder.port)!, using: LiveTunnel.parameters(key: key))
        defer { connection.cancel() }
        try await connection.established(within: .seconds(5))
        try await connection.write(LiveTunnel.Request(ticket: ticket, host: "localhost", port: holder.port).encoded)
        let answer = (try? await connection.read(1))?.first.flatMap(LiveTunnel.Answer.init)
        #expect(answer != .open)
        #expect(server.connections == 0)
    }

    nonisolated final class Holder: @unchecked Sendable {
        var server: LiveTunnel.Server?
        var port: UInt16 = 0
    }

    @Test func 密钥不对握不上() async throws {
        let (server, port) = try await server(key: key)
        defer { server.cancel() }
        await #expect(throws: (any Error).self) { try await probe(port: port, key: SymmetricKey(size: .bits256), ticket: ticket) }
    }
}
