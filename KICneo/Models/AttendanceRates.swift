import Foundation

nonisolated enum AttendanceRateScope: Int, CaseIterable, Identifiable, Codable, Sendable {
  case month, year, total
  var id: Int { rawValue }
  var title: String { switch self { case .month: "月"; case .year: "年"; case .total: "総合" } }
  var heading: String { switch self { case .month: "月間出席率"; case .year: "年間出席率"; case .total: "総出席率" } }
}

/// 月・学年・総合は、それぞれ学校の集計ページへの別々の問い合わせ。学年は4月1日に始まる。
nonisolated struct AttendanceRatePeriod: Hashable, Codable, Sendable {
  let scope: AttendanceRateScope
  let from: Date
  let through: Date

  /// 学校の暦（西暦・日本時間）。出欠・時間割・出席率の日付はすべてこれで扱う。
  /// 端末の設定（海外のタイムゾーン、和暦など）に左右されないよう、Calendar.current は使わない。
  static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return calendar
  }
  static func monthStart(_ date: Date) -> Date {
    calendar.date(from: calendar.dateComponents([.year, .month], from: date))!
  }
  static func yearStart(_ date: Date) -> Date {
    let parts = calendar.dateComponents([.year, .month], from: date)
    return calendar.date(from: DateComponents(year: parts.year! - (parts.month! < 4 ? 1 : 0), month: 4, day: 1))!
  }
  static func make(_ scope: AttendanceRateScope, month: Date, overallStart: Date?, now: Date = .now) -> Self? {
    let today = calendar.startOfDay(for: now)
    let start: Date
    let end: Date
    switch scope {
    case .month:
      start = monthStart(month)
      end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
    case .year:
      start = yearStart(month)
      end = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: start)!
    case .total:
      guard let overallStart else { return nil }
      start = calendar.startOfDay(for: overallStart)
      end = today
    }
    guard start <= today else { return nil }
    return Self(scope: scope, from: start, through: min(end, today))
  }
  static func batch(months: [Date], overallStart: Date?, includeOverall: Bool, now: Date = .now) -> [Self] {
    var periods = Set(months.flatMap { month in
      [make(.month, month: month, overallStart: nil, now: now), make(.year, month: month, overallStart: nil, now: now)].compactMap { $0 }
    })
    if includeOverall, let total = make(.total, month: now, overallStart: overallStart, now: now) { periods.insert(total) }
    return periods.sorted { $0.scope == $1.scope ? $0.from > $1.from : $0.scope.rawValue < $1.scope.rawValue }
  }
}

/// 学校が出した出席率そのもの。月の出席率の平均や、日ごとの出欠から計算した推定値ではない。
/// 学年の項目がない古いキャッシュも読めるよう、デコードを明示的に書いている。
nonisolated struct AttendanceRates: Equatable, Codable, Sendable {
  var overall: Double?
  var overallFrom: Date?
  var overallThrough: Date?
  var monthly: [Date: Double] = [:]
  var yearly: [Date: Double] = [:]
  var monthlyThrough: [Date: Date] = [:]
  var yearlyThrough: [Date: Date] = [:]

  init() {}
  private enum CodingKeys: String, CodingKey {
    case overall, overallFrom, overallThrough, monthly, yearly, monthlyThrough, yearlyThrough
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    overall = try c.decodeIfPresent(Double.self, forKey: .overall)
    overallFrom = try c.decodeIfPresent(Date.self, forKey: .overallFrom)
    overallThrough = try c.decodeIfPresent(Date.self, forKey: .overallThrough)
    monthly = try c.decodeIfPresent([Date: Double].self, forKey: .monthly) ?? [:]
    yearly = try c.decodeIfPresent([Date: Double].self, forKey: .yearly) ?? [:]
    monthlyThrough = try c.decodeIfPresent([Date: Date].self, forKey: .monthlyThrough) ?? [:]
    yearlyThrough = try c.decodeIfPresent([Date: Date].self, forKey: .yearlyThrough) ?? [:]
  }
  func value(_ scope: AttendanceRateScope, month: Date) -> Double? {
    switch scope {
    case .month: monthly[AttendanceRatePeriod.monthStart(month)]
    case .year: yearly[AttendanceRatePeriod.yearStart(month)]
    case .total: overallFrom == nil ? nil : overall
    }
  }
  func through(_ scope: AttendanceRateScope, month: Date) -> Date? {
    switch scope {
    case .month: monthlyThrough[AttendanceRatePeriod.monthStart(month)]
    case .year: yearlyThrough[AttendanceRatePeriod.yearStart(month)]
    case .total: overallThrough
    }
  }
  mutating func update(_ value: Double?, for period: AttendanceRatePeriod) {
    switch period.scope {
    case .month:
      monthly[period.from] = value
      monthlyThrough[period.from] = period.through
    case .year:
      yearly[period.from] = value
      yearlyThrough[period.from] = period.through
    case .total:
      overall = value; overallFrom = period.from; overallThrough = period.through
    }
  }
}
