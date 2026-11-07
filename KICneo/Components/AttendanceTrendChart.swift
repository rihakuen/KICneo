import Charts
import SwiftUI

/// 出席率の推移のグラフ。ホームの出席率カードをタップすると、カードの中に広がって出る。
/// 折れ線は出欠の記録から、期間のはじめから数えた「その日までの出席率」（遅刻3回で欠席1回の学校の数え方）。
/// 指でなぞると、その日の出席率とコマ数を出す。期間はカードで選んでいる 月間 / 年間 / 総合 に合わせる。
struct AttendanceTrendChart: View {
  let records: [AttendanceDay]
  let rates: AttendanceRates
  /// ホームで表示している月（月間・年間の範囲はこの月から決める）
  let month: Date
  let scope: AttendanceRateScope
  /// 指でなぞっている位置（横軸の日付）
  @State private var scrubDate: Date?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  struct Point: Identifiable, Equatable {
    let date: Date
    let rate: Double
    let attended: Int
    let total: Int
    var id: Date { date }
  }

  private var calendar: Calendar { AttendanceRatePeriod.calendar }

  /// 表示する範囲。今日より先は数えない。
  private var interval: (start: Date, end: Date)? {
    let today = calendar.startOfDay(for: .now)
    let start: Date
    let end: Date
    switch scope {
    case .month:
      start = AttendanceRatePeriod.monthStart(month)
      end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
    case .year:
      start = AttendanceRatePeriod.yearStart(month)
      end = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: start) ?? start
    case .total:
      guard let first = rates.overallFrom ?? records.map(\.date).min() else { return nil }
      start = calendar.startOfDay(for: first)
      end = today
    }
    guard start <= today else { return nil }
    return (start, min(end, today))
  }

  /// 期間のはじめから、記録のある日ごとに累計した出席率
  private var points: [Point] {
    guard let interval else { return [] }
    var tally = AttendanceTally()
    var result: [Point] = []
    for day in records.sorted(by: { $0.date < $1.date }) {
      let date = calendar.startOfDay(for: day.date)
      guard date >= interval.start, date <= interval.end else { continue }
      let statuses = day.periods.map(\.rawStatus).filter { !$0.isEmpty }
      guard !statuses.isEmpty else { continue }
      for status in statuses { tally.add(status) }
      if let rate = tally.rate {
        result.append(Point(date: date, rate: rate, attended: tally.attended, total: tally.total))
      }
    }
    return result
  }

  private func nearest(_ points: [Point]) -> Point? {
    guard let scrubDate else { return nil }
    return points.min { abs($0.date.timeIntervalSince(scrubDate)) < abs($1.date.timeIntervalSince(scrubDate)) }
  }

  var body: some View {
    let points = points
    let selected = nearest(points)
    // 記録が2日分に満たない期間は、線の代わりに「データなし」を出す
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      if points.count < 2 {
        noDataPlaceholder
      } else {
        infoLine(points: points, selected: selected)
        chart(points: points, selected: selected)
          .frame(height: 140)
        HStack {
          Text(dayText(points.first?.date))
          Spacer()
          Text(dayText(points.last?.date))
        }
        .font(AppTheme.Typography.caption)
        .monospacedDigit()
        .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .onChange(of: selected?.id) { _, newValue in
      if newValue != nil { AppHaptics.selection() }
    }
    .onChange(of: scope) { _, _ in scrubDate = nil }
  }

  /// 線を引けるだけの記録がない期間に出す枠（グラフと同じ高さで、カードの大きさが変わらないようにする）
  private var noDataPlaceholder: some View {
    RoundedRectangle(cornerRadius: 10, style: .continuous)
      .fill(AppTheme.elevatedBackground)
      .frame(height: 140)
      .overlay {
        Text("データなし")
          .font(AppTheme.Typography.body)
          .foregroundStyle(AppTheme.textSecondary)
      }
      .accessibilityElement(children: .combine)
  }

  /// グラフの上の1行：なぞっているときはその日の値、離しているときは最新のコマ数
  private func infoLine(points: [Point], selected: Point?) -> some View {
    let point = selected ?? points.last
    return HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.sm) {
      // 見出しの文字は出さず、なぞっているときだけ日付を出す
      Text(dayText(selected?.date))
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
      Spacer(minLength: AppTheme.Space.sm)
      if let point {
        if selected != nil {
          Text(String(format: "%.2f%%", point.rate))
            .font(AppTheme.Typography.bodyEmphasis)
            .foregroundStyle(AppTheme.primaryAction)
            .contentTransition(.numericText(value: point.rate))
        }
        Text("\(point.attended) / \(point.total)コマ")
          .font(AppTheme.Typography.body)
          .foregroundStyle(AppTheme.textSecondary)
          .contentTransition(.numericText(value: Double(point.attended)))
      }
    }
    .monospacedDigit()
    .animation(AppTheme.Motion.text(reduce: reduceMotion), value: point?.id)
  }

  private func chart(points: [Point], selected: Point?) -> some View {
    // 上下の幅は、値の範囲に少しだけ余白を足す（線が縦に伸びすぎないよう、最低でも20ポイント分の幅をとる）
    let values = points.map(\.rate)
    let minValue = values.min() ?? 0
    let maxValue = values.max() ?? 100
    let span = max(20, maxValue - minValue + 6)
    let upper = min(100, max(maxValue + 3, minValue + span))
    let lower = max(0, upper - span)
    let tint = AppTheme.primaryAction
    return Chart {
      ForEach(points) { point in
        AreaMark(
          x: .value("日付", point.date, unit: .day),
          yStart: .value("下限", lower),
          yEnd: .value("出席率", point.rate))
          .interpolationMethod(.monotone)
          .foregroundStyle(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
        LineMark(x: .value("日付", point.date, unit: .day), y: .value("出席率", point.rate))
          .interpolationMethod(.monotone)
          .foregroundStyle(tint)
          .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
      }
      if let selected {
        RuleMark(x: .value("日付", selected.date, unit: .day))
          .foregroundStyle(tint.opacity(0.35))
          .lineStyle(StrokeStyle(lineWidth: 1))
        PointMark(x: .value("日付", selected.date, unit: .day), y: .value("出席率", selected.rate))
          .symbol {
            Circle()
              .strokeBorder(tint, lineWidth: 2.5)
              .background(Circle().fill(AppTheme.cardBackground))
              .frame(width: 14, height: 14)
          }
      }
    }
    .chartYScale(domain: lower...upper)
    .chartXAxis(.hidden)
    .chartYAxis {
      AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
        AxisGridLine().foregroundStyle(AppTheme.border.opacity(0.5))
        AxisValueLabel {
          if let rate = value.as(Double.self) {
            Text("\(Int(rate))%").font(AppTheme.Typography.caption).foregroundStyle(AppTheme.textSecondary)
          }
        }
      }
    }
    // 少し長押ししてからなぞると、その日の値を出す（離すと消える）。
    // すぐに動かしたときはページのスクロールになるので、グラフの上からでも上下にスクロールできる
    .chartOverlay { proxy in
      GeometryReader { geo in
        Rectangle()
          .fill(.clear)
          .contentShape(Rectangle())
          .gesture(
            LongPressGesture(minimumDuration: 0.15)
              .sequenced(before: DragGesture(minimumDistance: 0))
              .onChanged { value in
                switch value {
                case .second(true, nil):
                  if scrubDate == nil { AppHaptics.light() }
                case .second(true, let drag?):
                  guard let frame = proxy.plotFrame else { return }
                  let x = min(max(drag.location.x - geo[frame].origin.x, 0), geo[frame].width)
                  scrubDate = proxy.value(atX: x, as: Date.self)
                default:
                  break
                }
              }
              .onEnded { _ in scrubDate = nil })
      }
    }
    .accessibilityLabel("出席率の推移")
    .accessibilityValue(points.last.map { String(format: "最新 %.2f%%", $0.rate) } ?? "")
  }

  private func dayText(_ date: Date?) -> String {
    guard let date else { return "" }
    let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
    let weekday = ["日", "月", "火", "水", "木", "金", "土"][((c.weekday ?? 1) - 1) % 7]
    let year = scope == .total ? "\(c.year ?? 0)/" : ""
    return "\(year)\(c.month ?? 0)/\(c.day ?? 0)(\(weekday))"
  }
}

#Preview("出席率の推移") {
  let days = DemoData.attendance
  AttendanceTrendChart(records: days, rates: DemoData.rates(for: days).rates, month: .now, scope: .month)
    .padding(AppTheme.Space.card)
    .walletCard()
    .padding(AppTheme.Space.page)
    .background(AppTheme.background)
}
