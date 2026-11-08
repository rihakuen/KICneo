import Foundation

/// 学校から取得した個人データ（出欠・出席率・時間割・就職活動の履歴・説明会の一覧と詳細・学生証）の端末キャッシュ。
/// 学校のページは重いので、開いたときは前回の内容を先に表示し、背景で更新する。
/// この端末の Caches フォルダにだけ保存し、別のアカウントのデータは読まない。ログアウト時に削除する。
nonisolated enum AccountCache {
  /// 添付のリンクを持たない古い保存内容を読み込まないよう、名前に版を付けている
  static let huntActivities = "hunt_activities_v2"
  static let timetable = "timetable"
  static let schoolEvents = "school_events"
  /// 旧版の "attendance" は removeLegacy() が起動時に消すので、別の名前にする（同じ名前だと毎回消えてしまう）
  static let attendance = "attendance_v2"
  static let attendanceRates = "attendance_rates_v2"
  static let studentCard = "student_card"
  static let eventDetails = "event_details"
  static let grades = "grades"
  static let notices = "school_notices"
  static let noticeDetails = "school_notice_details"

  /// 最後にログインしたアカウント。起動直後（ログインが終わる前）に、そのアカウントの保存内容を先に表示するために使う。
  static var lastAccountID: String? {
    get { UserDefaults.standard.string(forKey: "school_last_account_id") }
    set { UserDefaults.standard.set(newValue, forKey: "school_last_account_id") }
  }

  private struct Payload<T: Codable>: Codable {
    let accountID: String
    let items: [T]
  }

  private static func url(_ name: String) -> URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("\(name)_cache.json")
  }

  static func load<T: Codable>(_ name: String, accountID: String?) -> [T] {
    guard let accountID, let data = try? Data(contentsOf: url(name)),
          let payload = try? JSONDecoder().decode(Payload<T>.self, from: data),
          payload.accountID == accountID else { return [] }
    return payload.items
  }

  static func save<T: Codable>(_ items: [T], name: String, accountID: String) {
    guard let data = try? JSONEncoder().encode(Payload(accountID: accountID, items: items)) else { return }
    try? data.write(to: url(name), options: .atomic)
  }

  static func hasCache(_ name: String) -> Bool {
    FileManager.default.fileExists(atPath: url(name).path)
  }

  /// 古い出欠を削除し、出席率は学年の値を保持できるキャッシュへ移行する。
  static func removeLegacy() {
    try? FileManager.default.removeItem(at: url("attendance"))
    let oldRates = url("attendance_rates")
    if !FileManager.default.fileExists(atPath: url(attendanceRates).path) {
      try? FileManager.default.copyItem(at: oldRates, to: url(attendanceRates))
    }
    try? FileManager.default.removeItem(at: oldRates)
  }

  static func clearAll() {
    lastAccountID = nil
    try? FileManager.default.removeItem(at: url("attendance_rates"))
    try? FileManager.default.removeItem(at: url("hunt_activities")) // 旧版の保存内容
    for name in [huntActivities, timetable, schoolEvents, attendance, attendanceRates, studentCard, eventDetails, grades] {
      try? FileManager.default.removeItem(at: url(name))
    }
  }
}
