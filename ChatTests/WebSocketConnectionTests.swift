import Foundation
import Network
import CryptoKit
import Testing
@testable import Chat

private final class UpgradeFixture: @unchecked Sendable {
    enum Mode { case upgrade, storedMessage, notFound, unauthorized, silent, revoked }
    let mode: Mode
    private let queue = DispatchQueue(label: "chat.test.upgrade")
    private var listener: NWListener?
    private var clients: [NWConnection] = []
    private var requests: [String] = []
    private var waiting = true // Accessed only on queue.
    init(_ mode: Mode) { self.mode = mode }
    var receivedHeaders: [String] { queue.sync { requests } }
    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any); self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                guard waiting else { return }
                switch state {
                case .ready: waiting = false; continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error): waiting = false; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [self] client in
                clients.append(client); client.start(queue: queue); readHeader(client, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }
    private func readHeader(_ client: NWConnection, accumulated: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [self] data, _, complete, error in
            var buffer = accumulated; if let data { buffer.append(data) }
            guard buffer.count <= 16384 else { client.cancel(); return }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if !complete && error == nil { readHeader(client, accumulated: buffer) }; return
            }
            let text = String(decoding: buffer[..<end.upperBound], as: UTF8.self); requests.append(text)
            if mode == .silent { return }
            if mode == .notFound || mode == .unauthorized {
                let status = mode == .unauthorized ? "401 Unauthorized" : "404 Not Found"
                client.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in client.cancel() }); return
            }
            let key = text.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("sec-websocket-key:") }!
                .split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            // The server sends a first frame with the handshake; deliberately no Pong.
            if mode == .storedMessage {
                client.send(content: Data(response.utf8), completion: .contentProcessed { _ in })
                readMessage(client, accumulated: Data())
            } else if mode == .revoked {
                let payload = Data([0x0f, 0xa1]) + Data("device_revoked".utf8)
                client.send(content: Data(response.utf8) + Data([0x88, UInt8(payload.count)]) + payload,
                    completion: .contentProcessed { _ in })
            } else {
                client.send(content: Data(response.utf8) + Data([0x81, 2, 0x6f, 0x6b]), completion: .contentProcessed { _ in })
            }
        }
    }
    private func readMessage(_ client: NWConnection, accumulated: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            var buffer = accumulated; if let data { buffer.append(data) }
            func again() { if !complete && error == nil { readMessage(client, accumulated: buffer) } }
            guard buffer.count >= 2 else { again(); return }
            guard buffer[0] == 0x81, buffer[1] & 0x80 != 0 else { client.cancel(); return }
            var offset = 2, count = Int(buffer[1] & 0x7f)
            if count == 126 {
                guard buffer.count >= 4 else { again(); return }
                count = Int(buffer[2]) * 256 + Int(buffer[3]); offset = 4
            }
            guard count < 65536, count != 127 else { client.cancel(); return }
            guard buffer.count >= offset + 4 + count else { again(); return }
            let mask = Array(buffer[offset..<(offset + 4)]); offset += 4
            let bytes = Data(buffer[offset..<(offset + count)].enumerated().map { $0.element ^ mask[$0.offset % 4] })
            guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: String],
                  object["type"] == "chat.newTextMessage", object["authorization"] == "Bearer frame-token",
                  let id = object["message_id"], let packet = object["packet_base64"], Data(base64Encoded: packet) != nil else {
                client.cancel(); return
            }
            let payload = try! JSONSerialization.data(withJSONObject: ["type": "newTextMessage.result", "success": true,
                "message_id": id, "envelope_id": UUID().uuidString, "seq": 7, "duplicate": false])
            let header = Data([0x81, 126, UInt8(payload.count >> 8), UInt8(payload.count & 255)])
            client.send(content: header + payload, completion: .contentProcessed { _ in })
        }
    }
    func stop() { queue.sync { listener?.cancel(); clients.forEach { $0.cancel() } } }
}

