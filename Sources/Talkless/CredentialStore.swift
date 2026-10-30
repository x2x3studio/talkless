import Foundation
import Security
import LocalAuthentication

/// Injectable so settings migrations can be tested without accessing a user's Keychain.
@MainActor
protocol CredentialStoring {
    func credential(for provider: PolishProvider) throws -> String?
    func setCredential(_ value: String, for provider: PolishProvider) throws
}

@MainActor
struct CredentialStore: CredentialStoring {
    /// Keep this stable across releases, paths, and build configurations. Keychain access
    /// also depends on a stable signing identity; a service name cannot replace that.
    private let service = "com.x2x3studio.talkless.polish"

    func credential(for provider: PolishProvider) throws -> String? {
        var query = query(for: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CredentialStoreError(status: errSecDecode)
        }
        return value
    }

    func setCredential(_ value: String, for provider: PolishProvider) throws {
        let query = query(for: provider)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialStoreError(status: status)
            }
            return
        }
        let attributes = [kSecValueData as String: Data(value.utf8)] as [String: Any]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrLabel as String] = "Talkless \(provider.title) API key"
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw CredentialStoreError(status: addStatus) }
        } else if status != errSecSuccess {
            throw CredentialStoreError(status: status)
        }
    }

    private func query(for provider: PolishProvider) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            // Do not raise authorization prompts at launch or while switching providers.
            // An inaccessible item stays untouched and settings reports the failure.
            kSecUseAuthenticationContext as String: context,
        ]
    }
}

struct CredentialStoreError: LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        L10n.format("Keychain access failed (%d). Check that Keychain is unlocked and this Talkless build uses the same signing identity.", status)
    }
}
