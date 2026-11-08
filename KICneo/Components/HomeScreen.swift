import SwiftUI

/// ホーム。上から「見出し」「出席率（詰めた1枚）」「カレンダー（週 / 月）」。スクロールしなくてもカレンダーまで操作できる。
/// カレンダーは右上の「週 / 月」で切り替える（選んだ表示は端末に保存）。どちらも左右スワイプで週・月を送る。
/// 日付をタップすると、その日の授業・出欠を時限ごとに並べたシートを下から開く（半分の高さ、上に引くと全画面）。
/// 表示する値はすべて学校から取得した出欠（records）・時間割（timetable）・出席率（rates）。
struct HomeScreen: View {
  var records: [AttendanceDay]
  var rates: AttendanceRates
  var loadedRatePeriods: Set<AttendanceRatePeriod>
  var loadingRatePeriods: Set<AttendanceRatePeriod>
  var failedRatePeriods: Set<AttendanceRatePeriod>
  var errorMessage: String?
  var loadedMonths: Set<Date>
  var loadingMonths: Set<Date>
  var timetable: [TimetableDay]
  var isLoadingTimetable: Bool
  var timetableLoadFailed: Bool
  var onRefresh: () async -> Void
  /// 表示する月が変わったとき（初回表示を含む）に、その月の出欠・出席率を取得してもらう。
  var onMonthChange: (_ from: Date, _ through: Date) async -> Void
  /// カレンダーの下に置く「学校からのお知らせ」（ContentView から渡す。プレビューでは無し）
  var noticesSection: AnyView

  /// 日付ごとの記録。セルごとに作り直さないよう、初期化時に1回だけ作る。
  private let attendanceByDay: [Date: AttendanceDay]
  private let lessonsByDay: [Date: [TimetableLesson]]
  /// 時間割に授業が1つでもある月（月初日）。授業のない平日を「休み」と見なせるのは、この月だけ。
  private let monthsWithTimetable: Set<Date>
  /// 授業のある日（日付順）。最初の授業〜最後の授業の間で授業のない日は「休み」、間が長ければ「長期休暇」とみなす。
  /// （夏休みの8月のように、1か月まるごと授業のない月も休みとして出すため。最後の授業より先は、未発表かもしれないので休みにしない）
  private let lessonDates: [Date]
  /// 記録のある最も古い年の1月は、今月から何か月前か（0 以下）
  private let oldestOffset: Int

  init(
    records: [AttendanceDay],
    rates: AttendanceRates,
    loadedRatePeriods: Set<AttendanceRatePeriod> = [],
    loadingRatePeriods: Set<AttendanceRatePeriod> = [],
    failedRatePeriods: Set<AttendanceRatePeriod> = [],
    errorMessage: String?,
    loadedMonths: Set<Date>,
    loadingMonths: Set<Date>,
    timetable: [TimetableDay],
    isLoadingTimetable: Bool,
    timetableLoadFailed: Bool,
    onRefresh: @escaping () async -> Void,
    onMonthChange: @escaping (_ from: Date, _ through: Date) async -> Void,
    noticesSection: AnyView = AnyView(EmptyView())
  ) {
    self.noticesSection = noticesSection
    self.records = records
    self.rates = rates
    self.loadedRatePeriods = loadedRatePeriods
    self.loadingRatePeriods = loadingRatePeriods
    self.failedRatePeriods = failedRatePeriods
    self.errorMessage = errorMessage
    self.loadedMonths = loadedMonths
    self.loadingMonths = loadingMonths
    self.timetable = timetable
    self.isLoadingTimetable = isLoadingTimetable
    self.timetableLoadFailed = timetableLoadFailed
    self.onRefresh = onRefresh
    self.onMonthChange = onMonthChange
    let calendar = AttendanceRatePeriod.calendar
    attendanceByDay = Dictionary(records.map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { $1 })
    lessonsByDay = Dictionary(timetable.map { (calendar.startOfDay(for: $0.date), $0.lessons) }, uniquingKeysWith: { $1 })
    // 記録（出欠・授業）が最も古い年の1月まで。記録がまだ何も無いときは、今年の1月まで。
    let recordDates = records.map(\.date) + timetable.filter { !$0.lessons.isEmpty }.map(\.date)
    let oldestYear = calendar.component(.year, from: recordDates.min() ?? Date())
    let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
    let january = calendar.date(from: DateComponents(year: oldestYear, month: 1, day: 1)) ?? thisMonth
    oldestOffset = min(0, calendar.dateComponents([.month], from: thisMonth, to: january).month ?? 0)
    lessonDates = timetable.filter { day in day.lessons.contains { !$0.period.isEmpty } }
      .map { calendar.startOfDay(for: $0.date) }
      .sorted()
    monthsWithTimetable = Set(
      timetable.filter { !$0.lessons.isEmpty }.compactMap {
        calendar.date(from: calendar.dateComponents([.year, .month], from: $0.date))
      })
  }

  /// 選んでいる日。週の帯・下の授業一覧・見出しの月・出席率の月は、すべてこの日から決まる。
  @State private var selectedDate = AttendanceRatePeriod.calendar.startOfDay(for: Date())
  /// 週を送った向き（帯が入れ替わる方向）
  @State private var weekForward = true
  /// 週の帯を指で引いている量（少しだけ付いてくる）
  @State private var weekDragX: CGFloat = 0
  @State private var rateScope: AttendanceRateScope = .month
  /// 今月の内訳の数字（チップ）を広げているか。次に開いたときも同じにする。
  @AppStorage("home_breakdown_expanded") private var showsBreakdown = false
  /// 選んだ日の授業と出欠のシートを開いているか
  @State private var showsDayAgenda = false
  /// 出席率カードの中に推移のグラフを広げているか
  @State private var showsTrend = false
  /// カレンダーの表示（週の帯 / 月のカレンダー）。次に開いたときも同じ表示にする。
  @AppStorage("home_calendar_mode") private var calendarMode: CalendarMode = .week
  // ---- ここから下は月のカレンダーで使う ----
  /// 現在の月を 0 とした月のずれ。左にスワイプすると +1（次の月）。
  @State private var pageOffset = 0
  /// 指に合わせて動かす横のずれ。0 のとき当月が中央にある。
  @State private var dragX: CGFloat = 0
  @State private var isDragging = false
  @State private var pagerWidth: CGFloat = 0
  @State private var showMonthPicker = false
  /// 選択中の日付の反転した面を、セルからセルへ滑らせるため
  @Namespace private var selectionNamespace
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let calendar = AttendanceRatePeriod.calendar
  /// 表示・選択できる月の範囲（今月を 0 としたずれ）。いちばん古い記録（出欠・授業）がある年の1月まで、先は1年後まで。
  /// それより前の年は出さない。
  private var pageRange: ClosedRange<Int> { oldestOffset...12 }
  /// 曜日の行 + 6 週分。5 週の月は下が少し空く。
  /// 月のカレンダーの高さ：曜日の行 + 週の数（4〜6）× 1行の高さ。その月に必要な週の数だけにして、余った行を出さない。
  /// スワイプ中は、行き先の月と今の月の高い方に合わせる（中身が切れないように）。
  private var pagerHeight: CGFloat {
    let target: Date
    if dragX < 0, pageRange.contains(pageOffset + 1) {
      target = monthStart(offset: pageOffset + 1)
    } else if dragX > 0, pageRange.contains(pageOffset - 1) {
      target = monthStart(offset: pageOffset - 1)
    } else {
      target = currentMonth
    }
    return max(gridHeight(target), gridHeight(currentMonth))
  }

  /// 月のカレンダー（曜日の行＋日付）の実際の高さ。描いたときに測った値を使い、まだ測っていない月は行数から見積もる。
  /// 文字サイズの設定や「休」の字でセルが少し高くなっても、最後の週が切れないようにするため。
  private func gridHeight(_ month: Date) -> CGFloat {
    monthGridHeights[month] ?? (24 + CGFloat(weekRows(month)) * 50)
  }

  /// その月を表示するのに必要な週の数（1日の曜日と日数で決まる。4〜6）
  private func weekRows(_ monthStart: Date) -> Int {
    let leading = calendar.component(.weekday, from: monthStart) - 1
    return Int((Double(leading + dates(in: monthStart).count) / 7).rounded(.up))
  }
  /// 画面上端の時計・電波の帯の高さ（上にスクロールした内容をぼかす帯に使う）
  @State private var statusBarHeight: CGFloat = 0
  /// 月ごとに測った、月のカレンダーの高さ（月のはじめの日 → 高さ）
  @State private var monthGridHeights: [Date: CGFloat] = [:]
  /// スワイプ中に見える、月と月のすきま。
  private let pageGap: CGFloat = 32