@MainActor struct WebSocketConnectionTests {
    private func request(_ port: UInt16) -> URLRequest {
        var value = try! AccessTokenHeader.webSocketRequest(configuration: ServerConfiguration(), token: "fixture-only", deviceID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!)
        value.url = URL(string: "ws://127.0.0.1:\(port)/")!
        value.setValue("Bearer fixture-only", forHTTPHeaderField: "Authorization"); return value
    }
    @Test func nativeUpgradeOpensWithoutPongAndPreservesFirstFrame() async throws {
        let fixture = UpgradeFixture(.upgrade), connection = WebSocketConnection()
        defer { connection.close(); fixture.stop() }
        let port = try await fixture.start()
        try await connection.open(request(port))
        #expect(connection.isOpen)
        #expect(connection.httpStatus == 101)
        let message = try await connection.receive()
        guard case .string(let text) = message else { Issue.record("Expected text"); return }
        #expect(text == "ok")
        let headers = try #require(fixture.receivedHeaders.first)
        #expect(headers.hasPrefix("GET / HTTP/1.1"))
        #expect(headers.lowercased().contains("upgrade: websocket"))
        #expect(headers.lowercased().contains("content-length: 0"))
        #expect(headers.lowercased().contains("connection: upgrade"))
        #expect(headers.lowercased().contains("authorization: bearer fixture-only"))
        #expect(headers.lowercased().contains("sec-websocket-version: 13"))
        #expect(headers.lowercased().contains("deviceid: 11111111-2222-4333-8444-555555555555\r\n"))
    }
    @Test func maskedBusinessFrameRoundTripsThroughNativeSocket() async throws {
        let fixture = UpgradeFixture(.storedMessage), connection = WebSocketConnection(), business = WebSocketBusinessRequest()
        defer { connection.close(); fixture.stop() }
        try await connection.open(request(try await fixture.start()))
        let id = UUID()
        let frame = try JSONSerialization.data(withJSONObject: ["type": "chat.newTextMessage", "authorization": "Bearer frame-token",
            "sender_device_id": UUID().uuidString, "recipient_device_id": UUID().uuidString,
            "message_id": id.uuidString, "protocol_version": StoredMessageProtocol.version,
            "packet_base64": Data(repeating: 0xAA, count: 40000).base64EncodedString()])
        let reader = Task {
            if case .string(let value) = try await connection.receive() { business.receive(Data(value.utf8)) }
        }
        defer { reader.cancel() }
        let receipt = try await business.perform(data: frame, id: id, duration: .seconds(3),
            send: { try await connection.send($0) }, invalidate: { connection.close() })
        #expect(receipt.messageId == id && receipt.seq == 7 && !receipt.duplicate)
    }
    @Test func actualRevocationCloseIsDeliveredExactlyOnce() async throws {
        let fixture = UpgradeFixture(.revoked), connection = WebSocketConnection()
        defer { connection.close(); fixture.stop() }
        var revoked = 0
        connection.onDeviceRevoked = { revoked += 1 }
        try await connection.open(request(try await fixture.start()))
        do { _ = try await connection.receive() } catch {}
        // Delegate and receive error can both report the same close.
        for _ in 0..<20 where revoked == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(revoked == 1)
    }
    @Test func handshakeRequiresTokenAnd401IsAvailableForRefresh() async throws {
        let fixture = UpgradeFixture(.unauthorized), connection = WebSocketConnection()
        defer { connection.close(); fixture.stop() }
        let port = try await fixture.start()
        do { try await connection.open(request(port)); Issue.record("401 accepted") } catch {}
        #expect(!connection.isOpen && connection.httpStatus == 401)
        #expect(fixture.receivedHeaders.first?.lowercased().contains("authorization: bearer fixture-only") == true)
    }
    @Test func rejectionIsNotReportedAsConnected() async throws {
        let fixture = UpgradeFixture(.notFound), connection = WebSocketConnection()
        defer { connection.close(); fixture.stop() }
        let port = try await fixture.start()
        do { try await connection.open(request(port)); Issue.record("404 accepted") } catch {}
        #expect(!connection.isOpen && connection.httpStatus == 404)
    }
    @Test func handshakeDeadlineTerminatesSilentServer() async throws {
        let fixture = UpgradeFixture(.silent), connection = WebSocketConnection()
        defer { connection.close(); fixture.stop() }
        let port = try await fixture.start()
        do { try await connection.open(request(port), timeout: .milliseconds(100)); Issue.record("Missing timeout") }
        catch { #expect((error as NSError).code == NSURLErrorTimedOut) }
        #expect(!connection.isOpen)
    }
    @Test func cancelledOpenDoesNotHang() async throws {
        let fixture = UpgradeFixture(.silent), connection = WebSocketConnection()
        defer { connection.close(); fixture.stop() }
        let port = try await fixture.start()
        let task = Task { try await connection.open(request(port)) }
        task.cancel()
        do { try await task.value; Issue.record("Cancellation ignored") } catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(!connection.isOpen)
    }
}
