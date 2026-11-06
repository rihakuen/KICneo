import Foundation

/// 画面表示専用の変換。SchoolEvent / KICEvent とその Codable の形は変えない。
nonisolated enum EventPresentation {
  static func companyTitle(_ event: KICEvent) -> String {
    if let company = event.companyName?.trimmingCharacters(in: .whitespacesAndNewlines),
       !company.isEmpty, !["解析失败", "解析失敗"].contains(company) { return company }
    let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleaned = title.replacingOccurrences(
      of: #"[\s　]+(?:オンライン(?:学内)?|学内|校内|企業|会社)?説明会\s*$"#,
      with: "", options: .regularExpression)
    return cleaned.isEmpty ? title : cleaned
  }
}

/// 日時は学校の項目だけから決める。AI のタグや説明会のタイトルからは読まない。
nonisolated struct SchoolEventTiming {
  let start: Date?
  let end: Date?
  let day: Date?
  let deadline: Date?
  let deadlineHasTime: Bool
  static var calendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return c
  }

  init(schedule: String, applicationPeriod: String) {
    let eventTokens = Self.tokens(schedule, fallbackYear: nil)
    day = eventTokens.first?.date
    start = eventTokens.first.flatMap { $0.hasTime ? $0.date : nil }
    if let first = eventTokens.first, first.hasTime {
      if eventTokens.count > 1, let last = eventTokens.last, last.hasTime, last.date >= first.date {
        end = last.date
      } else {
        let clocks = Self.clocks(schedule)
        if eventTokens.count == 1, clocks.count == 2,
           let candidate = Self.calendar.date(bySettingHour: clocks[1].0, minute: clocks[1].1, second: 0, of: first.date),
           candidate > first.date {
          end = candidate
        } else { end = nil }
      }
    } else { end = nil }
    let year = day.map { Self.calendar.component(.year, from: $0) }
    let applications = Self.tokens(applicationPeriod, fallbackYear: year)
    deadline = applications.last?.date
    deadlineHasTime = applications.last?.hasTime ?? false
  }

  private struct Token { let date: Date; let hasTime: Bool }
  private static func tokens(_ raw: String, fallbackYear: Int?) -> [Token] {
    let text = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
    let pattern = #"(?<![0-9])(?:(\d{4}|\d{2})[/年.-])?(\d{1,2})[/月.-](\d{1,2})日?(?:\s*[（(][^）)]*[）)])?(?:\s*(\d{1,2}):(\d{2}))?(?![0-9])"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    var year = fallbackYear
    var previous: Date?
    var result: [Token] = []
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      func number(_ index: Int) -> Int? {
        Range(match.range(at: index), in: text).flatMap { Int(text[$0]) }
      }
      let explicitYear = number(1).map { $0 < 100 ? 2000 + $0 : $0 }
      if let explicitYear { year = explicitYear }
      guard var y = year, let month = number(2), let day = number(3) else { continue }
      let h = number(4), m = number(5)
      guard (1...12).contains(month), (1...31).contains(day),
            (0...23).contains(h ?? 0), (0...59).contains(m ?? 0) else { continue }
      // 「26/12/20～1/10」のような期間は、年を引き継いで1月にまたがる。
      if explicitYear == nil, let previous, month < calendar.component(.month, from: previous) {
        y += 1
        year = y
      }
      guard let date = calendar.date(from: DateComponents(year: y, month: month, day: day, hour: h ?? 0, minute: m ?? 0)),
            calendar.component(.year, from: date) == y,
            calendar.component(.month, from: date) == month,
            calendar.component(.day, from: date) == day else { continue }
      result.append(Token(date: date, hasTime: h != nil && m != nil))
      previous = date
    }
    return result
  }

  private static func clocks(_ raw: String) -> [(Int, Int)] {
    let text = raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw
    guard let regex = try? NSRegularExpression(pattern: #"(?<![0-9])([0-9]{1,2}):([0-9]{2})(?![0-9])"#) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
      guard let h = Range(match.range(at: 1), in: text), let m = Range(match.range(at: 2), in: text),
            let hour = Int(text[h]), let minute = Int(text[m]), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
      return (hour, minute)
    }
  }
}

