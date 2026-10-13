import Foundation
import Combine

enum LabAttack: String, CaseIterable, Identifiable {
    case signature = "坏签名", ciphertext = "改密文", aad = "改 AAD", wrongKey = "错密钥"
    var id: String { rawValue }
}

struct LabChatMessage: Identifiable {
    let id: UUID
    let from: LabPeer
    let text: String
}

@MainActor
final class CryptoLabModel: ObservableObject {
    @Published var draft = "你好，这是加密测试。"
    @Published var sender: LabPeer = .alice
    @Published private(set) var generated = false
    @Published private(set) var verified = false
    @Published private(set) var ready = false
    @Published private(set) var messages: [LabChatMessage] = []
    @Published private(set) var pending: [LabEnvelope] = []
    @Published private(set) var publicDetails = "尚未生成公钥包"
    @Published private(set) var handshakeDetails = "尚未建立会话"
    @Published private(set) var envelopeDetails = "尚无密文信封"
    @Published private(set) var fingerprints = ""
    @Published private(set) var events: [String] = []
    @Published private(set) var error: String?
    private let engine = CryptoLabEngine()
    private var lastDelivered: (packet: LabEnvelope, recipient: LabPeer)?

    func generate() {
        perform {
            try engine.generate()
            generated = true; verified = false; ready = false
            pending = []; messages = []; lastDelivered = nil; events = []
            envelopeDetails = "尚无密文信封"; handshakeDetails = "尚未建立会话"
            publicDetails = LabPeer.allCases.map { peer in
                "\(peer.rawValue) 的公开资料\n" + LabEncoding.display(engine.bundles[peer])
            }.joined(separator: "\n\n")
            fingerprints = LabPeer.allCases.map { "\($0.rawValue)：\(engine.bundles[$0]?.fingerprint ?? "")" }.joined(separator: "\n")
            log("A/B 各自生成身份、签名、预密钥和一次性预密钥；屏幕只显示公钥。")
        }
    }
    func verify() {
        perform {
            try engine.verify(); verified = true
            log("公钥包验签通过；指纹与本机模拟对端匹配。真实联系人需独立核验。")
        }
    }
    func establish() {
        perform {
            try engine.establish(); ready = true
            handshakeDetails = LabEncoding.display(engine.handshakes)
            log("A→B、B→A 各完成四次 DH；双方独立算出的共享秘密一致。")
        }
    }
    func encrypt() {
        perform {
            guard pending.count < 20 else { throw ClientError(message: "请先解密待收信封（上限 20 条）。") }
            let packet = try engine.encrypt(draft, from: sender)
            pending.append(packet); envelopeDetails = LabEncoding.display(packet)
            log("\(sender.rawValue) 加密完成，信封已放入本地模拟中转区；没有网络请求。")
        }
    }
    func decrypt() {
        perform {
            guard let packet = pending.first else { throw LabFailure.notReady }
            let from: LabPeer = packet.header.senderDeviceID == engine.bundles[.alice]?.material.deviceID ? .alice : .bob
            let text = try engine.decrypt(packet, at: from.other)
            pending.removeFirst()
            messages.append(LabChatMessage(id: packet.id, from: from, text: text))
            if messages.count > 100 { messages.removeFirst() }
            lastDelivered = (packet, from.other)
            log("\(from.other.rawValue) 验证并解密成功，正文进入聊天框；已消耗 \(engine.consumedPrekeys)/2 把接收端 OPK。")
        }
    }
    func replay() {
        perform {
            guard let lastDelivered else { throw LabFailure.notReady }
            do {
                _ = try engine.decrypt(lastDelivered.packet, at: lastDelivered.recipient)
                throw ClientError(message: "重复投递测试失败：信封被再次接受。")
            } catch LabFailure.replay { log("重复投递已拒绝；聊天框不增加重复消息。") }
        }
    }
    func attack(_ attack: LabAttack) {
        perform {
            if attack == .signature {
                guard var bundle = engine.bundles[.bob] else { throw LabFailure.notReady }
                let pin = bundle.fingerprint
                bundle.signature[0] ^= 1
                do {
                    try bundle.verify(pinnedFingerprint: pin)
                    throw ClientError(message: "测试失败：错误签名被接受。")
                } catch LabFailure.invalidBundle { log("坏签名被拒绝：不会建立会话。") }
                return
            }
            var packet = try engine.encrypt("此测试正文不得显示", from: sender)
            if attack == .ciphertext { packet.sealedBox[12] ^= 1 }
            if attack == .aad { packet.header.messageID = UUID() }
            do {
                _ = try engine.decrypt(packet, at: sender.other, wrongKey: attack == .wrongKey)
                throw ClientError(message: "测试失败：异常信封被接受。")
            } catch LabFailure.invalidEnvelope { log("\(attack.rawValue)已被认证检查拒绝；未显示正文，未提交接收状态。") }
        }
    }
    private func perform(_ action: () throws -> Void) {
        error = nil
        do { try action() } catch { self.error = error.localizedDescription }
    }
    private func log(_ value: String) {
        events.insert(value, at: 0)
        if events.count > 30 { events.removeLast() }
    }
}
