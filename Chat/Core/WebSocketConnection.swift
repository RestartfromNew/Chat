import Foundation

/// One instance per connection. URLSession owns RFC 6455 Upgrade, accept verification,
/// client frame masking and TLS. The HTTP worker must hand off and return 101 first.
@MainActor
final class WebSocketConnection: NSObject, URLSessionWebSocketDelegate {
    var onDeviceRevoked: (() -> Void)?
    private var reportedRevocation = false
    private var session: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var opening: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    private(set) var isOpen = false
    var httpStatus: Int? { (socket?.response as? HTTPURLResponse)?.statusCode }

    func open(_ request: URLRequest, timeout: Duration = .seconds(20)) async throws {
        guard session == nil else { throw ClientError(message: "连接实例不能重复使用。") }
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 1024 * 1024
        self.socket = socket
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                opening = continuation
                deadline = Task { [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    guard let self, self.opening != nil else { return }
                    self.finishOpening(.failure(URLError(.timedOut)))
                    self.socket?.cancel(with: .goingAway, reason: nil)
                    self.session?.invalidateAndCancel()
                }
                socket.resume() // Only start HTTP Upgrade. No application frames or ping yet.
            }
        } onCancel: { Task { @MainActor [weak self] in self?.close() } }
        try Task.checkCancellation()
    }
    private func finishOpening(_ result: Result<Void, Error>) {
        guard let continuation = opening else { return }
        opening = nil; deadline?.cancel(); deadline = nil
        continuation.resume(with: result)
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        guard isOpen, let socket else { throw URLError(.notConnectedToInternet) }
        do { return try await socket.receive() }
        catch { reportClose(code: socket.closeCode.rawValue, reason: socket.closeReason); throw error }
    }
    func send(_ data: Data) async throws {
        guard isOpen, let socket else { throw ClientError(message: "WebSocket 握手尚未完成。") }
        guard !data.isEmpty, data.count <= 1024 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw ClientError(message: "协议帧必须是 1 MB 内的 UTF-8 数据。")
        }
        try await socket.send(.string(text))
    }
    func ping() async throws {
        guard isOpen, let socket else { throw ClientError(message: "WebSocket 握手尚未完成。") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            socket.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    func reportClose(code: Int, reason: Data?) {
        guard code == 4001, reason.flatMap({ String(data: $0, encoding: .utf8) }) == "device_revoked",
              !reportedRevocation else { return }
        reportedRevocation = true; onDeviceRevoked?()
    }
    func close() {
        isOpen = false
        finishOpening(.failure(CancellationError()))
        deadline?.cancel(); deadline = nil
        socket?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            guard let self, self.socket === webSocketTask, self.opening != nil else { return }
            self.isOpen = true
            self.finishOpening(.success(()))
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.socket === task else { return }
            self.isOpen = false
            self.finishOpening(.failure(error ?? URLError(.networkConnectionLost)))
        }
    }
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        Task { @MainActor [weak self] in
            guard let self, self.socket === webSocketTask else { return }
            self.reportClose(code: closeCode.rawValue, reason: reason)
            self.isOpen = false
            self.finishOpening(.failure(URLError(.networkConnectionLost)))
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                                completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Never forward Bearer credentials to a redirect target.
    }
}
