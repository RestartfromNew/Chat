import Foundation

enum WebSocketTestFrame {
    static let type = "chat.newTextMessage_Test"
    static func encode(message: String, id: UUID, token: String) throws -> Data {
        guard !message.isEmpty, message.utf8.count <= 4096 else { throw ClientError(message: "测试内容需为 1–4096 字节。") }
        var request = URLRequest(url: URL(string: "https://localhost")!)
        try AccessTokenHeader.apply(token, to: &request)
        return try JSONSerialization.data(withJSONObject: ["type": type, "authorization": "Bearer " + token,
            "id": id.uuidString.lowercased(), "message": message])
    }
}

enum WebSocketDiagnostics {
    static func failure(_ error: Error, status: Int?, wasConnected: Bool) -> String {
        if let status, status != 101 {
            let detail: String
            switch status {
            case 401, 403: detail = "服务器拒绝握手鉴权，请检查 Access Token 和 WebSocket 鉴权配置。"
            case 404: detail = "WebSocket 路径或反向代理 Upgrade 转发未匹配，请检查配置路径对应的服务和部署版本。"
            case 301, 302, 307, 308: detail = "握手发生重定向，请使用最终的 wss 地址。"
            case 400, 426: detail = "服务器未接受 Upgrade，请检查代理的 HTTP/1.1、Upgrade 和 Connection 转发。"
            case 500...599: detail = "服务端或反向代理暂时不可用。"
            default: detail = "握手应返回 101 Switching Protocols。"
            }
            return "WebSocket 握手失败：HTTP \(status)。\(detail)消息 type 尚未发送，与此阶段无关。"
        }
        let value = error as NSError
        if value.domain == NSURLErrorDomain && value.code == NSURLErrorBadServerResponse {
            return "WebSocket 握手或协议响应无效（NSURLErrorDomain \(value.code)）。请检查服务器是否返回有效 101 Upgrade；消息 type 只在连接成功后发送。"
        }
        return "\(wasConnected ? "连接结束" : "连接未完成")：\(error.localizedDescription)（\(value.domain) \(value.code)）"
    }
}
