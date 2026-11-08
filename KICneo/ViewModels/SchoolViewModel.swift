import Combine
import Foundation

@MainActor
final class SchoolViewModel: ObservableObject {
  @Published var days: [AttendanceDay] = []
  @Published var isLoggedIn = false
  /// デモモード（DemoData の架空データを表示中）。学校には接続しない。
  @Published private(set) var isDemo = false
  @Published var accountID: String?
  @Published private(set) var credentialsRejected = false
  @Published var isLoading = false
  @Published private(set) var student: StudentCardData?
  @Published private(set) var isLoadingStudent = false
  @Published private(set) var studentLoadFailed = false
  @Published private(set) var huntActivities: [HuntActivity] = []
  @Published private(set) var isLoadingHunt = false
  @Published private(set) var huntLoadFailed = false
  private var huntLoaded = false

  /// 学校の「イベント申込」一覧。説明会に「参加中」タグを付ける根拠になる。
  @Published private(set) var schoolEvents: [SchoolEvent] = []
  @Published private(set) var isLoadingSchoolEvents = false
  /// 申込の処理中の説明会（タイトル）。同じ説明会を二重に申し込まないために使う
  @Published private(set) var applyingEventTitles: Set<String> = []
  /// 成績（学校ポータル「成績」ページの全科目）
  @Published private(set) var grades: [GradeRecord] = []
  /// 学校からのお知らせ（新しい順）。学校側で既読になって消えた分も、しばらく端末に残す
  @Published private(set) var notices: [SchoolNotice] = []
  @Published private(set) var isLoadingNotices = false
  @Published private(set) var noticesLoadFailed = false
  /// このアプリで開いたお知らせ（未読の印を消すため）
  @Published private(set) var readNoticeKeys: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "read_notice_keys") ?? [])
  private var noticeDetails: [String: SchoolNoticeDetail] = [:]
  @Published private(set) var isLoadingGrades = false
  @Published private(set) var gradesLoadFailed = false
  private var gradesLoaded = false
  @Published private(set) var schoolEventsLoadFailed = false

  /// 月・学年（4月〜翌3月）・総合を学校の集計ページから別々に取得する。
  @Published private(set) var attendanceRates = AttendanceRates()
  @Published private(set) var loadedRatePeriods: Set<AttendanceRatePeriod> = []
  /// 出欠・出席率を最後に学校から取得した時刻
  @Published private(set) var attendanceUpdatedAt: Date?
  @Published private(set) var loadingRatePeriods: Set<AttendanceRatePeriod> = []
  @Published private(set) var failedRatePeriods: Set<AttendanceRatePeriod> = []
  private var rateGeneration = UUID()

  @Published private(set) var timetable: [TimetableDay] = []
  private var eventDetails: [String: SchoolEventDetail] = [:]
  /// 詳細を学校から取得した時刻（この起動の間だけ覚える）
  private var detailFetchedAt: [String: Date] = [:]
  @Published private(set) var isLoadingTimetable = false
  @Published private(set) var timetableLoadFailed = false
  private var timetableLoaded = false

  // 就職活動の追加フォーム
  @Published var huntForm = HuntFormState()
  @Published var huntValues = HuntEntryValues()
  @Published private(set) var isHuntFormBusy = false
  @Published var huntFormError: String?
  @Published var errorMessage: String?

  private let client = SchoolClient()
  private var attendanceSaveTask: Task<Void, Never>?
  private var studentLoaded = false

  /// 保存済みのアカウントがあれば、前回の内容（出欠・出席率・時間割など）を端末から読み込んで先に表示する。
  /// デコードは主スレッドの外で並行して行い、画面の最初の描画を待たせない。
  /// 学校から取得できたら、内容が違うときだけ置き換える。
  func loadCachedData() async {
    AccountCache.removeLegacy()
    guard KeychainService.hasSavedAccount, let id = AccountCache.lastAccountID else { return }
    async let attendance: [AttendanceDay] = Task.detached { AccountCache.load(AccountCache.attendance, accountID: id) }.value
    async let timetable: [TimetableDay] = Task.detached { AccountCache.load(AccountCache.timetable, accountID: id) }.value
    async let hunt: [HuntActivity] = Task.detached { AccountCache.load(AccountCache.huntActivities, accountID: id) }.value
    async let events: [SchoolEvent] = Task.detached { AccountCache.load(AccountCache.schoolEvents, accountID: id) }.value
    async let rates: [AttendanceRates] = Task.detached { AccountCache.load(AccountCache.attendanceRates, accountID: id) }.value
    async let students: [StudentCardData] = Task.detached { AccountCache.load(AccountCache.studentCard, accountID: id) }.value
    async let details: [SchoolEventDetail] = Task.detached { AccountCache.load(AccountCache.eventDetails, accountID: id) }.value
    let loaded = await (attendance, timetable, hunt, events, rates, students, details)
    let savedNotices: [SchoolNotice] = await Task.detached { AccountCache.load(AccountCache.notices, accountID: id) }.value
    let savedNoticeDetails: [SchoolNoticeDetail] = await Task.detached { AccountCache.load(AccountCache.noticeDetails, accountID: id) }.value
    if notices.isEmpty { notices = savedNotices }
    for detail in savedNoticeDetails where noticeDetails[detail.key] == nil { noticeDetails[detail.key] = detail }
    // 学校からの取得が先に終わっていたら、古い保存内容で上書きしない
    if days.isEmpty {
      days = loaded.0
    }
    if self.timetable.isEmpty {
      self.timetable = loaded.1
    }
    if huntActivities.isEmpty {
      huntActivities = loaded.2
    }
    if schoolEvents.isEmpty {
      schoolEvents = loaded.3
    }
    if attendanceRates == AttendanceRates() {
      attendanceRates = loaded.4.first ?? AttendanceRates()
    }
    if student == nil {
      student = loaded.5.first
    }
    if eventDetails.isEmpty {
      eventDetails = Dictionary(loaded.6.map { (Self.detailKey(title: $0.title, date: $0.date), $0) }, uniquingKeysWith: { $1 })
    }
    let savedGrades: [GradeRecord] = await Task.detached { AccountCache.load(AccountCache.grades, accountID: id) }.value
    if grades.isEmpty {
      grades = savedGrades
    }
  }

  /// 成績。取得済みなら再取得せず、`force`（下に引いて更新）で取り直す。保存済みの内容があれば先にそれを表示する。
  func loadGrades(force: Bool = false) async {
    guard isLoggedIn, !isDemo, !isLoadingGrades, force || !gradesLoaded else { return }
    if !force, !grades.isEmpty, FetchLog.isFresh(.grades, account: accountID) {
      gradesLoaded = true
      return
    }
    isLoadingGrades = true
    defer { isLoadingGrades = false }
    let account = accountID
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    do {
      let items = try await client.grades(retryWith: saved.map { ($0.id, $0.password) })
      guard isCurrent(account) else { return }
      #if DEBUG
      print("[School] 成績: \(items.count)科目")
      #endif
      gradesLoaded = true
      gradesLoadFailed = false
      FetchLog.markFetched(.grades, account: accountID)
      if items != grades {
        grades = items
        saveCache(items, name: AccountCache.grades)
      }
    } catch {
      gradesLoadFailed = grades.isEmpty // 保存済みの内容を表示しているときは、失敗扱いにしない
      #if DEBUG
      print("[School] 成績を取得できませんでした: \(error)")
      #endif
    }
  }

  /// 取得を始めたときと同じアカウントで、まだログインしているか。
  /// 取得の途中でログアウトしたり別のアカウントでログインし直したりしたら、届いた結果は捨てる
  /// （以前は、ログアウト後に終わった取得が前のアカウントのデータを画面に書き戻すことがあった）。
  private func isCurrent(_ account: String?) -> Bool {
    isLoggedIn && account != nil && account == accountID
  }

  /// 端末への保存。エンコードとファイル書き込みは主スレッドの外で行う。
  private func saveCache<T: Codable & Sendable>(_ items: [T], name: String) {
    guard !isDemo, let id = accountID else { return }
    Task.detached { AccountCache.save(items, name: name, accountID: id) }
  }

  /// 取得が終わった月・取得中の月（月初の日付）。画面で「データがない」と「まだ取得していない」を区別するのに使う。
  @Published private(set) var loadedMonths: Set<Date> = []
  @Published private(set) var loadingMonths: Set<Date> = []

  /// ログインできたときだけ ID とパスワードを Keychain に保存し、出欠を1回取得する。
  func login(id: String, password: String) async {
    isLoading = true
    errorMessage = nil
    credentialsRejected = false
    defer { isLoading = false }
    do {
      try await client.login(id: id, password: password)
      #if DEBUG
      print("[School] ログイン成功")
      #endif
      KeychainService.save(id: id, password: password)
      // 保存済みの内容がこのアカウントのものなら、確定した過去の月・出席率は学校へ取り直さない
      let cacheIsThisAccount = AccountCache.lastAccountID == id
      if accountID != nil, accountID != id { attendanceRates = AttendanceRates() }
      rateGeneration = UUID()
      loadedRatePeriods = cacheIsThisAccount && attendanceRates != AttendanceRates() ? FetchLog.settledRates(account: id) : []
      loadingRatePeriods = []; failedRatePeriods = []
      isLoggedIn = true
      accountID = id
      AccountCache.lastAccountID = id
      loadedMonths = cacheIsThisAccount && !days.isEmpty ? FetchLog.settledMonths(account: id) : []
      // 保存済みの出欠・出席率が新しい（前回の取得から24時間以内）なら、学校には取りに行かない。
      // 保存してある月は取得済みとして扱う（下に引いて更新すれば、いつでも取り直せる）
      let attendanceFresh = cacheIsThisAccount && !days.isEmpty && FetchLog.isFresh(.attendance, account: id)
      attendanceUpdatedAt = cacheIsThisAccount ? FetchLog.lastFetched(.attendance, account: id) : nil
      if attendanceFresh {
        loadedMonths.formUnion(Self.monthsCovered(by: days))
      }
      #if DEBUG
      print("[School] 確定済みで取り直さない：出欠 \(loadedMonths.count)か月、出席率 \(loadedRatePeriods.count)件")
      #endif
      // ログインできたら、各データの取得はそれぞれ独立して始める。
      // （以前は最初の出欠の取得が失敗すると、説明会・出席率などの取得まで始まらなかった）
      Task { await loadHuntActivities() } // 画面を開く前に先読み
      Task { await loadSchoolEvents() }
      Task { await loadTimetable() }
      Task { await loadStudentCard() }
      Task { await loadGrades() }
      // 画面を先に表示し、直近6か月・対応する学年・開始日が既知の総合をまとめて取る
      // （ログイン前に画面で開いていた月も、ここで一緒に取る）
      guard !attendanceFresh else {
        #if DEBUG
        print("[School] 出欠・出席率：前回の取得から24時間以内なので、保存済みの内容を使う")
        #endif
        return
      }
      Task {
        let recent = (0..<6).compactMap { AttendanceRatePeriod.calendar.date(byAdding: .month, value: -$0, to: Self.monthStart(Date())) }
        await loadRates(months: recent + shownRateMonths, includeOverall: true)
      }
      do {
        let firstDays = try await client.attendance(retryWith: (id, password))
        guard isCurrent(id) else { return }
        merge(firstDays)
        #if DEBUG
        print("[School] ログイン直後の出欠: \(firstDays.count)日分")
        #endif
      } catch SchoolError.noRecords {
        // 今の期間に出欠の記録がまだ無いだけ（月初など）
      } catch {
        // 出欠だけ読めなかった：ログイン自体は成功しているので、知らせるだけにして他の取得は続ける
        errorMessage = Self.message(for: error)
        #if DEBUG
        print("[School] ログイン直後の出欠を取得できませんでした: \(error)")
        #endif
      }
      Task {
        await preloadAttendance()
        markAttendanceFetched()
      }
    } catch {
      if case SchoolError.loginFailed = error {
        credentialsRejected = true
      }
      errorMessage = Self.message(for: error)
    }
  }

  /// デモモードを始める（DemoData の架空データを入れる。学校・保存内容・Keychain には触らない）
  func startDemo() {
    isDemo = true
    isLoggedIn = true
    accountID = DemoData.accountID
    student = DemoData.student
    days = DemoData.attendance
    loadedMonths = Set(days.map { Self.monthStart($0.date) }).union([Self.monthStart(Date())])
    let rates = DemoData.rates(for: days)
    attendanceRates = rates.rates
    loadedRatePeriods = rates.periods
    timetable = DemoData.timetable
    schoolEvents = DemoData.schoolEvents
    eventDetails = Dictionary(DemoData.eventDetails.map { (Self.detailKey(title: $0.title, date: $0.date), $0) }, uniquingKeysWith: { $1 })
    grades = DemoData.grades
    huntActivities = DemoData.huntActivities
    notices = DemoData.notices
    noticeDetails = Dictionary(DemoData.noticeDetails.map { ($0.key, $0) }, uniquingKeysWith: { $1 })
  }

  /// ID とパスワードが保存されていれば自動でログインする（起動時に使う）。
  func restoreSession() async {
    guard !isLoggedIn,
          let saved = await Task.detached(operation: { KeychainService.load() }).value else { return }
    await login(id: saved.id, password: saved.password)
  }

  /// 指定した範囲（過去の月に切り替えたときなど）を読み込み、`days` に合わせる。
  /// 読み込み済み・読み込み中の月は飛ばす。通信は別の Task で行うので、画面を切り替えても取り消されない。
  func loadAttendance(from: Date, through: Date) async {
    guard isLoggedIn, !isDemo else { return }
    let month = Self.monthStart(from)
    guard !loadedMonths.contains(month), !loadingMonths.contains(month) else { return }
    loadingMonths.insert(month)
    await Task { await fetchMonth(month, from: from, through: through) }.value
  }

  /// 過去 `yearsBack` 年分を裏で先に読み込む。1回の通信で12か月分（新しい方から）を取り、アプリの中で月ごとに分ける。
  /// ある範囲にまったくデータがなければ（入学前など）そこで止める。
  func preloadAttendance(yearsBack: Int = 5) async {
    await preloadAttendanceChunks(yearsBack: yearsBack)
    guard errorMessage == nil || attendanceRates.overallFrom != nil else { return }
    await refineOverallRate()
  }

  /// 記録の読み込み後、総合の開始日を最古の取得済み記録に合わせる。仮の「4年前」は使わない。
  private func refineOverallRate() async {
    guard isLoggedIn, !isDemo, let earliest = days.map(\.date).min() else { return }
    let start = AttendanceRatePeriod.calendar.startOfDay(for: min(earliest, attendanceRates.overallFrom ?? earliest))
    let expected = AttendanceRatePeriod.make(.total, month: start, overallStart: start)
    if let expected, loadedRatePeriods.contains(expected) { return }
    await loadRates(months: [], includeOverall: true, overallStart: start)
  }

  private func preloadAttendanceChunks(yearsBack: Int) async {
    let cal = AttendanceRatePeriod.calendar
    let current = Self.monthStart(Date())
    for chunk in 0..<yearsBack {
      guard isLoggedIn, !isDemo else { return }
      let months: [Date] = (0..<12).compactMap {
        cal.date(byAdding: .month, value: -(chunk * 12 + $0), to: current)
      }
      guard await loadRange(months: months) else { return }
    }
  }

  /// 複数の月を1回の通信で読み込み、その期間にデータがあったかを返す。学校の応答を解析できなければ1か月ずつ読み直す。
  private func loadRange(months: [Date]) async -> Bool {
    let cal = AttendanceRatePeriod.calendar
    let pending = months.filter { !loadedMonths.contains($0) && !loadingMonths.contains($0) }
    guard let first = pending.min(), let last = pending.max(),
          let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: last)
    else {
      return months.contains { m in days.contains { cal.isDate($0.date, equalTo: m, toGranularity: .month) } }
    }
    loadingMonths.formUnion(pending)
    defer { loadingMonths.subtract(pending) }
    let account = accountID
    let result: Result<[AttendanceDay], Error> = await Task {
      do {
        let saved = await Task.detached(operation: { KeychainService.load() }).value
        return try .success(await client.attendance(range: (first, end), retryWith: saved.map { ($0.id, $0.password) }))
      } catch { return .failure(error) }
    }.value
    guard isCurrent(account) else { return false }
    switch result {
    case .success(let loaded):
      merge(loaded)
      loadedMonths.formUnion(pending)
      FetchLog.markMonthsSettled(pending, account: accountID)
      return true
    case .failure(SchoolError.parseFailed), .failure(SchoolError.noRecords):
      // 範囲全体に出欠の行がない、または学校がこの長さの範囲を受け付けない：どちらか見分けるため、1か月ずつ確かめる。
      loadingMonths.subtract(pending)
      await withTaskGroup(of: Void.self) { group in
        for m in pending {
          guard let monthEnd = cal.date(byAdding: DateComponents(month: 1, day: -1), to: m) else { continue }
          group.addTask { await self.loadAttendance(from: m, through: monthEnd) }
        }
      }
      return pending.contains { m in days.contains { cal.isDate($0.date, equalTo: m, toGranularity: .month) } }
    case .failure(let error):
      if !(error is CancellationError), (error as? URLError)?.code != .cancelled {
        errorMessage = Self.message(for: error)
      }
      return false
    }
  }

  private func fetchMonth(_ month: Date, from: Date, through: Date) async {
    defer { loadingMonths.remove(month) }
    #if DEBUG
    let began = Date()
    defer { print("[School] \(month.formatted(.dateTime.year().month())) の出欠: \(String(format: "%.1f", Date().timeIntervalSince(began)))s") }
    #endif
    let account = accountID
    do {
      let saved = await Task.detached(operation: { KeychainService.load() }).value
      let loaded = try await client.attendance(range: (from, through), retryWith: saved.map { ($0.id, $0.password) })
      guard isCurrent(account) else { return }
      merge(loaded)
      loadedMonths.insert(month)
      FetchLog.markMonthsSettled([month], account: accountID)
    } catch SchoolError.noRecords {
      guard isCurrent(account) else { return }
      loadedMonths.insert(month) // 出欠ページは開けたが記録が無い（入学前など）ので、空の月として扱う
      FetchLog.markMonthsSettled([month], account: accountID)
    } catch SchoolError.parseFailed {
      // 出欠ページを読めなかった（学校のエラー・メンテナンスなど）。空の月として確定させず、次に開いたときに取り直す
      #if DEBUG
      print("[School] \(month.formatted(.dateTime.year().month())) の出欠ページを読めませんでした（次の機会に取り直します）")
      #endif
    } catch is CancellationError {
    } catch let error as URLError where error.code == .cancelled {
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  /// 取得した出欠を反映する。保存済みの内容と同じなら何もしない（画面を無駄に更新しない）。
  private func merge(_ loaded: [AttendanceDay]) {
    let cal = AttendanceRatePeriod.calendar
    let loadedDates = Set(loaded.map { cal.startOfDay(for: $0.date) })
    let updated = (days.filter { !loadedDates.contains(cal.startOfDay(for: $0.date)) } + loaded)
      .sorted { $0.date < $1.date }
    guard updated != days else { return }
    days = updated
    scheduleAttendanceSave()
  }

  /// 出欠を端末に保存する。取得のたびに書かないよう、少し待ってまとめて1回だけ（エンコードは別スレッド）。
  private func scheduleAttendanceSave() {
    guard let id = accountID else { return }
    attendanceSaveTask?.cancel()
    attendanceSaveTask = Task {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      let snapshot = days
      await Task.detached { AccountCache.save(snapshot, name: AccountCache.attendance, accountID: id) }.value
    }
  }

  private static func monthStart(_ date: Date) -> Date {
    let cal = AttendanceRatePeriod.calendar
    return cal.date(from: cal.dateComponents([.year, .month], from: date)) ?? date
  }

  /// 学生証（氏名・学籍番号など）。取得済みなら取り直さず、`force` のときは取り直す。
  func loadStudentCard(force: Bool = false) async {
    guard isLoggedIn, !isDemo, !isLoadingStudent, force || !studentLoaded else { return }
    if !force, student != nil, FetchLog.isFresh(.studentCard, account: accountID) {
      studentLoaded = true
      return
    }
    isLoadingStudent = true
    studentLoadFailed = false
    defer { isLoadingStudent = false }
    let account = accountID
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    do {
      let card = try await client.studentCard(retryWith: saved.map { ($0.id, $0.password) })
      guard isCurrent(account) else { return }
      if card != student {
        student = card
      }
      studentLoaded = true
      FetchLog.markFetched(.studentCard, account: accountID)
      saveCache([card], name: AccountCache.studentCard)
    } catch is CancellationError {
    } catch {
      studentLoadFailed = student == nil // 保存済みの内容を表示しているときは、失敗扱いにしない
    }
  }

  /// 月・学年・総合の範囲をまとめて、学校の集計ページに順番に問い合わせる。
  /// 総合は、実際の最初の記録の日がわかっているときだけ問い合わせる（推測した年からは問い合わせない）。
  func loadRates(months: [Date], includeOverall: Bool, overallStart: Date? = nil) async {
    guard isLoggedIn, !isDemo else { return }
    let fresh = FetchLog.isFresh(.attendance, account: accountID)
    let entries = AttendanceRatePeriod.batch(months: months,
      overallStart: overallStart ?? attendanceRates.overallFrom, includeOverall: includeOverall)
      .filter { !loadedRatePeriods.contains($0) && !loadingRatePeriods.contains($0) }
      // 前回の取得から24時間以内なら、保存済みの値がある期間は取りに行かない
      .filter { !fresh || attendanceRates.value($0.scope, month: $0.from) == nil }
    guard !entries.isEmpty else { return }
    let generation = rateGeneration
    let requestedAccount = accountID
    loadingRatePeriods.formUnion(entries)
    failedRatePeriods.subtract(entries)
    defer { if generation == rateGeneration { loadingRatePeriods.subtract(entries) } }
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    do {
      let values = try await client.attendanceRates(
        ranges: entries.map { ($0.from, $0.through) }, retryWith: saved.map { ($0.id, $0.password) })
      guard generation == rateGeneration, requestedAccount == accountID, isLoggedIn else { return }
      guard values.count == entries.count else { throw SchoolError.parseFailed }
      #if DEBUG
      print("[School] 出席率: \(zip(entries, values).map { "\($0.scope)=\($1.map { String($0) } ?? "値なし")" }.joined(separator: ", "))")
      #endif
      var updated = attendanceRates
      for (period, value) in zip(entries, values) {
        updated.update(value, for: period)
        loadedRatePeriods.insert(period)
      }
      FetchLog.markRatesSettled(entries, account: accountID)
      if updated != attendanceRates {
        attendanceRates = updated
        saveCache([updated], name: AccountCache.attendanceRates)
      }
    } catch {
      guard generation == rateGeneration, requestedAccount == accountID, isLoggedIn else { return }
      failedRatePeriods.formUnion(entries)
      #if DEBUG
      print("[School] 出席率を取得できませんでした: \(error)")
      #endif
    }
  }

  /// カレンダーの月を変えたときは、その学年の出席率も取得する。出席率のカードをめくるだけでは取得しない。
  func requestMonthlyRate(for monthStart: Date) {
    let start = AttendanceRatePeriod.monthStart(monthStart)
    let months = (0...2).compactMap { AttendanceRatePeriod.calendar.date(byAdding: .month, value: -$0, to: start) }
    shownRateMonths = months
    Task { await loadRates(months: months, includeOverall: false) }
  }

  /// 画面で今開いている月（とその前の2か月）。ログインが終わる前に開いた月や、下に引いて更新したときに
  /// 取得が取り消された月も、ログイン後・更新後にもう一度取るために覚えておく
  /// （以前は取り直されず、出席率が「取得待ち」のまま止まることがあった）。
  private var shownRateMonths: [Date] = []

  /// 時間割。前回の結果が端末にあれば先に表示し、取得できた月から順に反映する。
  func loadTimetable(force: Bool = false) async {
    guard isLoggedIn, !isDemo, !isLoadingTimetable, force || !timetableLoaded else { return }
    if !force, !timetable.isEmpty, FetchLog.isFresh(.timetable, account: accountID) {
      timetableLoaded = true
      #if DEBUG
      print("[School] 時間割：前回の取得から間もないので、保存済みの内容を使う")
      #endif
      return
    }
    isLoadingTimetable = true
    timetableLoadFailed = false
    defer { isLoadingTimetable = false }
    let showProgress = timetable.isEmpty // キャッシュがある間は途中経過で上書きしない
    let account = accountID
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    do {
      let days = try await client.timetable(retryWith: saved.map { ($0.id, $0.password) }) { [weak self] days in
        if showProgress, self?.isCurrent(account) == true {
          self?.timetable = days
        }
      }
      guard isCurrent(account) else { return }
      if days != timetable {
        timetable = days
      }
      timetableLoaded = true
      FetchLog.markFetched(.timetable, account: accountID)
      saveCache(days, name: AccountCache.timetable)
    } catch is CancellationError {
    } catch {
      timetableLoadFailed = timetable.isEmpty
    }
  }

  /// 説明会の詳細（学校ポータルのタイトルで検索）。同じアプリ起動中は取得済みの内容を使い回す。
  func eventDetail(title: String, date: String) async -> SchoolEventDetailResult {
    let key = Self.detailKey(title: title, date: date)
    if isDemo { return eventDetails[key].map(SchoolEventDetailResult.loaded) ?? .unavailable }
    // 1時間以内に取得した詳細は、学校に問い合わせずにそのまま使う（申込状況は一覧の方で分かる）
    if let cached = eventDetails[key], let at = detailFetchedAt[key], Date().timeIntervalSince(at) < 60 * 60 {
      return .loaded(cached)
    }
    guard isLoggedIn, !isDemo else {
      #if DEBUG
      print("[School] 詳細: まだログインしていません（ログイン後に読み直します）")
      #endif
      return .failed
    }
    let account = accountID
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    do {
      guard let detail = try await client.schoolEventDetail(title: title, date: date, retryWith: saved.map { ($0.id, $0.password) }) else {
        return .unavailable
      }
      guard isCurrent(account) else { return .failed }
      detailFetchedAt[key] = .now
      if eventDetails[key] != detail {
        eventDetails[key] = detail
        saveCache(Array(eventDetails.values), name: AccountCache.eventDetails)
      }
      return .loaded(detail)
    } catch {
      #if DEBUG
      print("[School] 説明会の詳細を取得できませんでした（\(title)）: \(error)")
      #endif
      return .failed
    }
  }

  /// 端末に保存してある説明会の詳細（先に表示するため）。学校の最新の内容は `eventDetail(title:date:)` で取得する。
  func cachedEventDetail(title: String, date: String) -> SchoolEventDetail? {
    eventDetails[Self.detailKey(title: title, date: date)]
  }

  /// 詳細の保存キー。同じタイトルの説明会が別の日にもあるので、開催日の数字も含める。
  private static func detailKey(title: String, date: String) -> String {
    title + "|" + SchoolClient.dateKey(date)
  }

  /// 公欠申請などの添付ファイル。端末に保存済みならそれを返し、なければ学校から取得して保存する。
  func attachmentData(for activity: HuntActivity) async -> Data? {
    guard let url = activity.attachmentURL else { return nil }
    let name = url.lastPathComponent
    if let cached = await Task.detached(operation: { AttachmentCache.load(name) }).value {
      return cached
    }
    guard isLoggedIn, !isDemo else { return nil }
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    do {
      let data = try await client.downloadAttachment(from: url, retryWith: saved.map { ($0.id, $0.password) })
      Task.detached { AttachmentCache.save(data, name: name) }
      return data
    } catch {
      return nil
    }
  }

  enum ApplyResult: Equatable {
    case applied(message: String?)
    /// アプリからは申し込めない（学校サイトで申し込む）
    case needsWebsite(String)
    case failed(String)
  }

  /// 説明会に申し込む。押し終えたら「イベント申込」一覧を取り直し、申込状況が「申込済」になったときだけ成功とする。
  func applySchoolEvent(_ event: SchoolEvent) async -> ApplyResult {
    if isDemo {
      try? await Task.sleep(for: .seconds(1))
      schoolEvents = schoolEvents.map {
        $0.id == event.id ? SchoolEvent(title: $0.title, status: "申込済", date: $0.date, applyPeriod: $0.applyPeriod) : $0
      }
      return .applied(message: nil)
    }
    guard isLoggedIn, !isDemo else { return .failed("ログインしていません。") }
    guard !applyingEventTitles.contains(event.title) else { return .failed("申込を処理中です。") }
    applyingEventTitles.insert(event.title)
    defer { applyingEventTitles.remove(event.title) }
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    let outcome: SchoolEventApplyOutcome
    do {
      outcome = try await client.applySchoolEvent(title: event.title, date: event.date, retryWith: saved.map { ($0.id, $0.password) })
    } catch {
      // ボタンを押した後の通信エラーかもしれないので、一覧で申込状況を確かめてから伝える
      await loadSchoolEvents(force: true)
      if isApplied(event) { return .applied(message: nil) }
      return .failed(Self.message(for: error))
    }
    #if DEBUG
    print("[School] 申込の結果: \(outcome)")
    #endif
    if case .needsWebsite(let reason) = outcome { return .needsWebsite(reason) }
    await loadSchoolEvents(force: true)
    if isApplied(event) {
      if case .submitted(let message) = outcome { return .applied(message: message) }
      return .applied(message: nil)
    }
    switch outcome {
    case .rejected(let message): return .failed(message)
    default: return .failed("申込を確認できませんでした。学校サイトで申込状況を確かめてください。")
    }
  }

  private func isApplied(_ event: SchoolEvent) -> Bool {
    schoolEvents.first { $0.title == event.title && SchoolClient.dateKey($0.date) == SchoolClient.dateKey(event.date) }?.isApplied == true
  }

  /// 学校のイベント申込一覧（＝説明会の一覧）を取り直す。失敗しても既存の表示は変えない。
  /// 実行中の一覧の取得。`force` の呼び出しは、これが終わるのを待ってから取り直す。
  private var schoolEventsTask: Task<Void, Never>?

  // MARK: 学校からのお知らせ

  /// 学校の掲示板（全分類）の掲載中のお知らせを読む。既読のものも掲載期間中は出る。
  func loadNotices(force: Bool = false) async {
    guard isLoggedIn, !isDemo, !isLoadingNotices else { return }
    if !force, !notices.isEmpty, FetchLog.isFresh(.notices, account: accountID) { return }
    isLoadingNotices = true
    defer { isLoadingNotices = false }
    let account = accountID
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    do {
      let fetched = try await client.schoolNotices(retryWith: saved.map { ($0.id, $0.password) })
      guard isCurrent(account) else { return }
      noticesLoadFailed = false
      FetchLog.markFetched(.notices, account: accountID)
      let merged = Self.mergeNotices(fetched: fetched, saved: notices)
      if merged != notices { notices = merged }
      saveCache(merged, name: AccountCache.notices)
    } catch {
      guard isCurrent(account) else { return }
      noticesLoadFailed = true
      #if DEBUG
      print("[School] お知らせ: 取得失敗 \(error)")
      #endif
    }
  }

  /// 掲示板の一覧（掲載中のものだけ）を新しい順に並べる。掲載が終わったものは学校の一覧から消えるので、端末にも残さない。
  nonisolated static func mergeNotices(fetched: [SchoolNotice], saved: [SchoolNotice], now: Date = .now) -> [SchoolNotice] {
    var seen = Set<String>()
    return fetched
      .filter { seen.insert($0.key).inserted }
      .sorted { ($0.postedAt ?? .distantPast) > ($1.postedAt ?? .distantPast) }
  }

  /// 未読の印：学校側で未読（このアプリで開いたものは既読）。学校の未読がわからない保存内容は、開いたかどうかだけで判断
  func isNoticeUnread(_ notice: SchoolNotice) -> Bool {
    guard !readNoticeKeys.contains(notice.key) else { return false }
    return notice.unreadOnServer ?? true
  }

  func cachedNoticeDetail(_ notice: SchoolNotice) -> SchoolNoticeDetail? {
    noticeDetails[notice.key]
  }

  /// お知らせの詳細。保存済みならそれを返し、無ければ学校の詳細ページを開く（学校側でも既読になる）。
  func noticeDetail(_ notice: SchoolNotice) async -> SchoolNoticeDetail? {
    markNoticeRead(notice)
    if let cached = noticeDetails[notice.key] { return cached }
    guard isLoggedIn, !isDemo else { return nil }
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    do {
      let detail = try await client.noticeDetail(notice, retryWith: saved.map { ($0.id, $0.password) })
      noticeDetails[notice.key] = detail
      saveCache(Array(noticeDetails.values), name: AccountCache.noticeDetails)
      return detail
    } catch {
      #if DEBUG
      print("[School] お知らせの詳細: 取得失敗 \(error)")
      #endif
      return nil
    }
  }

  /// お知らせの添付ファイル。端末に保存済みならそれを返し、無ければ学校から取得して保存する。
  func noticeAttachmentData(_ attachment: SchoolNoticeDetail.Attachment, of notice: SchoolNotice) async -> Data? {
    // 保存名：お知らせの key から作る固定の番号（hashValue は起動ごとに変わるので使わない）＋ファイル名
    let stable = notice.key.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
    let name = "notice_" + String(stable, radix: 36) + "_" + attachment.name
    if let cached = await Task.detached(operation: { AttachmentCache.load(name) }).value { return cached }
    guard isLoggedIn, !isDemo else { return nil }
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    do {
      let data = try await client.noticeAttachment(attachment, of: notice, retryWith: saved.map { ($0.id, $0.password) })
      Task.detached { AttachmentCache.save(data, name: name) }
      return data
    } catch {
      #if DEBUG
      print("[School] お知らせの添付: 取得失敗 \(error)")
      #endif
      return nil
    }
  }

  private func markNoticeRead(_ notice: SchoolNotice) {
    guard !readNoticeKeys.contains(notice.key) else { return }
    readNoticeKeys.insert(notice.key)
    UserDefaults.standard.set(Array(readNoticeKeys), forKey: "read_notice_keys")
  }

  func loadSchoolEvents(force: Bool = false) async {
    guard isLoggedIn, !isDemo else { return }
    if schoolEventsTask != nil {
      // 取得中なら、その完了を待つ。申込の確認など `force` のときは、待ったあとにもう一度取り直す
      // （以前は取得中だと何もせずに戻り、申込前の古い一覧で申込状況を判断することがあった）
      while let running = schoolEventsTask {
        await running.value
      }
      guard force else { return }
    }
    if !force, !schoolEvents.isEmpty, FetchLog.isFresh(.schoolEvents, account: accountID) {
      #if DEBUG
      print("[School] 説明会一覧：前回の取得から間もないので、保存済みの内容を使う")
      #endif
      return
    }
    let task = Task { await fetchSchoolEvents() }
    schoolEventsTask = task
    await task.value
    if schoolEventsTask == task { schoolEventsTask = nil }
  }

  private func fetchSchoolEvents() async {
    isLoadingSchoolEvents = true
    defer { isLoadingSchoolEvents = false }
    let account = accountID
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    do {
      let events = try await client.schoolEvents(retryWith: saved.map { ($0.id, $0.password) })
      guard isCurrent(account) else { return }
      #if DEBUG
      print("[School] 説明会一覧: \(events.count)件")
      #endif
      schoolEventsLoadFailed = false
      FetchLog.markFetched(.schoolEvents, account: accountID)
      if events != schoolEvents {
        schoolEvents = events
      }
      saveCache(events, name: AccountCache.schoolEvents)
    } catch {
      schoolEventsLoadFailed = true
      #if DEBUG
      print("[School] 説明会一覧を取得できませんでした: \(error)")
      #endif
    }
  }

  /// 就職活動の履歴。取得済みなら再取得せず、`force` で取り直す。
  /// 前回の結果が端末にあれば先にそれを表示し、学校からの取得が終わった時点で置き換える。
  func loadHuntActivities(force: Bool = false) async {
    guard isLoggedIn, !isDemo, !isLoadingHunt, force || !huntLoaded else { return }
    if !force, !huntActivities.isEmpty, FetchLog.isFresh(.huntActivities, account: accountID) {
      huntLoaded = true
      return
    }
    isLoadingHunt = true
    huntLoadFailed = false
    defer { isLoadingHunt = false }
    // キャッシュがある間は途中経過で上書きしない（件数が一時的に減って見えるため）
    let showProgress = huntActivities.isEmpty
    let account = accountID
    let saved = await Task.detached(operation: { KeychainService.load() }).value
    do {
      let items = try await client.huntActivities(retryWith: saved.map { ($0.id, $0.password) }) { [weak self] items in
        if showProgress, self?.isCurrent(account) == true {
          self?.huntActivities = items
        }
      }
      guard isCurrent(account) else { return }
      if items != huntActivities {
        huntActivities = items
      }
      huntLoaded = true
      FetchLog.markFetched(.huntActivities, account: accountID)
      saveCache(items, name: AccountCache.huntActivities)
    } catch is CancellationError {
    } catch {
      huntLoadFailed = huntActivities.isEmpty
    }
  }

  /// 追加フォームを開く（学校から空のフォームを取り直す）。
  func beginHuntEntry() async {
    huntValues = HuntEntryValues()
    huntFormError = nil
    await runHuntForm {
      let state = try await self.client.beginHuntEntry()
      self.huntForm = state
      self.huntValues.year = state.year
    }
  }

  /// 企業名で学校の登録企業を絞り込む。候補が1件なら学校側が自動で選択する。
  func searchCompany() async {
    let query = huntValues.companySearch.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return }
    huntValues.companySearch = query
    huntValues.companyChoice = ""
    await runHuntForm {
      self.huntForm = try await self.client.updateHuntEntry(self.huntValues, trigger: .companySearch)
      self.huntValues.companyChoice = self.huntForm.selectedCompany
    }
  }

  /// 活動日 → 企業名 → 追加 の順に送る。成功したら true を返し、一覧を読み直す。
  func submitHuntEntry() async -> Bool {
    var ok = false
    await runHuntForm {
      // 学校のページと同じ順：活動日（時限・添付の欄が開く）→ 企業 → 追加
      if !self.huntValues.date.isEmpty {
        self.huntForm = try await self.client.updateHuntEntry(self.huntValues, trigger: .date)
      }
      if self.huntValues.useManualCompany {
        if !self.huntValues.company.isEmpty {
          self.huntForm = try await self.client.updateHuntEntry(self.huntValues, trigger: .company)
        }
      } else {
        if !self.huntValues.companySearch.isEmpty {
          self.huntForm = try await self.client.updateHuntEntry(self.huntValues, trigger: .companySearch)
        }
        if !self.huntValues.companyChoice.isEmpty {
          self.huntForm = try await self.client.updateHuntEntry(self.huntValues, trigger: .companyChoice)
        }
      }
      try await self.client.submitHuntEntry(self.huntValues)
      ok = true
    }
    if ok {
      await loadHuntActivities(force: true)
    }
    return ok
  }

  private func runHuntForm(_ work: () async throws -> Void) async {
    isHuntFormBusy = true
    huntFormError = nil
    defer { isHuntFormBusy = false }
    do {
      try await work()
    } catch SchoolError.rejected(let message) {
      huntFormError = message
    } catch is CancellationError {
    } catch {
      huntFormError = Self.message(for: error)
    }
  }

  /// 下に引いて更新したとき：確定した過去の月以外を取り直し、今月を取得して、先読みもやり直す。
  func refreshAttendance() async {
    guard isLoggedIn, !isDemo else { return }
    errorMessage = nil
    FetchLog.markStale(.attendance, account: accountID) // 期限に関係なく取り直す
    // 下に引いて更新：確定した過去の月以外はすべて取り直す
    loadedMonths = FetchLog.settledMonths(account: accountID)
    rateGeneration = UUID()
    loadedRatePeriods = FetchLog.settledRates(account: accountID)
    loadingRatePeriods = []; failedRatePeriods = [] // キャッシュを表示しながら再取得
    let cal = AttendanceRatePeriod.calendar
    let start = Self.monthStart(Date())
    guard let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start) else { return }
    await loadRates(months: [Self.monthStart(Date())] + shownRateMonths, includeOverall: true)
    await loadAttendance(from: start, through: end)
    await preloadAttendance()
    markAttendanceFetched()
  }

  /// 出欠・出席率を取り終えたら、取得した時刻を記録する（失敗があったときは記録せず、次の起動で取り直す）
  private func markAttendanceFetched() {
    guard isLoggedIn, !isDemo, errorMessage == nil else { return }
    FetchLog.markFetched(.attendance, account: accountID)
    attendanceUpdatedAt = .now
  }

  /// 保存済みの出欠がある最初の月〜今月
  private static func monthsCovered(by days: [AttendanceDay]) -> Set<Date> {
    let cal = AttendanceRatePeriod.calendar
    guard let first = days.map(\.date).min() else { return [] }
    var months: Set<Date> = []
    var month = monthStart(first)
    let last = monthStart(Date())
    while month <= last {
      months.insert(month)
      guard let next = cal.date(byAdding: .month, value: 1, to: month) else { break }
      month = next
    }
    return months
  }

  func logout() async {
    attendanceSaveTask?.cancel()
    let wasDemo = isDemo
    isDemo = false
    if !wasDemo {
      await client.logout()
      KeychainService.clear()
    }
    days = []
    student = nil
    grades = []
    notices = []
    noticeDetails = [:]
    readNoticeKeys = []
    UserDefaults.standard.removeObject(forKey: "read_notice_keys")
    gradesLoaded = false
    gradesLoadFailed = false
    huntActivities = []
    huntLoaded = false
    if !wasDemo {
      AccountCache.clearAll()
      FetchLog.clearAll()
      AttachmentCache.clear()
    }
    timetable = []
    timetableLoaded = false
    eventDetails = [:]
    detailFetchedAt = [:]
    attendanceUpdatedAt = nil
    attendanceRates = AttendanceRates()
    rateGeneration = UUID()
    loadedRatePeriods = []; loadingRatePeriods = []; failedRatePeriods = []
    schoolEvents = []
    loadedMonths = []
    loadingMonths = []
    isLoggedIn = false
    accountID = nil
  }

  private static func message(for error: Error) -> String {
    switch error {
    case SchoolError.loginFailed: return "ログインに失敗しました。IDとパスワードを確認してください。"
    case SchoolError.parseFailed: return "出欠データを読み取れませんでした。"
    case SchoolError.notLoggedIn: return "ログインしていません。"
    case SchoolError.noRecords: return "出欠の記録がありません。"
    case SchoolError.rejected(let message): return message
    default: return "通信に失敗しました。ネットワークを確認してください。"
    }
  }
}