  // MARK: 月

  private func monthStart(offset: Int) -> Date {
    let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
    return calendar.date(byAdding: .month, value: offset, to: thisMonth) ?? thisMonth
  }

  private var currentMonth: Date {
    monthStart(offset: pageOffset)
  }

  private func dates(in monthStart: Date) -> [Date] {
    guard let range = calendar.range(of: .day, in: .month, for: monthStart) else { return [] }
    return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: monthStart) }
  }

  private func title(_ monthStart: Date) -> String {
    let c = calendar.dateComponents([.year, .month], from: monthStart)
    return "\(c.year ?? 0)年\(c.month ?? 0)月"
  }

  /// 日付の表示。カレンダー上部の「2026年10月」と同じ書き方で、日と曜日を足す（例: 2026年10月19日(月)）。
  private func dayTitle(_ date: Date) -> String {
    let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
    let weekdays = ["日", "月", "火", "水", "木", "金", "土"]
    let weekday = weekdays[((c.weekday ?? 1) - 1) % 7]
    return "\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日(\(weekday))"
  }

  private func monthStart(of date: Date) -> Date {
    calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
  }

  /// 見出し・出席率・内訳が表す月（選んでいる日の月）
  private var focusMonth: Date {
    monthStart(of: selectedDate)
  }

  // MARK: 週

  private enum CalendarMode: String {
    case week, month
  }

  /// 「週 / 月」の切り替え。月にするときは、選んでいる日の月を開いてから切り替える。
  private var calendarModeBinding: Binding<CalendarMode> {
    Binding(
      get: { calendarMode },
      set: { mode in
        guard mode != calendarMode else { return }
        if mode == .month {
          let offset = calendar.dateComponents([.month], from: monthStart(of: Date()), to: focusMonth).month ?? 0
          pageOffset = min(max(offset, pageRange.lowerBound), pageRange.upperBound)
          dragX = 0
        }
        AppHaptics.selection()
        withAnimation(AppTheme.Motion.transition(reduce: reduceMotion)) { calendarMode = mode }
      })
  }

  /// 月のカレンダーで月を送ったら、選んでいる日もその月へ移す（今月なら今日、それ以外は1日）。
  /// 見出し・出席率・内訳・下の授業一覧が、表示中の月とずれないようにするため。
  private func followVisibleMonth() {
    guard calendarMode == .month, monthStart(of: selectedDate) != currentMonth else { return }
    let target = calendar.isDate(currentMonth, equalTo: Date(), toGranularity: .month) ? Date() : currentMonth
    weekForward = target > selectedDate
    withAnimation(AppTheme.Motion.transition(reduce: reduceMotion)) { selectedDate = calendar.startOfDay(for: target) }
  }

  private func weekStart(of date: Date) -> Date {
    let weekday = calendar.component(.weekday, from: date) // 日曜 = 1
    return calendar.startOfDay(for: calendar.date(byAdding: .day, value: -(weekday - 1), to: date) ?? date)
  }

  private var weekStart: Date {
    weekStart(of: selectedDate)
  }

  private var weekDays: [Date] {
    (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
  }

  /// 週の中に含まれる月（月をまたぐ週は2つ）。出欠の取得はこの月ごとに頼む。
  private var monthsInWeek: [Date] {
    Array(Set(weekDays.map { monthStart(of: $0) })).sorted()
  }

  /// 選べる日の範囲（月シートで動ける月の範囲と同じ）
  private var selectableRange: ClosedRange<Date> {
    let lower = monthStart(offset: pageRange.lowerBound)
    let upperMonth = monthStart(offset: pageRange.upperBound)
    return lower...(dates(in: upperMonth).last ?? upperMonth)
  }

  private var weeksFromThisWeek: Int {
    (calendar.dateComponents([.day], from: weekStart(of: Date()), to: weekStart).day ?? 0) / 7
  }

  private var weekEyebrow: String {
    switch weeksFromThisWeek {
    case 0: "今週"
    case -1: "先週"
    case 1: "来週"
    case let n where n > 0: "\(n)週間後"
    case let n: "\(-n)週間前"
    }
  }

  private var weekRangeTitle: String {
    func short(_ date: Date) -> String {
      let c = calendar.dateComponents([.month, .day], from: date)
      return "\(c.month ?? 0)/\(c.day ?? 0)"
    }
    return "\(short(weekDays.first ?? weekStart)) 〜 \(short(weekDays.last ?? weekStart))"
  }

  private func weekdaySymbol(_ date: Date) -> String {
    ["日", "月", "火", "水", "木", "金", "土"][(calendar.component(.weekday, from: date) - 1) % 7]
  }

  /// 日を選ぶ。週が変わるときは、その向きに帯を入れ替える。
  private func select(_ date: Date) {
    let day = calendar.startOfDay(for: min(max(date, selectableRange.lowerBound), selectableRange.upperBound))
    guard day != selectedDate else { return }
    AppHaptics.selection()
    weekForward = day > selectedDate
    withAnimation(AppTheme.Motion.transition(reduce: reduceMotion)) { selectedDate = day }
  }

  /// 日付をタップしたとき：その日を選ぶ。月の表示では、授業と出欠をシートで開く
  /// （週の表示では、カレンダーのすぐ下にその日の授業が出ているので、シートは開かない）
  private func openDay(_ date: Date) {
    guard !HorizontalPanGesture.isRecentlyPanned else { return }
    select(date)
    if calendarMode == .month { showsDayAgenda = true }
  }

  private func moveWeek(_ step: Int) {
    guard let target = calendar.date(byAdding: .day, value: 7 * step, to: selectedDate) else { return }
    select(target)
  }

  /// 週に含まれる月の出欠・出席率を取得してもらう
  private func loadWeekMonths() async {
    for month in monthsInWeek {
      if let last = dates(in: month).last { await onMonthChange(month, last) }
    }
  }

  // MARK: データ

  /// 表示中の月の取得状況。データがあるときは nil。
  private var monthStatus: String? {
    let days = dates(in: currentMonth)
    // 出欠か授業のどちらかがあれば、その月は表示してよい（保存済みの内容を含む）
    if days.contains(where: {
      let key = calendar.startOfDay(for: $0)
      return attendanceByDay[key] != nil || !(lessonsByDay[key] ?? []).isEmpty
    }) {
      return nil
    }
    if isLoadingCurrentMonth {
      return "読み込み中…"
    }
    if timetableLoadFailed {
      return "時間割を取得できませんでした。下に引いて再読み込みしてください。"
    }
    if let first = days.first, let last = days.last, isHoliday(calendar.startOfDay(for: first)) || isHoliday(calendar.startOfDay(for: last)) {
      return "授業のない月です（長期休暇など）"
    }
    return loadedMonths.contains(currentMonth) ? "この月のデータはありません" : "未取得 · 順番に読み込みます"
  }

  private var isLoadingCurrentMonth: Bool {
    loadingMonths.contains(currentMonth) || isLoadingTimetable
  }

  // MARK: 画面

  var body: some View {
    ZStack {
      AppBackgroundView()
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.cardGap) {
          KICneoHeader()
          if let errorMessage {
            ConnectionNotice(text: errorMessage)
          }
          summaryCard
          weekCard
          noticesSection
        }
        .padding(AppTheme.Space.page)
      }
    }
    // 上へスクロールしたとき、時計・電波の後ろに来た内容をぼかす（ナビゲーションバーを隠しているので自前で敷く）
    .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.top } action: { statusBarHeight = $0 }
    .overlay(alignment: .top) {
      Rectangle()
        .fill(.ultraThinMaterial)
        .frame(height: statusBarHeight + 14)
        // 下の端はぼかしを徐々に弱め、境目の線が見えないようにする
        .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.55),
                                     .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    .foregroundStyle(AppTheme.textPrimary)
    .refreshable {
      await onRefresh()
      // 更新で取得済みの記録がリセットされるので、表示中の週の月を取り直す
      await loadWeekMonths()
    }
    // 週が変わったとき（初回表示を含む）に、その週の月の出欠・出席率を取得してもらう
    .task(id: weekStart) { await loadWeekMonths() }
    // 記録が減って範囲が狭くなったとき（保存内容の入れ替えなど）に、範囲の外に居続けないようにする
    .onChange(of: oldestOffset) { _, _ in
      if pageOffset < pageRange.lowerBound { pageOffset = pageRange.lowerBound }
      if selectedDate < selectableRange.lowerBound { selectedDate = calendar.startOfDay(for: selectableRange.lowerBound) }
    }
    // 月のカレンダーを表示中は、表示している月の出欠・出席率も取得してもらう
    .task(id: calendarMode == .month ? pageOffset : Int.min) {
      guard calendarMode == .month, let last = dates(in: currentMonth).last else { return }
      await onMonthChange(currentMonth, last)
    }
    .onChange(of: pageOffset) { _, _ in followVisibleMonth() }
    .sheet(isPresented: $showsDayAgenda) { dayAgendaSheet }

    .navigationTitle("ホーム")
    // 見出しはページ内の KICneoHeader が出すので、ナビゲーションバーは隠す
    .toolbarVisibility(.hidden, for: .navigationBar)
  }

  // MARK: 出席率＋今月の内訳（すべて学校から取得した出欠の記録から数える）

  private struct MonthStats: Equatable {
    var present = 0
    var absent = 0
    var excused = 0
    /// 記録のある日のうち、すべての時限が「出席」だった日
    var perfectDays = 0
    var recordedDays = 0
    var lastRecorded: Date?
  }

  private func monthStats(for month: Date) -> MonthStats {
    var stats = MonthStats()
    // 学校の数え方：遅刻は出席に数えるが、遅刻3回で欠席1回（AttendanceTally）
    var tally = AttendanceTally()
    for date in dates(in: month) {
      let key = calendar.startOfDay(for: date)
      let statuses = attendanceByDay[key]?.periods.map(\.rawStatus).filter { !$0.isEmpty } ?? []
      guard !statuses.isEmpty else { continue }
      stats.recordedDays += 1
      stats.lastRecorded = key
      if statuses.allSatisfy({ $0 == "出席" }) { stats.perfectDays += 1 }
      for status in statuses { tally.add(status) }
    }
    stats.present = tally.present
    stats.absent = tally.absent
    stats.excused = tally.excused
    return stats
  }

  private var summaryCard: some View {
    AttendanceRateCard(rates: rates, month: focusMonth,
      loaded: loadedRatePeriods, loading: loadingRatePeriods, failed: failedRatePeriods,
      selection: $rateScope, onRetry: {
        Task {
          await onRefresh()
          await loadWeekMonths()
        }
      }, isTrendShown: showsTrend, onOpenTrend: {
        AppHaptics.light()
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.45, dampingFraction: 0.86)) {
          showsTrend.toggle()
        }
      }) {
        VStack(alignment: .leading, spacing: AppTheme.Space.cardStack) {
          if showsTrend {
            AttendanceTrendChart(records: records, rates: rates, month: focusMonth, scope: rateScope)
              // 開くときは今の動き（ふわっと広がる）。閉じるときは下の内訳がせり上がる前に素早く消して、重ならないようにする
              .transition(.asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
                removal: .opacity.animation(.easeOut(duration: 0.1))
              ))
          }
          monthBreakdown
        }
      }
  }

  /// 出席率カードの下半分：今月の内訳。ふだんは「11月の内訳 · 61 / 91コマ出席」と割合の帯だけ。
  /// タップすると、出席・欠課等・就職公欠のコマ数のチップを広げる（1画面に収めるため、普段は畳んでおく）。
  private var monthBreakdown: some View {
    let stats = monthStats(for: focusMonth)
    let hasData = stats.recordedDays > 0
    let total = stats.present + stats.absent + stats.excused
    let month = calendar.component(.month, from: focusMonth)
    return VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Button {
        AppHaptics.selection()
        withAnimation(AppTheme.Motion.transition(reduce: reduceMotion)) { showsBreakdown.toggle() }
      } label: {
        VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
          HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.sm) {
            Text("\(month)月の内訳")
              .font(AppTheme.Typography.label)
              .foregroundStyle(AppTheme.textSecondary)
              .contentTransition(.numericText())
            Spacer(minLength: AppTheme.Space.sm)
            Text(hasData ? "\(stats.present) / \(total)コマ出席" : "データなし")
              .font(AppTheme.Typography.bodyEmphasis)
              .monospacedDigit()
              .contentTransition(.numericText(value: Double(stats.present)))
            Image(systemName: "chevron.down")
              .font(AppTheme.Typography.captionEmphasis)
              .foregroundStyle(AppTheme.textTertiary)
              .rotationEffect(.degrees(showsBreakdown ? 180 : 0))
          }
          ratioBar(stats, total: total)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityHint(showsBreakdown ? "タップで内訳を閉じます" : "タップで内訳を表示します")
      if showsBreakdown {
        FlowLayout(spacing: AppTheme.Space.sm) {
          legendChip("出席", value: stats.present, tint: AppTheme.success, showsValue: hasData)
          legendChip("欠課等", value: stats.absent, tint: AppTheme.warning, showsValue: hasData)
          legendChip("就職・公欠", value: stats.excused, tint: AppTheme.primaryAction, showsValue: hasData)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .textTransition(on: [stats.present, stats.absent, stats.excused, month])
  }

  /// 出席・欠課等・就職公欠の割合を1本の太い帯で見せる（区切りは細いすき間）。記録がない月は灰色の帯だけ。
  private func ratioBar(_ stats: MonthStats, total: Int) -> some View {
    GeometryReader { geo in
      let gap: CGFloat = 3
      let parts = [(stats.present, AppTheme.success), (stats.absent, AppTheme.warning), (stats.excused, AppTheme.primaryAction)]
        .filter { $0.0 > 0 }
      let usable = max(0, geo.size.width - gap * CGFloat(max(0, parts.count - 1)))
      let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
      HStack(spacing: gap) {
        if total == 0 {
          shape.fill(AppTheme.elevatedBackground)
        } else {
          ForEach(parts.indices, id: \.self) { index in
            shape.fill(parts[index].1)
              .frame(width: max(6, usable * CGFloat(parts[index].0) / CGFloat(total)))
          }
        }
      }
    }
    .frame(height: 12)
    .accessibilityHidden(true)
  }

  /// 凡例のチップ：色の小さな四角・項目名・コマ数
  private func legendChip(_ label: String, value: Int, tint: Color, showsValue: Bool) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 2.5, style: .continuous)
        .fill(tint)
        .frame(width: 9, height: 9)
      Text(label)
        .font(AppTheme.Typography.body)
        .foregroundStyle(AppTheme.textSecondary)
      if showsValue {
        Text("\(value)")
          .font(AppTheme.Typography.bodyEmphasis)
          .monospacedDigit()
          .contentTransition(.numericText(value: Double(value)))
      }
    }
    .padding(.horizontal, AppTheme.Space.md)
    .padding(.vertical, 7)
    .background(AppTheme.elevatedBackground, in: Capsule())
    .accessibilityElement(children: .combine)
    .accessibilityLabel(showsValue ? "\(label) \(value)コマ" : label)
  }

  // MARK: カレンダー（週 / 月）＋選んだ日

  private var weekCard: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.cardStack) {
      HStack(alignment: .center, spacing: AppTheme.Space.sm) {
        ZStack(alignment: .leading) {
          if calendarMode == .week {
            weekTitle.transition(.blurReplace)
          } else {
            HStack(spacing: AppTheme.Space.sm) {
              monthPickerButton
              // 表示中の月を読み込んでいる間だけ、見出しの横に小さく出す
              if monthStatus != nil, isLoadingCurrentMonth {
                ProgressView().controlSize(.small).transition(.opacity)
              }
            }
            .transition(.blurReplace)
          }
        }
        Spacer(minLength: AppTheme.Space.sm)
        // 「今日」は出たり消えたりで行の高さが変わらないよう、場所を確保したまま見せる/隠すだけにする
        let showsToday = !calendar.isDateInToday(selectedDate) || (calendarMode == .month && pageOffset != 0)
        Button("今日", action: goToToday)
          .font(AppTheme.Typography.bodyEmphasis)
          .buttonStyle(.glass)
          .opacity(showsToday ? 1 : 0)
          .allowsHitTesting(showsToday)
          .accessibilityHidden(!showsToday)
        Picker("カレンダーの表示", selection: calendarModeBinding) {
          Text("週").tag(CalendarMode.week)
          Text("月").tag(CalendarMode.month)
        }
        .pickerStyle(.segmented)
        .fixedSize()
      }
      ZStack(alignment: .top) {
        if calendarMode == .week {
          weekStrip.transition(.blurReplace)
        } else {
          monthBody.transition(.blurReplace)
        }
      }
      if calendarMode == .week {
        Divider()
        inlineAgenda
      } else {
        selectedDayRow
      }
    }
    .padding(AppTheme.Space.card)
    .walletCard()
    .animation(AppTheme.Motion.text(reduce: reduceMotion), value: weekStart)
    .animation(AppTheme.Motion.text(reduce: reduceMotion), value: calendar.isDateInToday(selectedDate))
  }

  private var weekTitle: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(weekEyebrow)
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
        .contentTransition(.numericText(countsDown: !weekForward))
      Text(weekRangeTitle)
        .font(AppTheme.Typography.cardTitle)
        .monospacedDigit()
        .contentTransition(.numericText(countsDown: !weekForward))
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }

  private var weekStrip: some View {
    ZStack {
      HStack(spacing: 6) {
        ForEach(weekDays, id: \.self) { day in weekTile(day) }
      }
      .id(weekStart)
      .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.push(from: weekForward ? .trailing : .leading))
    }
    .offset(x: weekDragX)
    .frame(maxWidth: .infinity)
    .clipped()
    // 横方向が主のドラッグだけを受け取り、週を送る（縦スクロールは妨げない）
    .background(
      HorizontalPanGesture(
        onChanged: { x in weekDragX = x * 0.2 },
        onEnded: { x, velocity in
          let predicted = x + velocity * 0.2
          if x < -40 || predicted < -120 { moveWeek(1) } else if x > 40 || predicted > 120 { moveWeek(-1) }
          withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8)) { weekDragX = 0 }
        })
    )
    .accessibilityElement(children: .contain)
    .accessibilityAction(named: "前の週") { moveWeek(-1) }
    .accessibilityAction(named: "次の週") { moveWeek(1) }
  }

  /// 週の帯の1日：曜日・日付・状態（点 / 休）。授業のある日だけ面を持ち、選択中は反転する。
  private func weekTile(_ date: Date) -> some View {
    let info = dayInfo(date)
    let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
    let isToday = calendar.isDateInToday(date)
    let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
    return Button { openDay(date) } label: {
      VStack(spacing: 6) {
        Text(weekdaySymbol(date))
          .font(AppTheme.Typography.captionEmphasis)
          .foregroundStyle(isSelected ? AppTheme.primaryAction : AppTheme.textSecondary)
        Text("\(calendar.component(.day, from: date))")
          .font(.title3.bold())
          .monospacedDigit()
          .foregroundStyle(isSelected ? AppTheme.primaryAction : (info.hasTile ? AppTheme.textPrimary : AppTheme.textTertiary))
        dayMarker(info, selected: isSelected)
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, AppTheme.Space.sm)
      .background {
        ZStack {
          if info.hasTile { shape.fill(AppTheme.elevatedBackground) }
          if isSelected {
            // 選択中は浅い品牌色の面（黒い反転ではなく）
            shape.fill(AppTheme.cardBackground)
              .overlay { shape.fill(AppTheme.primaryAction.opacity(0.14)) }
              .matchedGeometryEffect(id: "week-selected-day", in: selectionNamespace)
          }
        }
      }
      .overlay {
        if isToday, !isSelected { shape.strokeBorder(AppTheme.primaryAction, lineWidth: 1.5) }
      }
      .contentShape(shape)
    }
    .buttonStyle(CardPressStyle())
    .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))、\(info.label)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  /// 点（出欠・授業予定）か「休」。どちらも無い日は高さだけ確保する。
  private func dayMarker(_ info: DayInfo, selected: Bool) -> some View {
    ZStack {
      if let dot = info.dot {
        Circle().fill(dot).frame(width: 6, height: 6)
      } else if info.marksRest {
        Text("休").font(.caption2.weight(.semibold))
          .foregroundStyle(selected ? AppTheme.primaryAction : AppTheme.holiday.opacity(0.8))
      }
    }
    .frame(height: 13)
  }

  /// カレンダーの下の1行：選んでいる日と、その日のコマ数・出欠のまとめ。タップで授業と出欠のシートを開く。
  private var selectedDayRow: some View {
    let dayRows = rows(for: selectedDate)
    let info = dayInfo(selectedDate)
    let statuses = dayRows.compactMap(\.status)
    let summary: String = {
      if dayRows.isEmpty { return info.isRest ? "授業のない日" : "記録なし" }
      if statuses.isEmpty { return "\(dayRows.count)コマ" }
      let present = statuses.filter { $0 == "出席" }.count
      let excused = statuses.filter { $0 == "就職" || $0 == "公欠" }.count
      let absent = statuses.count - present - excused
      return (["出席 \(present)"] + (absent > 0 ? ["欠課 \(absent)"] : []) + (excused > 0 ? ["就職・公欠 \(excused)"] : []))
        .joined(separator: " · ")
    }()
    return Button { openDay(selectedDate) } label: {
      HStack(spacing: AppTheme.Space.sm) {
        Text(dayTitle(selectedDate))
          .font(AppTheme.Typography.bodyEmphasis)
          .monospacedDigit()
          .contentTransition(.numericText())
        Spacer(minLength: AppTheme.Space.sm)
        Text(summary)
          .font(AppTheme.Typography.body)
          .monospacedDigit()
          .foregroundStyle(AppTheme.textSecondary)
          .lineLimit(1).minimumScaleFactor(0.8)
          .contentTransition(.numericText())
        Image(systemName: "chevron.up")
          .font(AppTheme.Typography.captionEmphasis)
          .foregroundStyle(AppTheme.textTertiary)
      }
      .padding(.horizontal, AppTheme.Space.md)
      .frame(minHeight: 44)
      .background(AppTheme.elevatedBackground, in: .rect(cornerRadius: AppTheme.Radius.small, style: .continuous))
    }
    .buttonStyle(CardPressStyle())
    .animation(AppTheme.Motion.text(reduce: reduceMotion), value: selectedDate)
    .accessibilityHint("タップでこの日の授業と出欠を表示します")
  }

  /// 週の表示のとき、カレンダーのすぐ下に出す、選んだ日の授業と出欠
  private var inlineAgenda: some View {
    let dayRows = rows(for: selectedDate)
    let info = dayInfo(selectedDate)
    return ZStack(alignment: .topLeading) {
      VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
        Text(dayTitle(selectedDate)).font(AppTheme.Typography.headline)
        if dayRows.isEmpty {
          Text(info.isRest ? restText(selectedDate) : "この日の授業・出欠の記録はありません")
            .font(AppTheme.Typography.body)
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.vertical, AppTheme.Space.sm)
        } else {
          VStack(spacing: 0) {
            ForEach(dayRows) { row in
              agendaRow(row)
              if row.id != dayRows.last?.id { Divider().padding(.leading, 56) }
            }
          }
        }
      }
      .id(selectedDate)
      .transition(.blurReplace)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// 選んだ日の授業と出欠のシート（半分の高さで開き、上に引くと全画面）。上の矢印で前後の日へ移れる。
  private var dayAgendaSheet: some View {
    let dayRows = rows(for: selectedDate)
    let info = dayInfo(selectedDate)
    return NavigationStack {
      ScrollView {
        ZStack(alignment: .topLeading) {
          VStack(alignment: .leading, spacing: 0) {
            if dayRows.isEmpty {
              Text(info.isRest ? restText(selectedDate) : "この日の授業・出欠の記録はありません")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.vertical, AppTheme.Space.sm)
            } else {
              ForEach(dayRows) { row in
                agendaRow(row)
                if row.id != dayRows.last?.id { Divider().padding(.leading, 56) }
              }
            }
          }
          .id(selectedDate)
          .transition(.blurReplace)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppTheme.Space.page)
        .padding(.vertical, AppTheme.Space.sm)
      }
      .background(AppTheme.cardBackground)
      .navigationTitle(dayTitle(selectedDate))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          Button("前の日", systemImage: "chevron.left") { moveDay(-1) }
        }
        ToolbarItem(placement: .topBarTrailing) {
          Button("次の日", systemImage: "chevron.right") { moveDay(1) }
        }
      }
      .animation(AppTheme.Motion.transition(reduce: reduceMotion), value: selectedDate)
    }
    .presentationDetents([.medium, .large])
    .presentationDragIndicator(.visible)
  }

  private func restText(_ date: Date) -> String {
    isLongBreak(calendar.startOfDay(for: date)) ? "長期休暇中です（授業はありません）" : "授業のない日です"
  }

  private func moveDay(_ step: Int) {
    guard let target = calendar.date(byAdding: .day, value: step, to: selectedDate) else { return }
    select(target)
  }

  private func agendaRow(_ row: PeriodRow) -> some View {
    HStack(alignment: .center, spacing: AppTheme.Space.md) {
      Text(row.label)
        .font(AppTheme.Typography.bodyEmphasis)
        .monospacedDigit()
        .foregroundStyle(AppTheme.primaryAction)
        .frame(width: 44, alignment: .leading)
      Text(row.lesson ?? "—")
        .font(AppTheme.Typography.body)
        .foregroundStyle(row.lesson == nil ? AppTheme.textSecondary : AppTheme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
      if let status = row.status {
        Text(status)
          .font(AppTheme.Typography.captionEmphasis)
          .foregroundStyle(statusColor(status))
          .padding(.horizontal, AppTheme.Space.sm).padding(.vertical, AppTheme.Space.xs)
          .background(statusColor(status).opacity(0.14), in: .rect(cornerRadius: AppTheme.Radius.chip))
      }
    }
    .padding(.vertical, AppTheme.Space.sm)
    .accessibilityElement(children: .combine)
  }

  // MARK: 年月の選択

  /// 左上の年月。タップすると、年と月をホイールで素早く選べる。
  private var monthPickerButton: some View {
    Button {
      AppHaptics.selection()
      showMonthPicker = true
    } label: {
      HStack(spacing: 6) {
        Text(title(currentMonth))
          .font(AppTheme.Typography.cardTitle)
          .contentTransition(.numericText(value: Double(pageOffset)))
          // 月の入れ替えはアニメーションを切った transaction で行われるので、この文字だけ動きを付け直す
          .transaction(value: pageOffset) { t in
            t.disablesAnimations = false
            t.animation = AppTheme.Motion.text(reduce: reduceMotion)
          }
        Image(systemName: "chevron.down")
          .font(.caption.weight(.bold))
          .foregroundStyle(AppTheme.textTertiary)
      }
      .frame(minHeight: 44, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(.isHeader)
    .accessibilityHint("タップして年月を選びます")
    .popover(isPresented: $showMonthPicker, arrowEdge: .top) {
      monthPickerContent
        .presentationCompactAdaptation(.popover)
    }
  }

  private var monthPickerContent: some View {
    VStack(spacing: AppTheme.Space.sm) {
      HStack(spacing: 0) {
        Picker("年", selection: pickedYear) {
          ForEach(pickerYears, id: \.self) { Text(String($0) + "年").tag($0) }
        }
        .pickerStyle(.wheel)
        .frame(width: 110)
        Picker("月", selection: pickedMonth) {
          ForEach(1...12, id: \.self) { Text("\($0)月").tag($0) }
        }
        .pickerStyle(.wheel)
        .frame(width: 90)
      }
      .frame(height: 150)
      Button {
        jumpToMonth(offset: 0)
        selectedDate = calendar.startOfDay(for: Date())
        showMonthPicker = false
      } label: {
        Text("今月へ")
          .font(AppTheme.Typography.bodyEmphasis)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
          .background(AppTheme.formatTagBackground)
          .clipShape(Capsule())
      }
      .buttonStyle(.plain)
    }
    .padding(AppTheme.Space.md)
    .frame(width: 230)
  }

  /// 選べる年（スワイプで動ける月の範囲に合わせる）
  private var pickerYears: [Int] {
    let first = calendar.component(.year, from: monthStart(offset: pageRange.lowerBound))
    let last = calendar.component(.year, from: monthStart(offset: pageRange.upperBound))
    return Array(first...last)
  }

  private var pickedYear: Binding<Int> {
    Binding(
      get: { calendar.component(.year, from: currentMonth) },
      set: { jump(year: $0, month: calendar.component(.month, from: currentMonth)) })
  }

  private var pickedMonth: Binding<Int> {
    Binding(
      get: { calendar.component(.month, from: currentMonth) },
      set: { jump(year: calendar.component(.year, from: currentMonth), month: $0) })
  }

  /// 年月を指定して移動する。動ける範囲を超えるときは、いちばん近い月にする。
  private func jump(year: Int, month: Int) {
    let now = calendar.dateComponents([.year, .month], from: Date())
    jumpToMonth(offset: (year - (now.year ?? year)) * 12 + (month - (now.month ?? month)))
  }

  private func jumpToMonth(offset: Int) {
    let clamped = min(max(offset, pageRange.lowerBound), pageRange.upperBound)
    guard clamped != pageOffset else { return }
    AppHaptics.selection()
    dragX = 0
    pageOffset = clamped
  }

  /// 月のカレンダー本体：取得状況の行・月のページ・凡例。
  private var monthBody: some View {
    monthPager
  }

  /// 前月・当月・次月の3枚を横に並べ、指の動きに合わせて動かす。
  /// 右へスワイプ（指が右へ動く）→ 前の月が左から入ってくる、左へスワイプ → 次の月が右から入ってくる。
  private var monthPager: some View {
    GeometryReader { geo in
      let width = geo.size.width
      HStack(spacing: pageGap) {
        ForEach([-1, 0, 1], id: \.self) { step in
          Group {
            if pageRange.contains(pageOffset + step) {
              monthGrid(monthStart(offset: pageOffset + step))
            } else {
              Color.clear
            }
          }
          .frame(width: width)
        }
      }
      .offset(x: -(width + pageGap) + dragX)
    }
    // 横方向の動きだけを受け取る（縦方向が主の動きのときは始まらないので、ページの縦スクロールを妨げない）
    .background(
      HorizontalPanGesture(
        onChanged: { x in
          isDragging = true
          let atEdge = (x > 0 && !pageRange.contains(pageOffset - 1)) || (x < 0 && !pageRange.contains(pageOffset + 1))
          dragX = atEdge ? x * 0.25 : x
        },
        onEnded: { x, velocity in
          guard isDragging else { return }
          isDragging = false
          let width = pagerWidth
          let predicted = x + velocity * 0.2
          if x < -width * 0.25 || predicted < -width * 0.5, pageRange.contains(pageOffset + 1) {
            settle(to: -(width + pageGap), change: 1)
          } else if x > width * 0.25 || predicted > width * 0.5, pageRange.contains(pageOffset - 1) {
            settle(to: width + pageGap, change: -1)
          } else {
            withAnimation(.easeOut(duration: 0.2)) { dragX = 0 }
          }
        })
    )
    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pagerWidth = $0 }
    // ページャーは高さ固定（6週分）なので、極端に大きな文字ではセルからはみ出さないよう上限を設ける
    .dynamicTypeSize(...DynamicTypeSize.xLarge)
    .frame(height: pagerHeight)
    .animation(AppTheme.Motion.transition(reduce: reduceMotion), value: pagerHeight)
    .clipped()
  }

  /// 今月・今日に戻る。
  private func goToToday() {
    select(Date())
    pageOffset = 0
    dragX = 0
  }

  /// 隣の月まで動かしきってから、中央に戻して月を入れ替える（見た目は連続したまま）。
  private func settle(to target: CGFloat, change: Int) {
    AppHaptics.selection()
    withAnimation(.easeOut(duration: 0.22)) {
      dragX = target
    } completion: {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        pageOffset += change
        dragX = 0
      }
    }
  }

  /// 月のカレンダー。曜日の行＋その月に必要な週の数（4〜6）の行を、ふつうの（遅延しない）縦横の並びで作る。
  /// LazyVGrid は、測った高さが見積もりになり、月によって最後の週が切れたり下が空いたりしたため使わない（最大 42 マス）。
  private func monthGrid(_ monthStart: Date) -> some View {
    let days = dates(in: monthStart)
    let leading = calendar.component(.weekday, from: monthStart) - 1
    let rows = weekRows(monthStart)
    // 各マス：その月の日（タップできる）か、前月・翌月の日（薄い数字だけ）か
    let cells: [(date: Date, inMonth: Bool)] = (0..<(rows * 7)).map { index in
      let offset = index - leading
      if offset >= 0, offset < days.count { return (days[offset], true) }
      return (calendar.date(byAdding: .day, value: offset, to: monthStart) ?? monthStart, false)
    }
    return VStack(spacing: 6) {
      HStack(spacing: 6) {
        ForEach(Array(["日", "月", "火", "水", "木", "金", "土"].enumerated()), id: \.offset) { _, label in
          Text(label)
            .font(AppTheme.Typography.captionEmphasis)
            .foregroundStyle(AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
        }
      }
      ForEach(0..<rows, id: \.self) { row in
        HStack(spacing: 6) {
          ForEach(0..<7, id: \.self) { column in
            let cell = cells[row * 7 + column]
            if cell.inMonth {
              dayCell(cell.date)
            } else {
              fillerCell(cell.date)
            }
          }
        }
      }
    }
    // 中身どおりの高さを測って、ページャーの高さに使う
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: { height in
      if monthGridHeights[monthStart] != height { monthGridHeights[monthStart] = height }
    }
    .frame(maxHeight: .infinity, alignment: .top)
  }

  /// 月の外の日付を表す薄いセル（面なし・数字だけ）。
  /// 日付セルと同じ組み立て（数字＋印の場所）・同じ高さにする。高さが違うと、その行だけ高くなり、
  /// 行数から計算したカレンダーの高さに収まらず、最後の行が切れてしまう。
  private func fillerCell(_ date: Date?) -> some View {
    VStack(spacing: 5) {
      Text(date.map { "\(calendar.component(.day, from: $0))" } ?? "")
        .font(AppTheme.Typography.body)
        .monospacedDigit()
        .foregroundStyle(Color(uiColor: .quaternaryLabel))
      Color.clear.frame(height: 13)
    }
    .frame(maxWidth: .infinity, minHeight: 44)
    .accessibilityHidden(true)
  }

  // MARK: 日付セル

  /// 日付セルの見た目。今日以降は時間割（授業の数）、過去は出欠（出席・欠課など）で表す。
  /// 過去の授業日でまだ出欠の記録がない日は「未記録」の空セル、授業のない日はさらに薄く表示する。
  /// 授業のない日は、すべて「休み」（土日も含む）。ただし、その月の時間割が取得できている場合だけ。
  /// 時間割がまだ無い月は、授業がないのか未取得なのか分からないので休みとは見なさない。
  /// `day` の前後で、いちばん近い授業のある日（前・後）
  private func surroundingLessons(_ day: Date) -> (previous: Date?, next: Date?) {
    // 日付順に並んでいるので、二分探索で位置を探す
    var low = 0
    var high = lessonDates.count
    while low < high {
      let mid = (low + high) / 2
      if lessonDates[mid] < day { low = mid + 1 } else { high = mid }
    }
    let previous = low > 0 ? lessonDates[low - 1] : nil
    let next = low < lessonDates.count ? lessonDates[low] : nil
    return (previous, next)
  }

  /// 長期休暇（前後の授業の間が10日以上あいている、授業のない日）
  private func isLongBreak(_ day: Date) -> Bool {
    let around = surroundingLessons(day)
    guard let previous = around.previous, let next = around.next, next != day else { return false }
    return (calendar.dateComponents([.day], from: previous, to: next).day ?? 0) >= 10
  }

  private func isHoliday(_ day: Date) -> Bool {
    // 最初の授業〜最後の授業の間なら、1か月まるごと授業のない月（夏休みなど）でも休み
    if let first = lessonDates.first, let last = lessonDates.last, day >= first, day <= last { return true }
    guard let month = calendar.date(from: calendar.dateComponents([.year, .month], from: day)) else { return false }
    return monthsWithTimetable.contains(month)
  }

  /// 1日の見た目の材料。週の帯と月のカレンダーで同じ判断を使う。
  /// 点の色：出席＝緑、欠課などを含む＝黄、就職・公欠のみ＝青、今日以降の授業日＝薄い灰、過去の未記録＝さらに薄い灰。
  private struct DayInfo {
    let dot: Color?
    /// 授業（または出欠の記録）がある日だけ角丸の面を持つ
    let hasTile: Bool
    let isRest: Bool
    let label: String
    /// 「休」の字を出すか。学期中の平日の休み（祝日など）だけ。土日と長期休暇は、数が多くうるさくなるので出さない
    var marksRest = false
  }

  private func dayInfo(_ date: Date) -> DayInfo {
    let key = calendar.startOfDay(for: date)
    let isPast = key < calendar.startOfDay(for: Date())
    let statuses = attendanceByDay[key]?.periods.map(\.rawStatus).filter { !$0.isEmpty } ?? []
    let dayLessons = lessonsByDay[key] ?? []
    if isPast, !statuses.isEmpty {
      let allPresent = statuses.allSatisfy { $0 == "出席" }
      let allExcused = statuses.allSatisfy { $0 == "就職" || $0 == "公欠" }
      return DayInfo(dot: allPresent ? AppTheme.success : (allExcused ? AppTheme.primaryAction : AppTheme.warning),
        hasTile: true, isRest: false, label: statuses.joined(separator: "、"))
    }
    if !dayLessons.isEmpty {
      let lessonCount = dayLessons.filter { periodNumber($0) != nil }.count
      return DayInfo(dot: isPast ? Color(uiColor: .quaternaryLabel) : AppTheme.textTertiary,
        hasTile: true, isRest: false, label: isPast ? "未記録" : (lessonCount > 0 ? "\(lessonCount)コマ" : "予定あり"))
    }
    if isHoliday(key) {
      let longBreak = isLongBreak(key)
      let weekday = calendar.component(.weekday, from: key)
      return DayInfo(dot: nil, hasTile: false, isRest: true, label: longBreak ? "長期休暇" : "休み",
        marksRest: !longBreak && weekday != 1 && weekday != 7)
    }
    return DayInfo(dot: nil, hasTile: false, isRest: false, label: "未取得")
  }

  /// 月のカレンダーの日付セル。選ぶと下の授業一覧がその日になる（週に戻しても、その日の週が出る）。
  private func dayCell(_ date: Date) -> some View {
    let key = calendar.startOfDay(for: date)
    let info = dayInfo(date)
    let isSelected = calendar.isDate(date, inSameDayAs: selectedDate)
    let isToday = calendar.isDateInToday(date)
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    return Button {
      openDay(key)
    } label: {
      VStack(spacing: 5) {
        Text("\(calendar.component(.day, from: date))")
          .font(.subheadline.weight(info.hasTile ? .bold : .semibold))
          .monospacedDigit()
          .foregroundStyle(isSelected ? AppTheme.primaryAction : (info.hasTile ? AppTheme.textPrimary : AppTheme.textTertiary))
        dayMarker(info, selected: isSelected)
      }
      .frame(maxWidth: .infinity, minHeight: 44)
      .background {
        ZStack {
          if info.hasTile { shape.fill(AppTheme.elevatedBackground) }
          if isSelected {
            shape.fill(AppTheme.cardBackground)
              .overlay { shape.fill(AppTheme.primaryAction.opacity(0.14)) }
              .matchedGeometryEffect(id: "month-selected-day", in: selectionNamespace)
          }
        }
      }
      .overlay {
        if isToday, !isSelected { shape.strokeBorder(AppTheme.primaryAction, lineWidth: 1.5) }
      }
      .contentShape(shape)
    }
    .buttonStyle(CardPressStyle())
    .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))、\(info.label)")
    .accessibilityAddTraits(isSelected ? .isSelected : [])
  }

  // MARK: 選んだ日

  private struct PeriodRow: Identifiable {
    let id: Int
    /// "1限" など。時限の形式でない項目（休講・予定のメモなど）は "予定"
    let label: String
    let lesson: String?
    let status: String?
  }

  /// 時限の番号（"1限" → 1）。番号の付かない項目は nil。
  private func periodNumber(_ lesson: TimetableLesson) -> Int? {
    Int(lesson.period.filter(\.isNumber))
  }

  /// 授業（時間割）と出欠を時限ごとにまとめる。どちらか一方しかない時限もそのまま出す。
  /// 学校のカレンダーに時限の形式でない項目（休講・予定のメモなど）があれば、末尾にそのまま出す。
  private func rows(for date: Date) -> [PeriodRow] {
    let key = calendar.startOfDay(for: date)
    let dayLessons = lessonsByDay[key] ?? []
    var lessons: [Int: String] = [:]
    for lesson in dayLessons {
      if let number = periodNumber(lesson) {
        lessons[number] = lesson.name
      }
    }
    var statuses: [Int: String] = [:]
    for period in attendanceByDay[key]?.periods ?? [] where !period.rawStatus.isEmpty {
      statuses[period.number] = period.rawStatus
    }
    let numbers = Set(lessons.keys).union(statuses.keys).sorted()
    var result = numbers.map { PeriodRow(id: $0, label: "\($0)限", lesson: lessons[$0], status: statuses[$0]) }
    let notes = dayLessons.filter { periodNumber($0) == nil }
    for (index, note) in notes.enumerated() {
      let text = [note.period, note.name].filter { !$0.isEmpty }.joined(separator: " ")
      result.append(PeriodRow(id: 1000 + index, label: "予定", lesson: text, status: nil))
    }
    return result
  }


  private func statusColor(_ status: String) -> Color {
    switch status {
    case "出席": return AppTheme.success
    case "就職", "公欠": return AppTheme.primaryAction
    default: return AppTheme.warning
    }
  }

}

