import Foundation
import Security

enum KeychainStore {
    private static let service = "com.blueagle.uwvpn.session"

    static func load(gateway: UWGateway) -> Result<StoredSession?, NSError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: gateway.sessionAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return .success(nil)
        }
        guard status == errSecSuccess, let data = result as? Data else {
            return .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        do {
            let decoded = try JSONDecoder().decode(StoredSession.self, from: data)
            return .success(decoded)
        } catch {
            return .failure(error as NSError)
        }
    }

    @discardableResult
    static func save(session: StoredSession, gateway: UWGateway) -> Result<Void, NSError> {
        do {
            let data = try JSONEncoder().encode(session)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: gateway.sessionAccount
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrLabel as String: "UWVPN Session (\(gateway.gatewayHost))",
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            if updateStatus == errSecSuccess {
                return .success(())
            }
            if updateStatus == errSecItemNotFound {
                var addQuery = query
                addQuery[kSecValueData as String] = data
                addQuery[kSecAttrLabel as String] = "UWVPN Session (\(gateway.gatewayHost))"
                addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
                return addStatus == errSecSuccess
                    ? .success(())
                    : .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus)))
            }
            return .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(updateStatus)))
        } catch {
            return .failure(error as NSError)
        }
    }

    @discardableResult
    static func clear(gateway: UWGateway) -> Result<Void, NSError> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: gateway.sessionAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return .success(())
        }
        return .failure(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
    }
}
