import Foundation
import Testing
@testable import Chat

@MainActor struct WebSocketAuthUpdateTests {
    @Test func newPublicErrorsAreHandledByAllBusinessRoutes() throws {
        for code in ["database_unavailable", "retry_later", "internal_server_error", "accessToken_do_not_match_session", "device_do_not_match_session", "invalid_request"] {
            let bytes = try JSONSerialization.data(withJSONObject: ["type":"error", "error":["code":code]])
            for route in ["newTextMessage.result", "chat.sync.envelope.result", "chat.envelopes.ack.result"] {
                do { _ = try EnvelopeAPI.response(bytes, expected: route); Issue.record("Error was ignored") }
                catch let error as SocketBusinessError { #expect(error.code == code) }
            }
            #expect(throws: SocketBusinessError.self) { try StoredMessageProtocol.response(bytes, id: UUID(), test: true) }
        }
    }
    @Test func retryPolicyDoesNotConfuseSessionIdentityWithExpiredTokens() {
        for code in ["database_unavailable", "retry_later", "server_busy"] {
            #expect(NetworkRetry.isTransient(SocketBusinessError(code: code)))
        }
        for code in ["accessToken_do_not_match_session", "device_do_not_match_session", "session_device_mismatch"] {
            let error = SocketBusinessError(code: code)
            #expect(error.isSessionFailure && !error.isAuthentication && !NetworkRetry.isTransient(error))
        }
        #expect(!NetworkRetry.isTransient(SocketBusinessError(code: "internal_server_error")))
        #expect(SocketBusinessError(code: "invalid_access_token").isAuthentication)
        #expect(SocketBusinessError(code: "access_token_expired").isAuthentication)
    }
    @Test func taskIdentityFailureCompletesRequestAndInvalidatesConnection() async throws {
        let business = WebSocketBusinessRequest()
        var invalidated = false
        do {
            _ = try await business.performRaw(data: Data(), parse: { try EnvelopeAPI.response($0, expected: "chat.envelopes.ack.result") }, send: { _ in
                business.receive(Data(#"{"type":"error","error":{"code":"device_do_not_match_session"}}"#.utf8))
            }, invalidate: { invalidated = true })
            Issue.record("Expected identity failure")
        } catch let error as SocketBusinessError { #expect(error.isSessionFailure) }
        #expect(invalidated && !business.isBusy)
    }
}