/// 月 / 年度 / 総合 の出席率。カードは動かさず、左右スワイプ・上のタブ・下の点のどれで切り替えても、
/// 見出し・数字・期間の文字が同じ場所で `.numericText()` により入れ替わる。
private struct AttendanceRateCard<Footer: View>: View {
  let rates: AttendanceRates
  let month: Date
  var loaded: Set<AttendanceRatePeriod> = []
  var loading: Set<AttendanceRatePeriod> = []
  var failed: Set<AttendanceRatePeriod> = []
  @Binding var selection: AttendanceRateScope
  /// 裏面（時間割）を表示している間はスワイプを受け付けない
  var swipeEnabled = true
  var onRetry: () -> Void
  /// 推移のグラフをカードの中に広げているか（ボタンの見た目を変える）
  var isTrendShown = false
  /// 数字（またはグラフのボタン）をタップしたとき：推移のグラフを広げる / 畳む
  var onOpenTrend: () -> Void = {}
  /// カードの下に続ける内容（ホームでは今月の内訳）
  let footer: Footer
  @ScaledMetric(relativeTo: .body) private var pageHeight = 64
  @ScaledMetric(relativeTo: .largeTitle) private var numberSize = 40
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 前の期間へ戻るときは数字・文字を逆向きに流す
  @State private var goingBack = false
  /// 指に少しだけ付いてくる量（離すと戻る）。切り替えたことを手で感じられるように。
  @State private var dragX: CGFloat = 0

