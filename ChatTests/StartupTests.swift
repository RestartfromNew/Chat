import Foundation
import Testing
@testable import Chat

struct StartupTests {
    @Test func retryPolicySeparatesTransientNetworkFromActionableFailures() {
        #expect(NetworkRetry.isTransient(URLError(.notConnectedToInternet)))
        #expect(NetworkRetry.isTransient(URLError(.networkConnectionLost)))
        #expect(NetworkRetry.isTransient(APIError(status: 503, code: "database_unavailable", message: "busy")))
        #expect(!NetworkRetry.isTransient(URLError(.serverCertificateUntrusted)))
        #expect(!NetworkRetry.isTransient(CancellationError()))
        #expect(!NetworkRetry.isTransient(WebSocketHandshakeError(status: 403, detail: "device unavailable")))
        #expect(!NetworkRetry.isTransient(APIError(status: 401, code: "expired", message: "expired")))
        #expect((0...7).map { NetworkRetry.delay(attempt: $0) } == [1, 2, 4, 8, 16, 30, 30, 30])
    }
    @Test func primaryInterfaceTranslationsArePackaged() throws {
        let en = try #require(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let zh = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let english = try #require(Bundle(path: en)), chinese = try #require(Bundle(path: zh))
        #expect(english.localizedString(forKey: "好友", value: nil, table: nil) == "Friends")
        #expect(english.localizedString(forKey: "正在自动连接，请稍候…", value: nil, table: nil) == "Connecting automatically…")
        #expect(chinese.localizedString(forKey: "好友", value: nil, table: nil) == "好友")
    }
}
