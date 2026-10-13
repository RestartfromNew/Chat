import Foundation
import Testing
@testable import Chat

struct DoubleRatchetTests {
    private func pair() throws -> (RatchetState, RatchetState) {
        let secret = Data(repeating: 0x55, count: 32), bob = try DeviceKeyCrypto.privateKey()
        return (try DoubleRatchet.initiator(secret: secret, remote: DeviceKeyCrypto.publicKey(bob)),
                DoubleRatchet.responder(secret: secret, signedPrivate: bob))
    }
    private func send(_ text: String, _ state: inout RatchetState) throws -> RatchetPacket {
        let (updated, bytes) = try DoubleRatchet.seal(text, state: state, session: UUID(), message: UUID(),
            sender: UUID(), local: UUID(), friend: UUID(), remote: UUID(), bootstrap: nil)
        state = updated
        return try JSONCodec.decoder().decode(RatchetPacket.self, from: bytes)
    }
    @Test func bidirectionalDHRatchetAndDelayedOldChainMessages() throws {
        var (alice, bob) = try pair()
        let a0 = try send("A0", &alice), a1 = try send("A1", &alice), a2 = try send("A2", &alice)
        #expect(a0.header.dh == a2.header.dh && a2.header.n == 2)
        let b2 = try DoubleRatchet.open(a2, state: bob); bob = b2.0
        #expect(b2.1 == "A2" && bob.skipped.count == 2)
        let reply = try send("B0", &bob)
        let aReply = try DoubleRatchet.open(reply, state: alice); alice = aReply.0
        #expect(aReply.1 == "B0")
        let a3 = try send("A3", &alice)
        #expect(a3.header.dh != a2.header.dh && a3.header.n == 0 && a3.header.pn == 3)
        bob = try DoubleRatchet.open(a3, state: bob).0
        let late0 = try DoubleRatchet.open(a0, state: bob); bob = late0.0
        #expect(late0.1 == "A0")
        let late1 = try DoubleRatchet.open(a1, state: bob); bob = late1.0
        #expect(late1.1 == "A1" && bob.skipped.isEmpty)
        #expect(throws: (any Error).self) { try DoubleRatchet.open(a0, state: bob) }
        for i in 0..<8 {
            let b = try send("B\(i)", &bob)
            alice = try DoubleRatchet.open(b, state: alice).0
            let a = try send("A\(i)", &alice)
            bob = try DoubleRatchet.open(a, state: bob).0
        }
    }
    @Test func tamperingDoesNotConsumeStateAndReplayFails() throws {
        var (alice, bob) = try pair()
        let packet = try send("secret", &alice), original = bob
        var sealed = packet.sealed; sealed[sealed.count - 1] ^= 1
        let tampered = RatchetPacket(header: packet.header, aad: packet.aad, sealed: sealed)
        #expect(throws: (any Error).self) { try DoubleRatchet.open(tampered, state: bob) }
        #expect(bob == original)
        bob = try DoubleRatchet.open(packet, state: bob).0
        #expect(throws: (any Error).self) { try DoubleRatchet.open(packet, state: bob) }
    }
    @Test func skipLimitAndArchiveRoundTrip() throws {
        var (alice, bob) = try pair()
        var last = try send("0", &alice)
        for _ in 0..<201 { last = try send("skip", &alice) }
        #expect(throws: (any Error).self) { try DoubleRatchet.open(last, state: bob) }
        let encoded = try JSONEncoder().encode(alice)
        #expect(try JSONDecoder().decode(RatchetState.self, from: encoded) == alice)
        #expect(bob.nr == 0 && bob.remotePublic == nil)
    }
}
