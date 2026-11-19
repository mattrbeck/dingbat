import Foundation
import Security

/// The Drive tokens, in the Keychain: a file in the app's container is read
/// by anything that reads the container (a backup, a path that escapes its
/// folder), and the refresh token is the account's Drive files for as long
/// as it lives. This device only, readable once the phone has been unlocked
/// since boot (a sync can run before the app is next opened by hand).
enum TokenVault {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.mattrb.dingbat") + ".drive"
    /// What the Keychain last took, so a save of the sync state that changes
    /// neither token does not write it again.
    private static var stored: [String: String?] = [:]

    private static func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    static func read(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else {
            stored[key] = .some(nil)
            return nil
        }
        let v = String(data: d, encoding: .utf8)
        stored[key] = .some(v)
        return v
    }

    /// Nil removes it. False when the Keychain refused: the token then
    /// lasts only as long as this run, and is never put in a file instead.
    @discardableResult
    static func write(_ key: String, _ value: String?) -> Bool {
        if let known = stored[key], known == value { return true }
        SecItemDelete(query(key) as CFDictionary)
        guard let value else {
            stored[key] = .some(nil)
            return true
        }
        var q = query(key)
        q[kSecValueData] = Data(value.utf8)
        q[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let ok = SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        if ok { stored[key] = .some(value) } else { stored[key] = nil }
        return ok
    }

    /// A Keychain outlives the app it belongs to: a fresh install starts
    /// without the last one's tokens.
    static func clear() {
        write("token", nil)
        write("refresh", nil)
    }
}