  private var scopes: [AttendanceRateScope] { AttendanceRateScope.allCases }

  init(rates: AttendanceRates, month: Date,
       loaded: Set<AttendanceRatePeriod> = [], loading: Set<AttendanceRatePeriod> = [], failed: Set<AttendanceRatePeriod> = [],
       selection: Binding<AttendanceRateScope>, swipeEnabled: Bool = true,
       onRetry: @escaping () -> Void, isTrendShown: Bool = false, onOpenTrend: @escaping () -> Void = {}, @ViewBuilder footer: () -> Footer) {
    self.rates = rates
    self.month = month
    self.loaded = loaded
    self.loading = loading
    self.failed = failed
    _selection = selection
    self.swipeEnabled = swipeEnabled
    self.onRetry = onRetry
    self.isTrendShown = isTrendShown
    self.onOpenTrend = onOpenTrend
    self.footer = footer()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      // 期間（月間・年間・総合）はメニューで選ぶ。左右スワイプでも切り替わる
      HStack(alignment: .center) {
        Menu {
          Picker("表示する期間", selection: scopeBinding) {
            ForEach(scopes) { scope in Text(scope.heading).tag(scope) }
          }
        } label: {
          HStack(spacing: 4) {
            Text(selection.heading)
              .contentTransition(.numericText(countsDown: goingBack))
            Image(systemName: "chevron.up.chevron.down")
              .font(.caption2.weight(.semibold))
          }
          .font(AppTheme.Typography.label)
          .foregroundStyle(AppTheme.textSecondary)
          .frame(minHeight: 32)
          .contentShape(Rectangle())
        }
        .accessibilityLabel("表示する期間")
        .accessibilityValue(selection.heading)
        .accessibilityIdentifier("attendance-scope-menu")
        Spacer(minLength: 12)
        Text(periodTitle(selection))
          .font(AppTheme.Typography.label)
          .monospacedDigit()
          .foregroundStyle(AppTheme.textSecondary)
          .contentTransition(.numericText(countsDown: goingBack))
        Button(isTrendShown ? "推移を閉じる" : "出席率の推移", systemImage: isTrendShown ? "chevron.up" : "chart.xyaxis.line", action: onOpenTrend)
          .labelStyle(.iconOnly)
          .contentTransition(.symbolEffect(.replace))
          .font(AppTheme.Typography.bodyEmphasis)
          .foregroundStyle(AppTheme.primaryAction)
          .frame(minWidth: 32, minHeight: 32)
          .contentShape(Rectangle())
      }
      ratePage(selection)
        // 中身に合わせた高さ（期間を切り替えても跳ねないよう、最低限の高さだけ確保）
        .frame(minHeight: pageHeight, alignment: .top)
        .offset(x: dragX)
        .contentShape(Rectangle())
        // 数字をタップすると推移のグラフをカードの中に広げる（左右のスワイプは期間の切り替えのまま）
        .onTapGesture {
          guard !HorizontalPanGesture.isRecentlyPanned, dragX == 0 else { return }
          onOpenTrend()
        }
        .accessibilityAction(named: "出席率の推移を表示", onOpenTrend)
        // 横方向が主のドラッグだけを受け取る（縦スクロールは妨げない）
        .background(
          HorizontalPanGesture(
            onChanged: { x in
              guard swipeEnabled else { return }
              let atEdge = (x > 0 && previous == nil) || (x < 0 && next == nil)
              dragX = x * (atEdge ? 0.08 : 0.18)
            },
            onEnded: { x, velocity in
              guard swipeEnabled else { return }
              let predicted = x + velocity * 0.2
              let target: AttendanceRateScope? =
                (x < -40 || predicted < -120) ? next : ((x > 40 || predicted > 120) ? previous : nil)
              if let target { select(target) }
              withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8)) { dragX = 0 }
            })
        )
      footer
    }
    .padding(AppTheme.Space.card)
    .walletCard()
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("attendance-rate-card")
    .onChange(of: selection) { _, _ in AppHaptics.selection() }
  }

  private var scopeBinding: Binding<AttendanceRateScope> {
    Binding(get: { selection }, set: { select($0) })
  }

  private var next: AttendanceRateScope? {
    scopes.firstIndex(of: selection).flatMap { $0 + 1 < scopes.count ? scopes[$0 + 1] : nil }
  }

  private var previous: AttendanceRateScope? {
    scopes.firstIndex(of: selection).flatMap { $0 > 0 ? scopes[$0 - 1] : nil }
  }

  /// 向きを先に決めてから、アニメーション付きで切り替える（向きは描画時に読まれるため、順番が大事）
  private func select(_ scope: AttendanceRateScope) {
    guard scope != selection else { return }
    goingBack = scope.rawValue < selection.rawValue
    withAnimation(AppTheme.Motion.text(reduce: reduceMotion)) { selection = scope }
  }

  private func ratePage(_ scope: AttendanceRateScope) -> some View {
    let period = AttendanceRatePeriod.make(scope, month: month, overallStart: rates.overallFrom)
    let value = period == nil ? nil : rates.value(scope, month: month)
    let textMotion = AppTheme.Motion.text(reduce: reduceMotion)
    return VStack(alignment: .leading, spacing: AppTheme.Space.xs) {
      HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text(value.map { String(format: "%.2f", $0) } ?? "—")
          .font(.system(size: numberSize, weight: .bold))
          .monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)
          // 値そのものを渡すと、増えたときは上へ・減ったときは下へ数字が流れる
          .contentTransition(.numericText(value: value ?? 0))
          .accessibilityIdentifier("attendance-value-\(scope.rawValue)")
        if value != nil {
          Text("%").font(.title3).foregroundStyle(AppTheme.textSecondary)
            .transition(.blurReplace)
        }
        if let period, loading.contains(period) {
          ProgressView().controlSize(.small).padding(.leading, 8).transition(.opacity)
        }
      }
      .animation(textMotion, value: value)
      .animation(textMotion, value: period.map { loading.contains($0) } ?? false)
      Text(rangeText(scope, period: period, value: value) ?? " ")
        .font(AppTheme.Typography.caption).monospacedDigit().foregroundStyle(AppTheme.textSecondary)
        .contentTransition(.numericText(countsDown: goingBack))
        .fixedSize(horizontal: false, vertical: true)
      status(scope, period: period, value: value)
    }
    .animation(textMotion, value: month)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("attendance-page-\(scope.rawValue)")
  }

  private func rangeText(_ scope: AttendanceRateScope, period: AttendanceRatePeriod?, value: Double?) -> String? {
    if let period, let through = rates.through(scope, month: month) {
      return "\(dateText(period.from))〜\(dateText(through))"
    }
    return value == nil ? nil : "保存済みの値"
  }

  private func status(_ scope: AttendanceRateScope, period: AttendanceRatePeriod?, value: Double?) -> some View {
    let didFail = period.map { failed.contains($0) } ?? false
    let message: String? = {
      guard let period else { return scope == .total ? "記録の開始日を確認中" : "集計前" }
      if didFail { return value == nil ? "取得できませんでした" : "更新できませんでした・前回の値" }
      guard value == nil else { return nil }
      return loading.contains(period) ? "読み込み中…" : (loaded.contains(period) ? "授業データなし" : "取得待ち")
    }()
    return HStack(spacing: 8) {
      AttendanceAnimatedText(text: message).foregroundStyle(AppTheme.textSecondary)
      if didFail {
        Button("再読み込み", action: onRetry).frame(minHeight: 28)
          .transition(.blurReplace)
      }
    }
    .font(AppTheme.Typography.caption)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: didFail)
  }
  private func periodTitle(_ scope: AttendanceRateScope) -> String {
    let c = AttendanceRatePeriod.calendar
    switch scope {
    case .month: return "\(c.component(.year, from: month))年\(c.component(.month, from: month))月"
    case .year: return "\(c.component(.year, from: AttendanceRatePeriod.yearStart(month)))年度"
    case .total: return "全期間"
    }
  }
  private func dateText(_ date: Date) -> String {
    let c = AttendanceRatePeriod.calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!)
  }
}

