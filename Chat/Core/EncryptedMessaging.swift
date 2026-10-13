import Foundation
import Combine

/// Implement this adapter once the backend defines its WebSocket frame contract.
protocol EncryptedMessageCodec {
    var isAvailable: Bool { get }
    func encode(_ envelope: InitialEnvelope) throws -> Data
    func decode(_ frame: Data) throws -> EncryptedSocketEvent?
}
enum EncryptedSocketEvent {
    case accepted(message: UUID, device: UUID)
    case delivered(message: UUID, device: UUID)
    case rejected(message: UUID, device: UUID, reason: String)
    case incoming(InitialEnvelope)
}
struct PendingEncryptedMessageCodec: EncryptedMessageCodec {
    var isAvailable: Bool { false }
    func encode(_ envelope: InitialEnvelope) throws -> Data {
        throw ClientError(message: "后端加密消息 WebSocket 协议尚未接入。")
    }
    func decode(_ frame: Data) throws -> EncryptedSocketEvent? { nil }
}
@MainActor
protocol EncryptedSocketTransport: AnyObject {
    var incomingFrames: PassthroughSubject<Data, Never> { get }
    func sendEncryptedFrame(_ data: Data) async throws
}

@MainActor
final class EncryptedMessaging: ObservableObject {
    enum DeliveryState: String {
        case prepared = "报文已准备", sending = "正在写入 WebSocket", submitted = "已写入 WebSocket，等待服务端回执"
        case accepted = "服务器已确认持久化", delivered = "接收设备已确认收到", uncertain = "发送结果不确定，需查询回执"
        case rejected = "服务端拒绝"
    }
    struct Outgoing: Identifiable {
        let envelope: InitialEnvelope
        var state: DeliveryState = .prepared
        var detail: String?
        var id: UUID { envelope.header.messageId }
    }
    @Published private(set) var outgoing: [UUID: Outgoing] = [:]
    @Published private(set) var receiveStatus = "等待加密消息协议接入"
    /// Consumer must persist, deduplicate, verify identity and decrypt before display/ack.
    let receivedEnvelopes = PassthroughSubject<InitialEnvelope, Never>()
    let codec: any EncryptedMessageCodec
    private let transport: any EncryptedSocketTransport
    private var subscription: AnyCancellable?
    private var generation = UUID()
    private var account: UUID?
    private var localDevice: UUID?
    init(transport: any EncryptedSocketTransport, codec: any EncryptedMessageCodec = PendingEncryptedMessageCodec()) {
        self.transport = transport; self.codec = codec
        subscription = transport.incomingFrames.sink { [weak self] frame in self?.receive(frame) }
    }
    func bind(account: UUID, device: UUID) {
        if self.account != account || localDevice != device { reset(); self.account = account; localDevice = device }
    }
    func stage(_ envelope: InitialEnvelope) throws {
        guard envelope.header.senderId == account, envelope.header.senderDeviceId == localDevice else {
            throw ClientError(message: "报文不属于当前登录设备。")
        }
        let id = envelope.header.messageId
        if let existing = outgoing[id] {
            guard existing.envelope == envelope else { throw ClientError(message: "相同消息 ID 不能绑定不同报文。") }
        } else { outgoing[id] = Outgoing(envelope: envelope) }
    }
    func send(_ id: UUID) async throws {
        guard codec.isAvailable else { throw ClientError(message: "入口已预留，等待后端 WebSocket 加密消息协议。") }
        guard let message = outgoing[id], message.state == .prepared else {
            throw ClientError(message: "消息不在待发送状态；结果不确定时不能自动重发。")
        }
        let data = try codec.encode(message.envelope)
        let current = generation
        outgoing[id]?.state = .sending
        do {
            try await transport.sendEncryptedFrame(data)
            guard generation == current else { return }
            // A receipt can arrive before the send continuation resumes.
            if outgoing[id]?.state == .sending { outgoing[id]?.state = .submitted }
        } catch {
            if generation == current, outgoing[id]?.state == .sending {
                outgoing[id]?.state = .uncertain; outgoing[id]?.detail = error.localizedDescription
            }
            throw error
        }
    }
    private func receive(_ frame: Data) {
        guard codec.isAvailable, let account, let localDevice else { return }
        do {
            guard let event = try codec.decode(frame) else { return }
            switch event {
            case .incoming(let envelope):
                guard envelope.header.recipientId == account, envelope.header.recipientDeviceId == localDevice else {
                    receiveStatus = "忽略不属于本机的推送"; return
                }
                receiveStatus = "收到密文，等待持久化、身份校验及认证解密"
                receivedEnvelopes.send(envelope) // Never display plaintext or auto-ack here.
            case .accepted(let id, let device): update(id, device: device, state: .accepted)
            case .delivered(let id, let device): update(id, device: device, state: .delivered)
            case .rejected(let id, let device, let reason): update(id, device: device, state: .rejected, detail: reason)
            }
        } catch { receiveStatus = "无法解析加密消息帧：\(error.localizedDescription)" }
    }
    private func update(_ id: UUID, device: UUID, state: DeliveryState, detail: String? = nil) {
        guard let message = outgoing[id], message.envelope.header.recipientDeviceId == device,
              message.state != .prepared, message.state != .delivered, message.state != .rejected else { return }
        if message.state == .accepted && state != .delivered { return }
        outgoing[id]?.state = state; outgoing[id]?.detail = detail
    }
    func reset() {
        generation = UUID(); outgoing = [:]; account = nil; localDevice = nil
        receiveStatus = "等待加密消息协议接入"
    }
}
