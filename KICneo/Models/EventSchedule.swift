import Foundation

/// 学校の 開催日 / 時間01 / 時間02 を表示用に整える。タイトルや申込期間は読まない。
nonisolated struct EventSchedule {
  let original: String
  let day: String?
  let monthAndWeekday: String?
  let time: String?

  init(_ raw: String?) {
    let value = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    original = value
    let pattern = #"(?<![0-9])(?:(?:[0-9]{4}|[0-9]{2})[/年])?([0-9]{1,2})[/月]([0-9]{1,2})日?(?:\s*[（(]([月火水木金土日])(?:曜日)?[）)])?(?![0-9])"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
          let monthRange = Range(match.range(at: 1), in: value),
          let dayRange = Range(match.range(at: 2), in: value),
          let month = Int(value[monthRange]), let number = Int(value[dayRange]),
          (1...12).contains(month),
          (1...[31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]).contains(number) else {
      day = nil
      monthAndWeekday = nil
      time = nil
      return
    }
    if let fullRange = Range(match.range, in: value) {
      let pieces = value[fullRange].components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
      if pieces.count >= 3, let yearValue = Int(pieces[0]) {
        let year = pieces[0].count == 2 ? 2000 + yearValue : yearValue
        let calendar = Calendar(identifier: .gregorian)
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: number)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == number else {
          day = nil
          monthAndWeekday = nil
          time = nil
          return
        }
      }
    }
    day = String(number)
    if let weekdayRange = Range(match.range(at: 3), in: value) {
      monthAndWeekday = "\(month)月 / \(value[weekdayRange])"
    } else {
      monthAndWeekday = "\(month)月"
    }
    let matchedRange = Range(match.range, in: value)
    let remainder = matchedRange.map { String(value[$0.upperBound...]) } ?? ""
    let timeRegex = try? NSRegularExpression(pattern: #"(?<![0-9])(?:[01]?[0-9]|2[0-3]):[0-5][0-9](?![0-9])"#)
    let times = timeRegex?.matches(in: remainder, range: NSRange(remainder.startIndex..., in: remainder))
      .compactMap { Range($0.range, in: remainder).map { String(remainder[$0]) } } ?? []
    time = times.isEmpty ? nil : times.prefix(2).joined(separator: " – ")
  }
}
