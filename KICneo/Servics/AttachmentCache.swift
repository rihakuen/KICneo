import Foundation

/// 学校から取得した添付ファイル（公欠申請の画像など）の端末キャッシュ。
/// 添付は後から変わらないので、一度取得したらそのまま使う。この端末の Caches フォルダにだけ保存し、ログアウト時に削除する。
nonisolated enum AttachmentCache {
  private static var directory: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("attachments", isDirectory: true)
  }

  static func load(_ name: String) -> Data? {
    try? Data(contentsOf: directory.appendingPathComponent(sanitized(name)))
  }

  static func save(_ data: Data, name: String) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? data.write(to: directory.appendingPathComponent(sanitized(name)), options: .atomic)
  }

  static func clear() {
    try? FileManager.default.removeItem(at: directory)
  }

  /// ファイル名として安全な文字だけにする。
  private static func sanitized(_ name: String) -> String {
    String(name.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" ? $0 : "_" })
  }
}
