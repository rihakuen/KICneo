import Foundation

/// 学校から「いつ取得したか」と「もう変わらない（確定した）範囲」を、アカウントごとに端末へ記録する。
/// 前回の取得から十分新しいデータや、確定した過去の出欠・月の出席率は、起動のたびに学校へ取り直さない。
/// 画面には保存済みの内容（AccountCache）がそのまま出るので、取り直さなくても表示は変わらない。
nonisolated enum FetchLog {
  enum Key: String {
    case timetable, schoolEvents, huntActivities, studentCard, grades
    /// 学校からのお知らせ（トップページの未読の一覧）
    case notices
    /// 出欠と出席率（まとめて1つの期限で扱う）
    case attendance
  }

  /// 前回の取得からこの秒数がたつまでは取り直さない（下に引いて更新したときは必ず取り直す）。
  /// 学校のデータは数日に一度しか変わらないので、最初に取得した内容を端末に保存し、期限の間は学校に問い合わせない。
  static func ttl(_ key: Key) -> TimeInterval {
    switch key {
    case .schoolEvents: 30 * 60            // 説明会の一覧（残席・締切が動くので短め）
    case .notices: 30 * 60                 // お知らせ（トップページを1回読むだけなので短め）
    case .huntActivities: 6 * 60 * 60      // 就職活動
    case .attendance, .grades: 24 * 60 * 60 // 出欠・出席率・成績
    case .timetable: 7 * 24 * 60 * 60      // 時間割
    case .studentCard: 30 * 24 * 60 * 60   // 学生証
    }
  }

  /// 月が終わってからこの日数がたった月は、出欠と月の出席率を「確定」とみなす（学校側の修正を待つ猶予）
  static let settleDays = 14

  private struct Store: Codable {
    var fetched: [String: Date] = [:]
    var settledMonths: Set<Date> = []
    var settledRates: Set<AttendanceRatePeriod> = []
  }

  /// v2：以前は、学校のページを読めなかった月まで「確定（空の月）」として記録していたため、記録をいったん作り直す。
  /// 古い記録（"fetch_log_" で始まるキー）はログアウト時の clearAll() でまとめて消える。
  private static let prefix = "fetch_log_v2_"

  private static func load(_ account: String) -> Store {
    guard let data = UserDefaults.standard.data(forKey: prefix + account),
          let store = try? JSONDecoder().decode(Store.self, from: data) else { return Store() }
    return store
  }

  private static func update(_ account: String?, _ change: (inout Store) -> Void) {
    guard let account else { return }
    var store = load(account)
    change(&store)
    if let data = try? JSONEncoder().encode(store) {
      UserDefaults.standard.set(data, forKey: prefix + account)
    }
  }

  // MARK: 有効期限のあるデータ

  static func isFresh(_ key: Key, account: String?, now: Date = .now) -> Bool {
    guard let account, let last = load(account).fetched[key.rawValue] else { return false }
    return now.timeIntervalSince(last) < ttl(key)
  }

  static func markFetched(_ key: Key, account: String?, at date: Date = .now) {
    update(account) { $0.fetched[key.rawValue] = date }
  }

  /// 最後に取得した時刻
  static func lastFetched(_ key: Key, account: String?) -> Date? {
    account.flatMap { load($0).fetched[key.rawValue] }
  }

  /// 期限を切らす（下に引いて更新したとき、期限に関係なく取り直すため）
  static func markStale(_ key: Key, account: String?) {
    update(account) { $0.fetched[key.rawValue] = nil }
  }

  // MARK: 確定した出欠・出席率

  /// `monthStart` の月が終わって `settleDays` 日たったか
  static func isSettled(monthStart: Date, calendar: Calendar = AttendanceRatePeriod.calendar, now: Date = .now) -> Bool {
    guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart),
          let settled = calendar.date(byAdding: .day, value: settleDays, to: nextMonth) else { return false }
    return now >= settled
  }

  static func settledMonths(account: String?) -> Set<Date> {
    account.map { load($0).settledMonths } ?? []
  }

  /// 取得できた月のうち、確定した月だけを記録する
  static func markMonthsSettled(_ months: [Date], account: String?, calendar: Calendar = AttendanceRatePeriod.calendar, now: Date = .now) {
    let settled = months.filter { isSettled(monthStart: $0, calendar: calendar, now: now) }
    guard !settled.isEmpty else { return }
    update(account) { $0.settledMonths.formUnion(settled) }
  }

  static func settledRates(account: String?) -> Set<AttendanceRatePeriod> {
    account.map { load($0).settledRates } ?? []
  }

  /// 取得できた出席率のうち、確定した月（と終わった学年）だけを記録する。総合は毎回変わるので記録しない。
  static func markRatesSettled(_ periods: [AttendanceRatePeriod], account: String?, now: Date = .now) {
    let calendar = AttendanceRatePeriod.calendar
    let settled = periods.filter { period in
      guard period.scope != .total,
            let limit = calendar.date(byAdding: .day, value: settleDays + 1, to: period.through) else { return false }
      // 学年は3月31日まで集計し終わっていること（途中で取った値は確定ではない）
      if period.scope == .year {
        let end = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: period.from) ?? period.through
        guard calendar.isDate(period.through, inSameDayAs: end) else { return false }
      }
      return now >= limit
    }
    guard !settled.isEmpty else { return }
    update(account) { $0.settledRates.formUnion(settled) }
  }

  // MARK: 削除

  /// ログアウト時：すべてのアカウントの記録を消す
  static func clearAll() {
    for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("fetch_log_") {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}