extension AttendanceRateCard where Footer == EmptyView {
  init(rates: AttendanceRates, month: Date,
       loaded: Set<AttendanceRatePeriod> = [], loading: Set<AttendanceRatePeriod> = [], failed: Set<AttendanceRatePeriod> = [],
       selection: Binding<AttendanceRateScope>, onRetry: @escaping () -> Void) {
    self.init(rates: rates, month: month, loaded: loaded, loading: loading, failed: failed,
      selection: selection, onRetry: onRetry) { EmptyView() }
  }
}

/// 文字の ID を変えるときも外側の View は変えない（標準の Blur Replace のアニメーションを効かせるため）。
private struct AttendanceAnimatedText: View {
  let text: String?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack(alignment: .leading) {
      if let text {
        Text(text).id(text).transition(.blurReplace)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.24), value: text)
    .transaction { if reduceMotion { $0.animation = nil } }
  }
}

private struct AttendanceRatePageControl: UIViewRepresentable {
  let page: Int
  var onChange: (Int) -> Void
  func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
  func makeUIView(context: Context) -> UIPageControl {
    let control = UIPageControl()
    control.numberOfPages = 3
    control.backgroundStyle = .minimal
    control.currentPageIndicatorTintColor = .label
    control.pageIndicatorTintColor = .tertiaryLabel
    control.accessibilityLabel = "出席率の表示期間"
    control.accessibilityIdentifier = "attendance-pages"
    control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
    return control
  }
  func updateUIView(_ control: UIPageControl, context: Context) {
    context.coordinator.onChange = onChange
    control.currentPage = page
  }
  final class Coordinator: NSObject {
    var onChange: (Int) -> Void
    init(onChange: @escaping (Int) -> Void) { self.onChange = onChange }
    @objc func changed(_ control: UIPageControl) { onChange(control.currentPage) }
  }
}