nonisolated struct EventCountdown: Equatable {
  let label: String
  let value: String

  init(timing: SchoolEventTiming, applied: Bool, status: String, now: Date) {
    if let end = timing.end, now >= end {
      label = "開催終了"; value = ""; return
    }
    if let start = timing.start, now >= start, let end = timing.end {
      label = "終了まで"; value = Self.remaining(end, now: now); return
    }
    let closed = status.contains("期間外") || status.contains("終了") || status.contains("満席")
    if !applied, !closed, let deadline = timing.deadline {
      if timing.deadlineHasTime, now < deadline {
        label = "申込締切まで"; value = Self.remaining(deadline, now: now); return
      }
      if !timing.deadlineHasTime,
         SchoolEventTiming.calendar.startOfDay(for: now) <= deadline {
        label = "申込締切"; value = Self.dateLabel(deadline); return
      }
    }
    if let start = timing.start, now < start {
      label = "開催まで"; value = Self.remaining(start, now: now); return
    }
    if let day = timing.day {
      label = "開催日"; value = Self.dateLabel(day); return
    }
    label = "日程未定"; value = ""
  }

  private static func dateLabel(_ date: Date) -> String {
    let c = SchoolEventTiming.calendar
    return "\(c.component(.month, from: date))/\(c.component(.day, from: date))"
  }
  private static func remaining(_ target: Date, now: Date) -> String {
    let minutes = max(0, Int(target.timeIntervalSince(now) / 60))
    if minutes < 1 { return "1分未満" }
    let days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60
    if days > 0 { return "\(days)日 \(hours)時間" }
    if hours > 0 { return "\(hours)時間 \(mins)分" }
    return "\(mins)分"
  }
}

/// 日付だけの締切は、学校の暦でその日いっぱい有効とする。
/// 時・分のカウントダウンを勝手に作らない。
nonisolated struct EventApplicationDeadline {
  let date: Date?
  let boundary: Date?
  let isExpired: Bool
  let value: String
  let dateText: String
  var sortGroup: Int { date == nil ? 2 : (isExpired ? 1 : 0) }

  init(source: SchoolEvent?, now: Date) {
    let timing = SchoolEventTiming(schedule: source?.date ?? "", applicationPeriod: source?.applyPeriod ?? "")
    date = timing.deadline
    let calendar = SchoolEventTiming.calendar
    guard let deadline = timing.deadline else {
      boundary = nil; isExpired = false; value = "未定"; dateText = "学校サイトで確認"; return
    }
    boundary = timing.deadlineHasTime ? deadline : calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: deadline))
    isExpired = boundary.map { now >= $0 } ?? false
    let month = calendar.component(.month, from: deadline), day = calendar.component(.day, from: deadline)
    let hour = calendar.component(.hour, from: deadline), minute = calendar.component(.minute, from: deadline)
    dateText = timing.deadlineHasTime
      ? String(format: "%d/%d %02d:%02d", month, day, hour, minute) : "\(month)/\(day)まで"
    if isExpired { value = "受付終了"; return }
    if timing.deadlineHasTime {
      let seconds = deadline.timeIntervalSince(now)
      if seconds < 60 { value = "まもなく締切"; return }
      if seconds < 3600 { value = "あと\(Int(ceil(seconds / 60)))分"; return }
      if seconds < 86400 { value = "あと\(Int(ceil(seconds / 3600)))時間"; return }
    }
    let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: deadline)).day ?? 0
    value = days == 0 ? "本日締切" : "あと\(days)日"
  }

  static func ordered(_ events: [KICEvent], source: (KICEvent) -> SchoolEvent?, now: Date) -> [KICEvent] {
    events.enumerated().map { (index: $0.offset, event: $0.element, deadline: Self(source: source($0.element), now: now)) }
      .sorted { lhs, rhs in
        if lhs.deadline.sortGroup != rhs.deadline.sortGroup { return lhs.deadline.sortGroup < rhs.deadline.sortGroup }
        if let left = lhs.deadline.date, let right = rhs.deadline.date, left != right { return left < right }
        return lhs.index < rhs.index
      }.map(\.event)
  }
}
