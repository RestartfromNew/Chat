import Foundation
import Security

protocol CredentialStore {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

struct KeychainStore: CredentialStore {
    private let service: String
    private let account: String
    init(service: String = "personal-learning.Chat.session.v1", account: String = "active-session") { self.service = service; self.account = account }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure(status) }
        return result as? Data
    }
    func write(_ data: Data) throws {
        let changes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            changes.forEach { item[$0.key] = $0.value }
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw failure(added) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure(status) }
    }
    private func failure(_ status: OSStatus) -> ClientError {
        ClientError(message: "无法访问安全存储（\(status)）。请解锁设备后重试。")
    }
}

struct SavedSession: Codable {
    let server: ServerConfiguration
    let login: LoginResponse
}
