import Foundation

/// iPhone の「カレンダー」App に追加する予定の下書き（説明会から作る）。
nonisolated struct CalendarDraft: Identifiable, Equatable, Sendable {
  let id = UUID()
  let title: String
  let start: Date
  let end: Date
  let isAllDay: Bool
  let location: String?
  let notes: String?

  /// 学校の書き方の開催日時（例：「26/11/05(木) 11:20〜12:10」）から下書きを作る。
  /// 日付が読めなければ nil。時刻が無ければ終日、終了時刻が無ければ開始から1時間とする。
  static func make(title: String, schedule: String, location: String?, notes: String?) -> CalendarDraft? {
    guard let parsed = parse(schedule) else { return nil }
    return CalendarDraft(
      title: title, start: parsed.start, end: parsed.end, isAllDay: parsed.isAllDay,
      location: location.flatMap { $0.isEmpty ? nil : $0 }, notes: notes.flatMap { $0.isEmpty ? nil : $0 })
  }

  /// 開催日時の文字から、開始・終了の日時を読む（学校の暦＝日本時間）。
  static func parse(_ schedule: String) -> (start: Date, end: Date, isAllDay: Bool)? {
    let text = schedule.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? schedule
    guard let dateMatch = text.firstMatch(of: #/(\d{2,4})/(\d{1,2})/(\d{1,2})/#),
          var year = Int(dateMatch.1), let month = Int(dateMatch.2), let day = Int(dateMatch.3) else { return nil }
    if year < 100 { year += 2000 }
    let calendar = AttendanceRatePeriod.calendar
    guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
          calendar.component(.month, from: date) == month, calendar.component(.day, from: date) == day else { return nil }

    // 日付より後ろにある時刻（最大2つ）を、開始・終了とする
    let rest = text[dateMatch.range.upperBound...]
    let times: [(Int, Int)] = rest.matches(of: #/(\d{1,2}):(\d{2})/#).prefix(2).compactMap { match in
      guard let hour = Int(match.1), let minute = Int(match.2), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
      return (hour, minute)
    }
    guard let first = times.first,
          let start = calendar.date(bySettingHour: first.0, minute: first.1, second: 0, of: date) else {
      // 時刻が無い：終日の予定
      let next = calendar.date(byAdding: .day, value: 1, to: date) ?? date
      return (date, next, true)
    }
    var end = start.addingTimeInterval(60 * 60)
    if times.count > 1, let last = times.last,
       let candidate = calendar.date(bySettingHour: last.0, minute: last.1, second: 0, of: date), candidate > start {
      end = candidate
    }
    return (start, end, false)
  }
}
