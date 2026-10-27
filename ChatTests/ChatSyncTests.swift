import Foundation
import Testing
@testable import Chat

private final class ChatMemoryStore: CredentialStore {
    var data: Data?
    var fail = false
    var reads = 0
    var writes = 0
    var accessedMainThread = false
    func read() throws -> Data? { reads += 1; accessedMainThread = accessedMainThread || Thread.isMainThread; return data }
    func write(_ data: Data) throws { writes += 1; accessedMainThread = accessedMainThread || Thread.isMainThread; if fail { throw ClientError(message: "disk full") }; self.data = data }
    func delete() throws { data = nil }
}
@MainActor struct ChatSyncTests {
    private struct Fixture {
        var alice: LocalDeviceKeys
        var bob: LocalDeviceKeys
        let aUser: UUID
        let bUser: UUID
        let aDevice: FriendDevice
        let bDevice: FriendDevice
        let seed: CachedPrekey
        let a: ChatStore
        let b: ChatStore
        let aMemory: ChatMemoryStore
        let bMemory: ChatMemoryStore
    }
    private func fixture() async throws -> Fixture {
        var alice = try LocalDeviceKeys.generate(), bob = try LocalDeviceKeys.generate()
        alice.deviceId = UUID(); alice.phase = .registered; bob.deviceId = UUID(); bob.phase = .registered
        bob.oneTimePrekeys = [.init(id: 1001, privateKey: try DeviceKeyCrypto.privateKey(), upload: .uploaded)]
        let au = UUID(), bu = UUID()
        func device(_ keys: LocalDeviceKeys) throws -> FriendDevice {
            FriendDevice(deviceId: keys.deviceId!, deviceName: "test", status: "active",
                identityPublicKeyHex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(keys.identityPrivate)), protocolSuite: DeviceKeyCrypto.suite)
        }
        let ad = try device(alice), bd = try device(bob)
        let bundle = SignedPrekeyMaterial(protocolSuite: DeviceKeyCrypto.suite, identityPublicKeyHex: bd.identityPublicKeyHex,
            signedPrekeyId: "42", signedPrekeyPublicHex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(bob.signedPrekeyPrivate)), signedPrekeySignatureHex: DeviceKeyCrypto.hex(bob.signature))
        let claim = ClaimedPrekey(friendId: bu, deviceId: bd.id, prekeyId: 1001, publicKeyHex: DeviceKeyCrypto.hex(try DeviceKeyCrypto.publicKey(bob.oneTimePrekeys[0].privateKey)))
        let seed = CachedPrekey(phase: .cached, identityHex: bd.identityPublicKeyHex, suite: DeviceKeyCrypto.suite,
            value: claim, check: PrekeyCheckState(bundle: bundle, ephemeralPrivate: try DeviceKeyCrypto.privateKey()), bundle: bundle)
        let am = ChatMemoryStore(), bm = ChatMemoryStore(), a = ChatStore(storage: am), b = ChatStore(storage: bm)
        try await a.bind(scope: "server", user: au, device: ad.id); try await b.bind(scope: "server", user: bu, device: bd.id)
        try await a.remember(user: bu, devices: [bd]); try await b.remember(user: au, devices: [ad])
        return Fixture(alice: alice, bob: bob, aUser: au, bUser: bu, aDevice: ad, bDevice: bd, seed: seed, a: a, b: b, aMemory: am, bMemory: bm)
    }
    private func envelope(_ item: ChatOutgoing, from: UUID, seq: Int64 = 1) -> IncomingEnvelope {
        IncomingEnvelope(envelopeId: UUID(), messageId: item.messageId, senderDeviceId: from, recipientDeviceId: item.target,
            protocolVersion: DoubleRatchet.version, packetBase64: item.packet.base64EncodedString(), seq: seq)
    }
    @Test func friendFanoutIncludesOwnDeviceCopyWithoutForwarding() async throws {
        let f = try await fixture(), other = try await fixture()
        try await other.b.bind(scope: "own-copy", user: f.aUser, device: other.bDevice.id)
        try await other.b.remember(user: f.aUser, devices: [f.aDevice])
        try await f.a.remember(user: f.aUser, devices: [other.bDevice])
        var ownSeed = other.seed
        let original = try #require(ownSeed.value)
        ownSeed.value = ClaimedPrekey(friendId: f.aUser, deviceId: original.deviceId, prekeyId: original.prekeyId, publicKeyHex: original.publicKeyHex)
        let id = try await f.a.prepareMessage(text: "同步给我的平板", friend: f.bUser, targets: [f.bDevice], ownTargets: [other.bDevice],
            seeds: [f.bDevice.id: f.seed, other.bDevice.id: ownSeed], local: f.alice)
        #expect(f.a.archive.outgoing.count == 2)
        for item in f.a.archive.outgoing.values {
            let receiver = item.target == f.bDevice.id ? f.b : other.b
            let keys = item.target == f.bDevice.id ? f.bob : other.bob
            try await receiver.ingest([envelope(item, from: f.aDevice.id)], advanceCursors: false)
            try await receiver.decryptPending(local: keys)
        }
        #expect(f.b.archive.messages[id]?.outgoing == false)
        #expect(other.b.archive.messages[id]?.outgoing == true)
        #expect(other.b.archive.messages[id]?.friend == f.bUser)
        #expect(other.b.archive.messages[id]?.text == "同步给我的平板")
        #expect(other.b.archive.outgoing.isEmpty)
    }
    @Test func liveBatchDecryptsOnceAndSyncReplayPreservesRatchet() async throws {
        let f = try await fixture()
        var envelopes: [IncomingEnvelope] = []
        for seq in 1...3 {
            let id = try await f.a.prepareMessage(text: "live \(seq)", friend: f.bUser, targets: [f.bDevice], seeds: [f.bDevice.id: f.seed], local: f.alice)
            let item = try #require(f.a.archive.outgoing.values.first { $0.messageId == id })
            envelopes.append(envelope(item, from: f.aDevice.id, seq: Int64(seq)))
        }
        try await f.b.ingest(envelopes, advanceCursors: false)
        #expect(f.b.archive.cursors.isEmpty)
        let writes = f.bMemory.writes
        try await f.b.decryptPending(local: f.bob)
        #expect(f.bMemory.writes == writes + 1)
        #expect(f.b.archive.messages.count == 3)
        let state = try #require(f.b.session(for: f.aDevice.id)).ratchet
        try await f.b.confirm(envelopes.map(\.envelopeId))
        try await f.b.ingest(envelopes, advanceCursors: true)
        try await f.b.decryptPending(local: f.bob)
        #expect(f.b.archive.cursors[f.aDevice.id] == 3)
        #expect(f.b.session(for: f.aDevice.id)?.ratchet == state)
        #expect(f.b.archive.messages.count == 3)
        #expect(f.bMemory.reads == 1)
        #expect(!f.bMemory.accessedMainThread && !f.aMemory.accessedMainThread)
    }
    @Test func twoDevicesDecryptReplyAndRestorePersistedSessions() async throws {
        let f = try await fixture()
        let first = try await f.a.prepareMessage(text: "你好 Bob", friend: f.bUser, targets: [f.bDevice], seeds: [f.bDevice.id: f.seed], local: f.alice)
        let item = try #require(f.a.archive.outgoing.values.first)
        let e = envelope(item, from: f.aDevice.id)
        #expect(!String(decoding: item.packet, as: UTF8.self).contains("你好 Bob"))
        try await f.b.ingest([e], advanceCursors: true)
        #expect(f.b.archive.messages.isEmpty && f.b.archive.cursors[f.aDevice.id] == 1)
        try await f.b.decryptPending(local: f.bob)
        #expect(f.b.archive.messages[first]?.text == "你好 Bob")
        try await f.b.confirm([e.envelopeId])
        let restored = ChatStore(storage: f.bMemory)
        try await restored.bind(scope: "server", user: f.bUser, device: f.bDevice.id)
        let replyId = try await restored.prepareMessage(text: "你好 Alice", friend: f.aUser, targets: [f.aDevice], seeds: [:], local: f.bob)
        let reply = try #require(restored.archive.outgoing.values.first)
        try await f.a.ingest([envelope(reply, from: f.bDevice.id, seq: 2)], advanceCursors: true)
        try await f.a.decryptPending(local: f.alice)
        #expect(f.a.archive.messages[replyId]?.text == "你好 Alice")
        #expect(restored.archive.inbox[e.envelopeId]?.acknowledged == true)
        let before = f.b.archive.sessions
        try await f.b.ingest([e], advanceCursors: true); try await f.b.decryptPending(local: f.bob)
        #expect(f.b.archive.messages.count == 1 && f.b.archive.sessions.count == before.count)
    }
    @Test func failedWriteDoesNotAdvanceRatchetAndRetryRetainsBytes() async throws {
        let f = try await fixture()
        f.aMemory.fail = true
        await #expect(throws: (any Error).self) { try await f.a.prepareMessage(text: "fail", friend: f.bUser, targets: [f.bDevice], seeds: [f.bDevice.id: f.seed], local: f.alice) }
        #expect(f.a.archive.sessions.isEmpty && f.a.archive.outgoing.isEmpty)
        f.aMemory.fail = false
        _ = try await f.a.prepareMessage(text: "saved", friend: f.bUser, targets: [f.bDevice], seeds: [f.bDevice.id: f.seed], local: f.alice)
        let item = try #require(f.a.archive.outgoing.values.first)
        try await f.a.failed(item, error: URLError(.timedOut))
        let restored = ChatStore(storage: f.aMemory); try await restored.bind(scope: "server", user: f.aUser, device: f.aDevice.id)
        #expect(restored.archive.outgoing[item.id]?.packet == item.packet)
        let frame = try JSONSerialization.jsonObject(with: restored.outgoingFrame(item, token: "new-token")) as! [String: String]
        #expect(frame["authorization"] == "Bearer new-token" && frame["packet_base64"] == item.packet.base64EncodedString())
        try await restored.accepted(item, receipt: .init(messageId: item.messageId, envelopeId: UUID(), seq: 99, duplicate: true))
        #expect(restored.archive.cursors.isEmpty)
    }
    @Test func tamperIsSavedAckableButNoPlaintextOrRatchetCommit() async throws {
        let f = try await fixture()
        _ = try await f.a.prepareMessage(text: "secret", friend: f.bUser, targets: [f.bDevice], seeds: [f.bDevice.id: f.seed], local: f.alice)
        let item = try #require(f.a.archive.outgoing.values.first)
        let packet = try JSONCodec.decoder().decode(RatchetPacket.self, from: item.packet)
        var sealed = packet.sealed; sealed[sealed.count - 1] ^= 1
        let bad = try DoubleRatchet.encode(RatchetPacket(header: packet.header, aad: packet.aad, sealed: sealed))
        let e = IncomingEnvelope(envelopeId: UUID(), messageId: item.messageId, senderDeviceId: f.aDevice.id,
            recipientDeviceId: f.bDevice.id, protocolVersion: DoubleRatchet.version, packetBase64: bad.base64EncodedString(), seq: 3)
        try await f.b.ingest([e], advanceCursors: true); try await f.b.decryptPending(local: f.bob); try await f.b.confirm([e.envelopeId])
        #expect(f.b.archive.messages.isEmpty && f.b.archive.sessions.isEmpty && f.b.archive.usedPrekeys.isEmpty)
        #expect(f.b.archive.inbox[e.envelopeId]?.error != nil && f.b.archive.inbox[e.envelopeId]?.acknowledged == true)
        try await f.b.ingest([envelope(item, from: f.aDevice.id, seq: 4)], advanceCursors: true); try await f.b.decryptPending(local: f.bob)
        #expect(f.b.archive.messages[item.messageId]?.text == "secret")
    }
    @Test func pushDoesNotSkipOfflineHistoryAndAckSubsetStaysPending() async throws {
        let f = try await fixture()
        _ = try await f.a.prepareMessage(text: "first", friend: f.bUser, targets: [f.bDevice], seeds: [f.bDevice.id: f.seed], local: f.alice)
        _ = try await f.a.prepareMessage(text: "second", friend: f.bUser, targets: [f.bDevice], seeds: [:], local: f.alice)
        let items = Array(f.a.archive.outgoing.values)
        let e0 = envelope(items[0], from: f.aDevice.id, seq: 1), e1 = envelope(items[1], from: f.aDevice.id, seq: 7)
        try await f.b.ingest([e1], advanceCursors: false)
        #expect(f.b.archive.cursors.isEmpty)
        try await f.b.ingest([e0, e1], advanceCursors: true)
        try await f.b.confirm([e0.envelopeId])
        #expect(f.b.archive.cursors[f.aDevice.id] == 7 && f.b.archive.inbox[e1.envelopeId]?.acknowledged == false)
        let ack = EnvelopeAck(deviceId: f.bDevice.id, count: 1, acknowledgedIds: [e0.envelopeId])
        try ack.validate(device: f.bDevice.id, requested: [e0.envelopeId, e1.envelopeId])
        #expect(throws: (any Error).self) { try ack.validate(device: UUID(), requested: [e0.envelopeId]) }
    }
    @Test func untrustedOrUnsupportedPacketsAreNotShownAsPlaintext() async throws {
        let f = try await fixture()
        let e = IncomingEnvelope(envelopeId: UUID(), messageId: UUID(), senderDeviceId: UUID(), recipientDeviceId: f.bDevice.id,
            protocolVersion: "unknown", packetBase64: Data([1]).base64EncodedString(), seq: 1)
        try await f.b.ingest([e], advanceCursors: true); try await f.b.decryptPending(local: f.bob)
        #expect(f.b.archive.messages.isEmpty && f.b.archive.inbox[e.envelopeId]?.error != nil)
        let previous = f.b.archive.inbox.count
        f.bMemory.fail = true
        await #expect(throws: (any Error).self) { try await f.b.ingest([.init(envelopeId: UUID(), messageId: UUID(), senderDeviceId: UUID(), recipientDeviceId: f.bDevice.id, protocolVersion: "unknown", packetBase64: "AQ==", seq: 5)], advanceCursors: true) }
        #expect(f.b.archive.inbox.count == previous)
    }
    @Test func bootstrapSecretsAreRetiredWithoutReusingOPKNumbers() async throws {
        let f = try await fixture()
        _ = try await f.a.prepareMessage(text: "one", friend: f.bUser, targets: [f.bDevice], seeds: [f.bDevice.id: f.seed], local: f.alice)
        let first = try #require(f.a.archive.outgoing.values.first)
        try await f.b.ingest([envelope(first, from: f.aDevice.id)], advanceCursors: true)
        try await f.b.decryptPending(local: f.bob)
        let retired = try #require(f.b.retiringBootstrapMaterial(f.bob))
        #expect(retired.oneTimePrekeys.first?.id == 1001 && retired.oneTimePrekeys.first?.privateKey.isEmpty == true)
        var withSeed = f.alice; withSeed.claims["seed"] = f.seed
        #expect(f.a.retiringBootstrapMaterial(withSeed)?.claims.isEmpty == true)
        let secondId = try await f.a.prepareMessage(text: "two", friend: f.bUser, targets: [f.bDevice], seeds: [:], local: f.alice)
        let second = try #require(f.a.archive.outgoing.values.first { $0.messageId == secondId })
        try await f.b.ingest([envelope(second, from: f.aDevice.id, seq: 2)], advanceCursors: true)
        try await f.b.decryptPending(local: retired)
        #expect(f.b.archive.messages[secondId]?.text == "two")
        let fresh = ChatStore(storage: ChatMemoryStore())
        try await fresh.bind(scope: "server", user: f.aUser, device: f.aDevice.id); try await fresh.remember(user: f.bUser, devices: [f.bDevice])
        _ = try await fresh.prepareMessage(text: "reused OPK", friend: f.bUser, targets: [f.bDevice], seeds: [f.bDevice.id: f.seed], local: f.alice)
        let reused = try #require(fresh.archive.outgoing.values.first)
        let rejected = envelope(reused, from: f.aDevice.id, seq: 3)
        try await f.b.ingest([rejected], advanceCursors: true); try await f.b.decryptPending(local: f.bob)
        #expect(f.b.archive.messages[reused.messageId] == nil && f.b.archive.inbox[rejected.envelopeId]?.error != nil)
    }
    @Test func delayedVaultWriteCannotResurrectRetiredSecrets() async throws {
        let f = try await fixture(), vault = DeviceKeyVault(store: ChatMemoryStore())
        var old = f.bob
        old.claims["pending"] = f.seed
        try vault.save(old, scope: "bob")
        var retired = old
        retired.oneTimePrekeys = [.init(id: 1001, privateKey: Data(), upload: .uploaded)]
        retired.retiredClaimDevices = [f.bDevice.id]; retired.claims = [:]
        try vault.save(retired, scope: "bob")
        try vault.save(old, scope: "bob") // Simulate completion of a request started before retirement.
        let restored = try #require(try vault.load("bob"))
        #expect(restored.oneTimePrekeys[0].privateKey.isEmpty && restored.claims.isEmpty)
        let coordinator = DeviceCoordinator(vault: vault)
        try await coordinator.upload(scope: "bob") { request in
            #expect(request.prekeys.map(\.prekey_id).min() == 1002)
            return PrekeyUploadResult(deviceId: f.bDevice.id, uploadedCount: request.prekeys.count)
        }
    }
    @Test func multiDeviceFanoutEncryptsIndependentlyAndScopeIsIsolated() async throws {
        let f = try await fixture(), second = try await fixture()
        var seed = second.seed
        let claim = try #require(seed.value)
        seed.value = ClaimedPrekey(friendId: f.bUser, deviceId: second.bDevice.id, prekeyId: claim.prekeyId, publicKeyHex: claim.publicKeyHex)
        try await f.a.remember(user: f.bUser, devices: [second.bDevice])
        let id = try await f.a.prepareMessage(text: "both devices", friend: f.bUser, targets: [f.bDevice, second.bDevice],
            seeds: [f.bDevice.id: f.seed, second.bDevice.id: seed], local: f.alice)
        let items = Array(f.a.archive.outgoing.values)
        #expect(items.count == 2 && items[0].packet != items[1].packet && Set(items.map(\.messageId)) == [id])
        try await second.b.bind(scope: "server", user: f.bUser, device: second.bDevice.id)
        try await second.b.remember(user: f.aUser, devices: [f.aDevice])
        for (store, local) in [(f.b, f.bob), (second.b, second.bob)] {
            let item = try #require(items.first { $0.target == local.deviceId })
            try await store.ingest([envelope(item, from: f.aDevice.id)], advanceCursors: true)
            try await store.decryptPending(local: local)
            #expect(store.archive.messages[id]?.text == "both devices")
        }
        try await f.a.bind(scope: "other-server", user: f.aUser, device: f.aDevice.id)
        #expect(f.a.archive.messages.isEmpty && f.a.archive.sessions.isEmpty)
    }
    @Test func serializedSyncAndAckResponsesAndMalformedPages() async throws {
        let queue = WebSocketBusinessRequest(), device = UUID()
        let page = try JSONSerialization.data(withJSONObject: ["type": "chat.sync.envelope.result", "success": true,
            "device_id": device.uuidString, "count": 0, "has_more": false, "envelopes": []])
        let bytes = try await queue.performRaw(data: EnvelopeAPI.sync(device: device, cursors: [:], token: "token"),
            parse: { try EnvelopeAPI.response($0, expected: "chat.sync.envelope.result") }, send: { _ in
                queue.receive(Data(#"{"type":"newTextMessage.result","success":true}"#.utf8))
                #expect(queue.isBusy) // Unrelated success does not consume the sync slot.
                queue.receive(page)
            }, invalidate: { Issue.record("Unexpected disconnect") })
        let decoded = try JSONCodec.decoder().decode(EnvelopePage.self, from: bytes)
        try decoded.validate(device: device)
        #expect(decoded.envelopes.isEmpty && !decoded.hasMore)
        let id = UUID()
        let ack = try JSONSerialization.data(withJSONObject: ["type": "chat.envelopes.ack.result", "success": true,
            "device_id": device.uuidString, "count": 1, "acknowledged_ids": [id.uuidString]])
        let result = try await queue.performRaw(data: EnvelopeAPI.ack(device: device, ids: [id], token: "token"),
            parse: { try EnvelopeAPI.response($0, expected: "chat.envelopes.ack.result") }, send: { _ in queue.receive(ack) }, invalidate: {})
        try JSONCodec.decoder().decode(EnvelopeAck.self, from: result).validate(device: device, requested: [id])
        #expect(throws: SocketBusinessError.self) {
            try EnvelopeAPI.response(Data(#"{"type":"error","error":{"code":"access_token_expired"}}"#.utf8), expected: "chat.sync.envelope.result")
        }
        let bad = EnvelopePage(deviceId: device, count: 1, hasMore: true, envelopes: [])
        #expect(throws: (any Error).self) { try bad.validate(device: device) }
    }
    @Test func cursorWireUsesIntegersAndStoresAllPeers() async throws {
        let device = UUID(), p1 = UUID(), p2 = UUID()
        let data = try EnvelopeAPI.sync(device: device, cursors: [p1: 0, p2: Int64.max], token: "token")
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cursors = try #require(json["cursors"] as? [[String: Any]])
        #expect(cursors.count == 2 && json["authorization"] as? String == "Bearer token")
        #expect(cursors.allSatisfy { $0["after_seq"] is NSNumber })
    }
}
