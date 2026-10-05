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

struct APIClient: Sendable {
    let configuration: ServerConfiguration
    var transport: any HTTPTransport = URLSessionTransport.shared
    var legacyTransport: any HTTPTransport = LegacyGETTransport()

    func request(path: String, method: String = "GET", body: [String: String]? = nil,
                 token: String? = nil) async throws -> Data {
        let url = try configuration.validatedURL().appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        let sender = method == "GET" && body != nil ? legacyTransport : transport
        let result = try await sender.send(request)
        guard (200..<300).contains(result.status) else {
            struct ErrorBody: Decodable { struct Detail: Decodable { let code: String; let message: String }; let error: Detail }
            let error = try? JSONDecoder().decode(ErrorBody.self, from: result.data)
            throw APIError(status: result.status, code: error?.error.code ?? "http_error",
                           message: error?.error.message ?? "服务器返回错误，请检查地址和服务状态")
        }
        return result.data
    }

    func decode<T: Decodable>(_ type: T.Type, path: String, method: String = "GET",
                             body: [String: String]? = nil, token: String? = nil) async throws -> T {
        let data = try await request(path: path, method: method, body: body, token: token)
        do { return try JSONCodec.decoder().decode(type, from: data) }
        catch { throw ClientError(message: "服务器响应格式不符合接口约定（\(path)）。") }
    }
}
