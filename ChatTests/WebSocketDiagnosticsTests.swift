import Foundation
import Testing
@testable import Chat

struct WebSocketDiagnosticsTests {
    @Test func testTypeUsesUpdatedBackendContract() throws {
        let id = UUID()
        let data = try WebSocketTestFrame.encode(message: "test", id: id, token: "test-token")
        let json = try JSONSerialization.jsonObject(with: data) as! [String: String]
        #expect(json == ["type": "chat.newTextMessage_Test", "id": id.uuidString.lowercased(), "message": "test", "authorization": "Bearer test-token"])
    }
    @Test func statusMakesUpgradeFailureActionable() {
        let error = URLError(.badServerResponse)
        #expect(WebSocketDiagnostics.failure(error, status: 404, wasConnected: false).contains("HTTP 404"))
        #expect(WebSocketDiagnostics.failure(error, status: 404, wasConnected: false).contains("type 尚未发送"))
        #expect(WebSocketDiagnostics.failure(error, status: 401, wasConnected: false).contains("鉴权"))
        #expect(WebSocketDiagnostics.failure(error, status: nil, wasConnected: false).contains("101 Upgrade"))
        #expect(!WebSocketDiagnostics.failure(URLError(.networkConnectionLost), status: 101, wasConnected: true).contains("握手失败"))
    }
}
