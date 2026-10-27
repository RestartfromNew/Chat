import Foundation

enum NetworkRetry {
    static func isTransient(_ error: Error) -> Bool {
        if let value = error as? SocketBusinessError { return value.isTransient }
        if let value = error as? WebSocketHandshakeError {
            return value.status == nil || value.status == 408 || value.status == 429 || (value.status ?? 0) >= 500
        }
        if let value = error as? APIError { return value.status == 408 || value.status == 429 || value.status >= 500 }
        let value = error as NSError
        return value.domain == NSURLErrorDomain && [NSURLErrorTimedOut, NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorDNSLookupFailed,
            NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed].contains(value.code)
    }
    static func delay(attempt: Int) -> Int { min(30, 1 << min(max(0, attempt), 5)) }
}
