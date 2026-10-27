import Foundation

/// One serial worker owns the CredentialStore and archive cache. No Keychain or
/// JSON work runs on the UI executor; failed writes never update the cache.
final class ChatArchiveIO: @unchecked Sendable {
    private let queue = DispatchQueue(label: "chat.archive.io", qos: .utility)
    private let storage: any CredentialStore
    private var cache: [String: ChatArchive]?
    init(storage: any CredentialStore) { self.storage = storage }
    private func profiles() throws -> [String: ChatArchive] {
        if let cache { return cache }
        let values = try storage.read().map { try JSONDecoder().decode([String: ChatArchive].self, from: $0) } ?? [:]
        cache = values; return values
    }
    func read(_ scope: String) async throws -> ChatArchive {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try self.profiles()[scope] ?? ChatArchive() }) }
        }
    }
    func write(_ value: ChatArchive, scope: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                continuation.resume(with: Result {
                    var profiles = try self.profiles(); profiles[scope] = value
                    try self.storage.write(JSONEncoder().encode(profiles)); self.cache = profiles
                })
            }
        }
    }
}