private struct AttendanceRatePreview: View {
  @State private var scope: AttendanceRateScope = .month
  var empty = false
  var body: some View {
    let month = AttendanceRatePeriod.monthStart(.now)
    let start = DemoData.enrollment
    let periods = AttendanceRatePeriod.batch(months: [month], overallStart: start, includeOverall: true)
    let rates = DemoData.previewRates(periods) { empty ? nil : DemoData.previewRateValues[$0] }
    AttendanceRateCard(rates: rates, month: month, loaded: Set(periods), selection: $scope,
      onRetry: {})
      .padding(AppTheme.Space.page)
      .background(Color(uiColor: .systemGroupedBackground))
  }
}

#Preview("出席率・月／年／総合") { AttendanceRatePreview() }
#Preview("出席率・ダーク") { AttendanceRatePreview().preferredColorScheme(.dark) }
#Preview("出席率・大きな文字") { AttendanceRatePreview().environment(\.dynamicTypeSize, .accessibility3) }
#Preview("出席率・データなし") { AttendanceRatePreview(empty: true) }

private struct AttendanceRateMotionPreview: View {
  @State private var scope: AttendanceRateScope = .month
  @State private var month = AttendanceRatePeriod.monthStart(.now)
  @State private var phase = 0

  var body: some View {
    let start = DemoData.enrollment
    let periods = AttendanceRatePeriod.batch(months: [month], overallStart: start, includeOverall: true)
    let active = Set(periods)
    VStack(spacing: 20) {
      AttendanceRateCard(rates: sample(periods), month: month,
        loaded: phase == 1 ? [] : active, loading: phase == 1 ? active : [],
        failed: phase == 2 ? active : [], selection: $scope,
        onRetry: { phase = 0 })
      HStack {
        Button("前月") { month = AttendanceRatePeriod.calendar.date(byAdding: .month, value: -1, to: month)! }
        Button("更新") { phase = (phase + 1) % 4 }
      }.buttonStyle(.bordered)
    }
    .padding(AppTheme.Space.page)
    .background(Color(uiColor: .systemGroupedBackground))
  }

