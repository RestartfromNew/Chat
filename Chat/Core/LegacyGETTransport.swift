import Foundation
import Network

/// Compatibility adapter for the existing GET-with-JSON-body endpoints.
/// URLSession rejects GET bodies. Network.framework sends HTTP/1.1 over verified TLS.
/// Isolated so this file can be removed once both endpoints support POST.
struct LegacyGETTransport: HTTPTransport {
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let operation = LegacyGETOperation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { operation.start(request, continuation: $0) }
        } onCancel: { operation.cancel() }
    }
}

private final class LegacyGETOperation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "chat.legacy-http")
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<HTTPResult, Error>?
    private var bytes = Data()
    private var cancelled = false
    private var timer: DispatchWorkItem?

    func start(_ request: URLRequest, continuation: CheckedContinuation<HTTPResult, Error>) {
        queue.async {
            self.continuation = continuation
            if self.cancelled { self.finish(.failure(CancellationError())); return }
            guard let url = request.url, url.scheme == "https", let host = url.host,
                  let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? 443) ?? 0),
                  port.rawValue > 0, request.httpMethod == "GET" else {
                self.finish(.failure(URLError(.badURL))); return
            }
            let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tls)
            self.connection = connection
            let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(URLError(.timedOut))) }
            self.timer = timeout
            self.queue.asyncAfter(deadline: .now() + 20, execute: timeout)
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    do {
                        let wire = try Self.encode(request)
                        connection.send(content: wire, completion: .contentProcessed { [weak self] error in
                            if let error { self?.finish(.failure(error)) }
                            else { self?.receive() }
                        })
                    } catch { self.finish(.failure(error)) }
                case .failed(let error): self.finish(.failure(error))
                default: break
                }
            }
            connection.start(queue: self.queue)
        }
    }
    func cancel() {
        queue.async { self.cancelled = true; self.finish(.failure(CancellationError())) }
    }
    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, self.continuation != nil else { return }
            if let data { self.bytes.append(data) }
            guard self.bytes.count <= 2 * 1024 * 1024 else {
                self.finish(.failure(ClientError(message: "服务器响应超过 2 MB。"))); return
            }
            do {
                if let result = try HTTP1ResponseParser.parse(self.bytes, eof: complete) {
                    self.finish(.success(result)); return
                }
                if let error { self.finish(.failure(error)) }
                else if complete { self.finish(.failure(URLError(.badServerResponse))) }
                else { self.receive() }
            } catch { self.finish(.failure(error)) }
        }
    }
    private func finish(_ result: Result<HTTPResult, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        continuation.resume(with: result)
    }
    static func encode(_ request: URLRequest) throws -> Data {
        guard let url = request.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host else { throw URLError(.badURL) }
        let authority = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let hostHeader = authority + (parts.port.map { ":\($0)" } ?? "")
        let path = parts.percentEncodedPath.isEmpty ? "/" : parts.percentEncodedPath
        var headers = ["Host": hostHeader, "Connection": "close", "Accept": "application/json",
                       "Accept-Encoding": "identity", "Content-Type": "application/json",
                       "Content-Length": String(request.httpBody?.count ?? 0)]
        if let token = request.value(forHTTPHeaderField: "authorization") { headers["authorization"] = token }
        guard headers.values.allSatisfy({ !$0.contains("\r") && !$0.contains("\n") }) else { throw URLError(.badURL) }
        var output = Data(("GET \(path) HTTP/1.1\r\n" + headers.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n").utf8)
        output.append(request.httpBody ?? Data())
        return output
    }
}

/// Incremental parser: accepts Content-Length, chunked encoding, or close-delimited bodies.
enum HTTP1ResponseParser {
    static func parse(_ data: Data, eof: Bool = false) throws -> HTTPResult? {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else {
            if data.count > 65536 || eof { throw URLError(.badServerResponse) }
            return nil
        }
        guard end.lowerBound <= 65536,
              let header = String(data: data[..<end.lowerBound], encoding: .utf8) else { throw URLError(.badServerResponse) }
        let lines = header.components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ")
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."), let status = Int(statusParts[1]) else {
            throw URLError(.badServerResponse)
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw URLError(.badServerResponse) }
            let name = line[..<colon].lowercased()
            guard fields[name] == nil else { throw URLError(.badServerResponse) }
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).lowercased()
        }
        let body = Data(data[end.upperBound...])
        if (100..<200).contains(status) { throw URLError(.badServerResponse) }
        if status == 204 || status == 304 { return HTTPResult(status: status, data: Data()) }
        if let encoding = fields["content-encoding"], encoding != "identity" { throw URLError(.cannotDecodeContentData) }
        if let transfer = fields["transfer-encoding"] {
            guard transfer == "chunked", fields["content-length"] == nil else { throw URLError(.badServerResponse) }
            guard let decoded = try unchunk(body) else {
                if eof { throw URLError(.badServerResponse) }; return nil
            }
            return HTTPResult(status: status, data: decoded)
        }
        if let raw = fields["content-length"] {
            guard let length = Int(raw), length >= 0, length <= 2 * 1024 * 1024 else { throw URLError(.badServerResponse) }
            guard body.count >= length else { if eof { throw URLError(.badServerResponse) }; return nil }
            return HTTPResult(status: status, data: body.prefix(length))
        }
        return eof ? HTTPResult(status: status, data: body) : nil
    }
    private static func unchunk(_ data: Data) throws -> Data? {
        var cursor = 0
        var output = Data()
        let crlf = Data("\r\n".utf8)
        while cursor < data.count {
            guard let end = data.range(of: crlf, in: cursor..<data.count),
                  let line = String(data: data[cursor..<end.lowerBound], encoding: .utf8) else { return nil }
            guard let size = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first,
                  !size.isEmpty, let count = Int(size, radix: 16), count >= 0,
                  count <= 2 * 1024 * 1024 else { throw URLError(.badServerResponse) }
            cursor = end.upperBound
            if count == 0 {
                if data.count >= cursor + 2 && data[cursor..<cursor+2] == crlf { return output }
                return data.range(of: Data("\r\n\r\n".utf8), in: cursor..<data.count) != nil ? output : nil
            }
            guard data.count >= cursor + count + 2 else { return nil }
            output.append(data[cursor..<cursor+count]); cursor += count
            guard data[cursor..<cursor+2] == crlf else { throw URLError(.badServerResponse) }
            cursor += 2
        }
        return nil
    }
}
