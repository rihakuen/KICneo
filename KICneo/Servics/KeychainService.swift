import Foundation
import Security

/// 学校の ID とパスワードは Keychain にだけ保存する（UserDefaults やコードには置かない）。
nonisolated enum KeychainService {
  struct Credentials {
    let id: String
    let password: String
  }

  private static let service = "KICneo.school"
  private static let savedFlagKey = "school_has_saved_account"

  /// Keychain の読み込みは遅いので、起動時はこのフラグでログイン画面を先に出すかを決める（メインスレッドを止めないため）。
  static var hasSavedAccount: Bool {
    UserDefaults.standard.bool(forKey: savedFlagKey)
  }

  static func load() -> Credentials? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecReturnAttributes as String: true,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let dict = item as? [String: Any],
          let id = dict[kSecAttrAccount as String] as? String,
          let data = dict[kSecValueData as String] as? Data,
          let password = String(data: data, encoding: .utf8) else { return nil }
    return Credentials(id: id, password: password)
  }

  static func save(id: String, password: String) {
    clear()
    let attrs: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: id,
      kSecValueData as String: Data(password.utf8),
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    SecItemAdd(attrs as CFDictionary, nil)
    UserDefaults.standard.set(true, forKey: savedFlagKey)
  }

  static func clear() {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service
    ]
    SecItemDelete(query as CFDictionary)
    UserDefaults.standard.set(false, forKey: savedFlagKey)
  }
}
