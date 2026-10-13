import Foundation
import CryptoKit
import Testing
@testable import Chat

private func hex(_ value: String) -> Data {
    var result = Data(); var cursor = value.startIndex
    while cursor < value.endIndex {
        let next = value.index(cursor, offsetBy: 2)
        result.append(UInt8(value[cursor..<next], radix: 16)!)
        cursor = next
    }
    return result
}

@MainActor
struct CryptoLabTests {
    private func prepared() throws -> CryptoLabEngine {
        let engine = CryptoLabEngine()
        try engine.generate(); try engine.verify(); try engine.establish()
        return engine
    }
    @Test func documentKnownVector() throws {
        typealias Key = Curve25519.KeyAgreement.PrivateKey
        let ai = try Key(rawRepresentation: hex("60860237e15f8f85adc80ec7723a6f0bf2601ac49234a1150c1154236fdab57e"))
        let ae = try Key(rawRepresentation: hex("d09ea7e07d773d633232c017815e5d1fdfd5290a4fb81fb16db95a89505c6862"))
        let bi = try Key(rawRepresentation: hex("a8f7c99c020a1a16e7237755fa6f73d711c4c22a864359cc4eb369e86c56b67d"))
        let bs = try Key(rawRepresentation: hex("901893ba90df1299fbc4a80368837f57b11b7b70a281aa80a215ef83319aca4b"))
        let bo = try Key(rawRepresentation: hex("50f8142c6b9539453a518f70cad9630eb05bd842f27001143439f22156071b5c"))
        let material = LabBundle.PublicMaterial(suite: LabBundle.suite, deviceID: UUID(), identityKey: bi.publicKey.rawRepresentation,
            signingKey: Data(), signedPrekeyID: 42, signedPrekey: bs.publicKey.rawRepresentation,
            oneTimePrekeyID: 1007, oneTimePrekey: bo.publicKey.rawRepresentation)
        let a = try LabFourDH.initiate(identity: ai, ephemeral: ae, peer: material)
        let b = try LabFourDH.respond(identity: bi, prekey: bs, oneTime: bo,
            senderIdentity: ai.publicKey.rawRepresentation, senderEphemeral: ae.publicKey.rawRepresentation)
        #expect(a == b)
        #expect(a.withUnsafeBytes { LabEncoding.hex(Data($0)) } == "861134e2187bc12887e6d47325a8666f86282ce8984428afc2669e7458c82a56")
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: a,
            salt: hex("5c52a554ee34cf92798f2e3b8ddeb27e064e6fd1e747a4b49a41234e93239842"),
            info: Data("Example-Only/A1-to-B1/M100".utf8), outputByteCount: 32)
        #expect(key.withUnsafeBytes { LabEncoding.hex(Data($0)) } == "c03970d03c61f750be11efdb22bd4537ac6c99dd1d395821dbe357a5d0e5e371")
        let box = try ChaChaPoly.seal(Data("你好".utf8), using: key,
            nonce: ChaChaPoly.Nonce(data: hex("34df7fa4974ed897480904f7")),
            authenticating: Data("v=1|from=A1|to=B1|conversation=C_AB|message=M100".utf8))
        #expect(LabEncoding.hex(box.ciphertext) == "d1431664f8bd")
        #expect(LabEncoding.hex(box.tag) == "58877d534cb45c6e1e78186184b8e8f1")
    }
    @Test func orderedStepsAndBidirectionalUnicode() throws {
        let engine = CryptoLabEngine()
        #expect(throws: LabFailure.notReady) { try engine.establish() }
        try engine.generate()
        #expect(throws: LabFailure.notReady) { try engine.encrypt("hello", from: .alice) }
        try engine.verify(); try engine.establish()
        for sender in LabPeer.allCases {
            let packet = try engine.encrypt("你好 🔐 \(sender.rawValue)", from: sender)
            #expect(try engine.decrypt(packet, at: sender.other) == "你好 🔐 \(sender.rawValue)")
        }
        #expect(engine.consumedPrekeys == 2)
    }
    @Test func publicBundleTamperingAndIdentityChangeFail() throws {
        let engine = try prepared()
        let original = try #require(engine.bundles[.bob])
        for field in 0..<4 {
            var changed = original
            switch field {
            case 0: changed.signature[0] ^= 1
            case 1: changed.material.signedPrekey[0] ^= 1
            case 2: changed.material.identityKey[0] ^= 1
            default: changed.material.suite = "other"
            }
            #expect(throws: (any Error).self) { try changed.verify(pinnedFingerprint: original.fingerprint) }
        }
        let other = try prepared()
        #expect(throws: LabFailure.invalidBundle) { try other.bundles[.bob]!.verify(pinnedFingerprint: original.fingerprint) }
    }
    @Test func failedAuthenticationDoesNotConsumeState() throws {
        let engine = try prepared()
        let packet = try engine.encrypt("真实正文", from: .alice)
        var tampered = packet; tampered.sealedBox[12] ^= 1
        #expect(throws: LabFailure.invalidEnvelope) { try engine.decrypt(tampered, at: .bob) }
        tampered = packet; tampered.header.messageID = UUID()
        #expect(throws: LabFailure.invalidEnvelope) { try engine.decrypt(tampered, at: .bob) }
        #expect(throws: LabFailure.invalidEnvelope) { try engine.decrypt(packet, at: .bob, wrongKey: true) }
        #expect(engine.consumedPrekeys == 0)
        #expect(try engine.decrypt(packet, at: .bob) == "真实正文")
        #expect(engine.consumedPrekeys == 1)
        #expect(throws: LabFailure.replay) { try engine.decrypt(packet, at: .bob) }
    }
    @Test func routeAndOldSessionAreRejected() throws {
        let engine = try prepared()
        let packet = try engine.encrypt("hello", from: .alice)
        #expect(throws: LabFailure.invalidEnvelope) { try engine.decrypt(packet, at: .alice) }
        var changed = packet; changed.header.conversationID = UUID()
        #expect(throws: LabFailure.invalidEnvelope) { try engine.decrypt(changed, at: .bob) }
        try engine.generate(); try engine.verify(); try engine.establish()
        #expect(throws: LabFailure.invalidEnvelope) { try engine.decrypt(packet, at: .bob) }
    }
    @Test func packetsAreUniqueSerializableAndCanArriveOutOfOrder() throws {
        let engine = try prepared()
        let first = try engine.encrypt("相同内容", from: .alice)
        let second = try engine.encrypt("相同内容", from: .alice)
        #expect(first.id != second.id)
        #expect(first.header.salt != second.header.salt)
        #expect(first.sealedBox != second.sealedBox)
        let wire = try LabEncoding.encode(first)
        let decoded = try JSONDecoder().decode(LabEnvelope.self, from: wire)
        #expect(try engine.decrypt(second, at: .bob) == "相同内容")
        #expect(try engine.decrypt(decoded, at: .bob) == "相同内容")
    }
    @Test func uiOnlyDisplaysAuthenticatedMessages() throws {
        let model = CryptoLabModel()
        model.generate(); model.verify(); model.establish()
        #expect(model.ready)
        for attack in LabAttack.allCases { model.attack(attack); #expect(model.error == nil) }
        #expect(model.messages.isEmpty)
        model.encrypt(); #expect(model.messages.isEmpty); #expect(model.pending.count == 1)
        model.decrypt(); #expect(model.messages.count == 1); #expect(model.pending.isEmpty)
        model.replay(); #expect(model.messages.count == 1); #expect(model.error == nil)
        model.generate(); #expect(model.messages.isEmpty); #expect(!model.ready)
    }
    @Test func emptyAndOversizedTextAreRejected() throws {
        let engine = try prepared()
        #expect(throws: LabFailure.input) { try engine.encrypt(" \n", from: .alice) }
        #expect(throws: LabFailure.input) { try engine.encrypt(String(repeating: "你", count: 1400), from: .alice) }
    }
}