  private func sample(_ periods: [AttendanceRatePeriod]) -> AttendanceRates {
    DemoData.previewRates(periods) { scope in
      phase == 1 || phase == 3 ? nil : (phase == 2 ? DemoData.previewRateAlternative : DemoData.previewRateValues[scope])
    }
  }
}

#Preview("出席率・文字の切替") { AttendanceRateMotionPreview() }

/// 横方向のドラッグだけを受け取るジェスチャー。
/// SwiftUI の `DragGesture` だと縦の動きもスクロールを妨げることがあるので、UIKit のパンを使い、
/// 縦方向が主の動きでは始まらないようにしている（始まらなければ、ScrollView が普通にスクロールする）。
/// 反応するのは、この背景が置かれた範囲の中で始まったドラッグだけ。
private struct HorizontalPanGesture: UIViewRepresentable {
  /// 最後に横のスワイプが動いた時刻
  @MainActor static var lastPanAt: Date = .distantPast
  /// スワイプ中か、終わった直後か。タップ側で確かめて、スワイプの終わりに指を離した場所が押されないようにする
  @MainActor static var isRecentlyPanned: Bool { Date().timeIntervalSince(lastPanAt) < 0.35 }

  var onChanged: (CGFloat) -> Void
  var onEnded: (_ translation: CGFloat, _ velocity: CGFloat) -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeUIView(context: Context) -> HostView {
    let view = HostView()
    view.isUserInteractionEnabled = false
    view.coordinator = context.coordinator
    return view
  }

