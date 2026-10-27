import Foundation

struct HTTPResult: Sendable { let status: Int; let data: Data }
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResult
}

final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = URLSessionTransport()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    override init() { super.init(); _ = session }
    func send(_ request: URLRequest) async throws -> HTTPResult {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return HTTPResult(status: response.statusCode, data: data)
    }
    // Never redirect credentials or authenticated requests to a different endpoint.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum AuthenticationPolicy: Sendable { case required, none }

enum AccessTokenHeader {
    static func apply(_ token: String?, to request: inout URLRequest) throws {
        guard let token, !token.isEmpty,
              token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw ClientError(message: "缺少有效的 Access Token，请重新登录。")
        }
        // Foundation canonicalizes this to Authorization. Raw HTTP compatibility
        // must serialize the field as lowercase for the current C++ backend.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    static func webSocketRequest(configuration: ServerConfiguration, token: String, deviceID: UUID) throws -> URLRequest {
        var request = URLRequest(url: try configuration.socketURL())
        request.httpMethod = "GET"
        request.setValue(deviceID.uuidString.lowercased(), forHTTPHeaderField: "deviceID")
        request.setValue("0", forHTTPHeaderField: "Content-Length") // Empty Upgrade request, matching the backend probe.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // URLSessionWebSocketTask supplies Upgrade/Connection/Sec-WebSocket-* headers.
        try apply(token, to: &request)
        request.timeoutInterval = 20
        return request
    }
}

struct APIClient: Sendable {
    let configuration: ServerConfiguration
    var transport: any HTTPTransport = URLSessionTransport.shared
    var legacyTransport: any HTTPTransport = HTTP1CompatibilityTransport()

    func request(path: String, method: String = "GET", body: [String: String]? = nil,
                 encodedBody: Data? = nil, token: String? = nil, authentication: AuthenticationPolicy = .required) async throws -> Data {
        let url = try configuration.validatedURL().appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try encodedBody ?? body.map { try JSONSerialization.data(withJSONObject: $0) }
        if request.httpBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authentication == .required { try AccessTokenHeader.apply(token, to: &request) }
        // Work around the backend's case-sensitive header lookup. No automatic
        // retry of a mutation: choose the compatible transport before sending.
        let sender = authentication == .required || (method == "GET" && request.httpBody != nil) ? legacyTransport : transport
        let result = try await sender.send(request)
        guard (200..<300).contains(result.status) else {
            struct ErrorBody: Decodable { struct Detail: Decodable { let code: String; let message: String }; let error: Detail }
            let error = try? JSONDecoder().decode(ErrorBody.self, from: result.data)
            throw APIError(status: result.status, code: error?.error.code ?? "http_error",
                           message: error?.error.message ?? "服务器返回错误，请检查地址和服务状态")
        }
        return result.data
    }

    func post<T: Decodable, B: Encodable>(_ type: T.Type, path: String, body: B, token: String) async throws -> T {
        let data = try await request(path: path, method: "POST", encodedBody: JSONEncoder().encode(body), token: token)
        return try JSONCodec.decoder().decode(type, from: data)
    }

    func decode<T: Decodable>(_ type: T.Type, path: String, method: String = "GET",
                             body: [String: String]? = nil, token: String? = nil,
                             authentication: AuthenticationPolicy = .required) async throws -> T {
        let data = try await request(path: path, method: method, body: body, token: token, authentication: authentication)
        do { return try JSONCodec.decoder().decode(type, from: data) }
        catch { throw ClientError(message: "服务器响应格式不符合接口约定（\(path)）。") }
    }
}
