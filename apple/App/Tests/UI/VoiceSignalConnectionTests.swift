import CryptoKit
import Foundation
import Testing
@testable import CuePad

@MainActor struct VoiceSignalConnectionTests {
    /// 同一设备每次连上都换新租约；收过的包、已换绑或已退役的旧租约发来的包都打不开，新租约的照常打开。
    @Test func replayedAndStaleLeasePacketsAreRefused() throws {
        let key = SymmetricKey(size: .bits256)
        let a = VoiceSignalConnection(room: "isolated", challenge: "same", device: .init("a"), key: key)
        let a2 = VoiceSignalConnection(room: "isolated", challenge: "same", device: .init("a"), key: key)
        let b = VoiceSignalConnection(room: "isolated", challenge: "same", device: .init("b"), key: key)
        #expect(a.claim.endpoint != a2.claim.endpoint)
        for c in [a, a2, b] { try c.acceptRegistration(c.claim.endpoint) }
        try a.bind(b.claim.endpoint); try a2.bind(b.claim.endpoint); try b.bind(a.claim.endpoint)
        let session = VoiceSessionID(UUID())
        let old = try a.seal(.media(signal: .hangup(reason: .hungUp)), session: session, to: b.claim.endpoint, now: 1000)
        _ = try b.open(old, now: 1001)
        #expect(throws: (any Error).self) { try b.open(old, now: 1001) }
        try b.bind(a2.claim.endpoint)
        #expect(throws: (any Error).self) { try b.open(old, now: 1001) }
        let fresh = try a2.seal(.media(signal: .hangup(reason: .hungUp)), session: VoiceSessionID(UUID()), to: b.claim.endpoint, now: 1001)
        _ = try b.open(fresh, now: 1002)
        try b.retire(a.claim.endpoint)
        let next = try a2.seal(.media(signal: .hangup(reason: .hungUp)), session: session, to: b.claim.endpoint, now: 1002)
        _ = try b.open(next, now: 1003)
    }
}
