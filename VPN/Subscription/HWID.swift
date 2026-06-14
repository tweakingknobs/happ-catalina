import Foundation
import Security

/// Stable per-install device id sent as the `x-hwid` header. The subscription
/// service gates real nodes behind this (Remnawave HWID device limit), and each
/// *new* value consumes a device slot — so we persist exactly one and reuse it.
///
/// The default is seeded with a value already registered on the bundled demo key,
/// so the demo works out of the box without the user freeing a device slot.
enum HWID {
    /// Already-registered on the demo subscription — makes the demo work immediately.
    static let seeded = "8f3b2c1a-aaaa-bbbb-cccc-1234567890ab"

    private static let service = "ru.local.vpn.hwid"
    private static let account = "device-hwid"
    private static let udKey   = "ru.local.vpn.hwid"

    /// Returns the stable HWID, creating/seeding it on first use.
    static func current() -> String {
        if let v = keychainRead(), !v.isEmpty { return v }
        if let v = UserDefaults.standard.string(forKey: udKey), !v.isEmpty {
            keychainWrite(v); return v
        }
        keychainWrite(seeded)
        UserDefaults.standard.set(seeded, forKey: udKey)
        return seeded
    }

    /// Generates a brand-new random HWID (consumes a new device slot on the server).
    @discardableResult
    static func reset() -> String {
        let v = UUID().uuidString
        keychainWrite(v)
        UserDefaults.standard.set(v, forKey: udKey)
        return v
    }

    // MARK: - Keychain

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func keychainRead() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainWrite(_ value: String) {
        let data = value.data(using: .utf8) ?? Data()
        SecItemDelete(baseQuery() as CFDictionary)
        var q = baseQuery()
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }
}
