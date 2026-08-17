//
//  KeychainHelper.swift
//  Meetinsight
//

import Foundation
import Security

/// 轻量 Keychain 封装（账号口令/API Key 等敏感信息只存系统钥匙串，绝不明文落盘）。
/// 不隔离到 @MainActor：Security.framework 的 C API 线程安全，避免跨隔离调用摩擦。
final class KeychainHelper {
    static let shared = KeychainHelper()
    private let service = "com.weilu.meetingminutes"

    func save(_ value: String, account: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // 已存在则先删除再写入（覆盖更新）
        SecItemDelete(query as CFDictionary)
        let add = query.merging([
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]) { _, new in new }
        SecItemAdd(add as CFDictionary, nil)
    }

    func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