  func updateUIView(_ view: HostView, context: Context) {
    context.coordinator.parent = self
  }

  /// 画面に載ったとき、ウィンドウにパンを付ける（ウィンドウ全体の位置で受け、範囲の判定は Coordinator で行う）。
  final class HostView: UIView {
    weak var coordinator: Coordinator?
    private var recognizer: UIPanGestureRecognizer?
    private weak var attachedWindow: UIWindow?

    override func didMoveToWindow() {
      super.didMoveToWindow()
      if let recognizer, let attachedWindow {
        attachedWindow.removeGestureRecognizer(recognizer)
        self.recognizer = nil
      }
      guard let window, let coordinator else { return }
      let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.panned(_:)))
      pan.delegate = coordinator
      // 横のスワイプだと分かった時点で、同じ指のタップ（日付・カードのボタン）を取り消す。
      // 以前は false で、スワイプして指を離した場所の日付が押され、シートが開くなどの誤タップになっていた
      pan.cancelsTouchesInView = true
      pan.delaysTouchesBegan = false
      coordinator.host = self
      window.addGestureRecognizer(pan)
      recognizer = pan
      attachedWindow = window
    }
  }

  final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var parent: HorizontalPanGesture
    weak var host: HostView?

    init(_ parent: HorizontalPanGesture) { self.parent = parent }

    @objc func panned(_ pan: UIPanGestureRecognizer) {
      let x = pan.translation(in: pan.view).x
      HorizontalPanGesture.lastPanAt = Date()
      switch pan.state {
      case .changed:
        parent.onChanged(x)
      case .ended, .cancelled, .failed:
        parent.onEnded(x, pan.velocity(in: pan.view).x)
      default:
        break
      }
    }

    /// この範囲の中で始まった、横方向が主のドラッグだけを受ける
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let host else { return false }
      let velocity = pan.velocity(in: pan.view)
      guard abs(velocity.x) > abs(velocity.y) else { return false }
      return host.bounds.contains(pan.location(in: host))
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
  }
}
