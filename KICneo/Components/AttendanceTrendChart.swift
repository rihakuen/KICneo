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
  /// 指でなぞっている位置（横軸のサンプルの番号）
  @State private var scrubIndex: Int?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// 線を描くための点。期間の最初〜最後の記録の間を、決まった数に等間隔で区切った位置の値。
  /// 横の位置（番号）がいつも同じなので、月や期間を切り替えると、線は横から入れ替わらず上下に形を変える。
  struct Sample: Identifiable, Equatable {
    let index: Int
    let date: Date
    /// 線の高さ（前後の記録の間をなめらかにつないだ値）
    let lineRate: Double
    /// その日までに分かっている記録の値（なぞったときに出す）
    let rate: Double
    let attended: Int
    let total: Int
    var id: Int { index }
  }

  private static let sampleCount = 48

  private func samples(_ points: [Point]) -> [Sample] {
    guard let first = points.first, let last = points.last, points.count >= 2 else { return [] }
    let span = last.date.timeIntervalSince(first.date)
    var j = 0
    return (0..<Self.sampleCount).map { i in
      let t = first.date.addingTimeInterval(span * Double(i) / Double(Self.sampleCount - 1))
      while j + 1 < points.count, points[j + 1].date <= t { j += 1 }
      let a = points[j]
      let b = points[min(j + 1, points.count - 1)]
      let gap = b.date.timeIntervalSince(a.date)
      let f = gap > 0 ? min(1, max(0, t.timeIntervalSince(a.date) / gap)) : 0
      return Sample(index: i, date: t, lineRate: a.rate + (b.rate - a.rate) * f,
                    rate: a.rate, attended: a.attended, total: a.total)
    }
  }

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

  var body: some View {
    let points = points
    let samples = samples(points)
    let selected = scrubIndex.flatMap { index in samples.first { $0.index == index } }
    // 記録が2日分に満たない期間は、線の代わりに「データなし」を出す
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      if samples.isEmpty {
        noDataPlaceholder
      } else {
        infoLine(latest: points.last, selected: selected)
        chart(samples: samples, selected: selected)
          .frame(height: 140)
        HStack {
          Text(dayText(points.first?.date))
          Spacer()
          Text(dayText(points.last?.date))
        }
        .font(AppTheme.Typography.caption)
        .monospacedDigit()
        .foregroundStyle(AppTheme.textSecondary)
        .contentTransition(.numericText())
      }
    }
    .onChange(of: selected?.id) { _, newValue in
      if newValue != nil { AppHaptics.selection() }
    }
    .onChange(of: scope) { _, _ in scrubIndex = nil }
    .onChange(of: month) { _, _ in scrubIndex = nil }
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
  private func infoLine(latest: Point?, selected: Sample?) -> some View {
    let rate = selected?.rate ?? latest?.rate
    let attended = selected?.attended ?? latest?.attended
    let total = selected?.total ?? latest?.total
    return HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.sm) {
      // 見出しの文字は出さず、なぞっているときだけ日付を出す
      Text(dayText(selected?.date))
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
      Spacer(minLength: AppTheme.Space.sm)
      if selected != nil, let rate {
        Text(String(format: "%.2f%%", rate))
          .font(AppTheme.Typography.bodyEmphasis)
          .foregroundStyle(AppTheme.primaryAction)
          .contentTransition(.numericText(value: rate))
      }
      if let attended, let total {
        Text("\(attended) / \(total)コマ")
          .font(AppTheme.Typography.body)
          .foregroundStyle(AppTheme.textSecondary)
          .contentTransition(.numericText(value: Double(attended)))
      }
    }
    .monospacedDigit()
    .animation(AppTheme.Motion.text(reduce: reduceMotion), value: selected?.id)
    .animation(AppTheme.Motion.text(reduce: reduceMotion), value: attended)
  }

  private func chart(samples: [Sample], selected: Sample?) -> some View {
    // 上下の幅は、値の範囲に少しだけ余白を足す（線が縦に伸びすぎないよう、最低でも20ポイント分の幅をとる）
    let values = samples.map(\.lineRate)
    let minValue = values.min() ?? 0
    let maxValue = values.max() ?? 100
    let span = max(20, maxValue - minValue + 6)
    let upper = min(100, max(maxValue + 3, minValue + span))
    let lower = max(0, upper - span)
    let tint = AppTheme.primaryAction
    return Chart {
      ForEach(samples) { sample in
        AreaMark(
          x: .value("位置", sample.index),
          yStart: .value("下限", lower),
          yEnd: .value("出席率", sample.lineRate))
          .interpolationMethod(.monotone)
          .foregroundStyle(LinearGradient(colors: [tint.opacity(0.16), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
        LineMark(x: .value("位置", sample.index), y: .value("出席率", sample.lineRate))
          .interpolationMethod(.monotone)
          .foregroundStyle(tint)
          .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
      }
      if let selected {
        RuleMark(x: .value("位置", selected.index))
          .foregroundStyle(tint.opacity(0.35))
          .lineStyle(StrokeStyle(lineWidth: 1))
        PointMark(x: .value("位置", selected.index), y: .value("出席率", selected.lineRate))
          .symbol {
            Circle()
              .strokeBorder(tint, lineWidth: 2.5)
              .background(Circle().fill(AppTheme.cardBackground))
              .frame(width: 14, height: 14)
          }
      }
    }
    .chartYScale(domain: lower...upper)
    // 横軸は「最初の記録の日〜最後の記録の日」を等間隔に区切った番号。日数が少なくても線は左右いっぱい
    .chartXScale(domain: 0...(Self.sampleCount - 1))
    .chartXAxis(.hidden)
    // グラフの範囲がわかるよう、描画域を細い枠で囲む
    .chartPlotStyle { plot in
      plot.overlay {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
          .strokeBorder(AppTheme.border.opacity(0.7), lineWidth: 1)
      }
    }
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
    // 月や期間を切り替えたとき、同じ位置の点が上下に動いて線の形が変わる
    .animation(reduceMotion ? nil : .smooth(duration: 0.5), value: values)
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
                  if scrubIndex == nil { AppHaptics.light() }
                case .second(true, let drag?):
                  guard let frame = proxy.plotFrame else { return }
                  let x = min(max(drag.location.x - geo[frame].origin.x, 0), geo[frame].width)
                  if let position = proxy.value(atX: x, as: Double.self) {
                    scrubIndex = min(max(Int(position.rounded()), 0), Self.sampleCount - 1)
                  }
                default:
                  break
                }
              }
              .onEnded { _ in scrubIndex = nil })
      }
    }
    .accessibilityLabel("出席率の推移")
    .accessibilityValue(samples.last.map { String(format: "最新 %.2f%%", $0.rate) } ?? "")
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
