import Foundation

/// テスト用の架空データ（デモモード・Xcode のプレビュー・スクリーンショット・発表）。テスト用のデータはすべてこのファイルにまとめる。
/// ここにあるものはすべて作りもの（人名・企業名・数値・日付）。実在の企業名は使わない。
///
/// 使い方: Xcode の Product → Scheme → Edit Scheme… → Run → Arguments に `-demo` を追加して実行する。
/// - 学校ポータルには一切接続しない（ログイン画面も出ない）
/// - 保存済みのデータ・Keychain のアカウントには触らない（デモ中にログアウトしても本物のアカウントは消えない）
/// - 日付は「今日」を基準に作るので、いつ撮っても自然に見える
/// - DEBUG ビルドだけで有効。リリース版では `-demo` を付けても何も起きない
nonisolated enum DemoData {
  static var isEnabled: Bool {
    #if DEBUG
    ProcessInfo.processInfo.arguments.contains("-demo")
    #else
    false
    #endif
  }

  static let accountID = "2400123"

  private static var calendar: Calendar { AttendanceRatePeriod.calendar }
  private static var today: Date { calendar.startOfDay(for: .now) }
  private static func day(_ offset: Int, from base: Date? = nil) -> Date {
    calendar.date(byAdding: .day, value: offset, to: base ?? today)!
  }

  /// 入学日（総合の出席率の起点）。今年度の前の年度の4月 → 2年生。
  static var enrollment: Date {
    let thisYear = AttendanceRatePeriod.yearStart(today)
    return calendar.date(byAdding: DateComponents(year: -1, day: 6), to: thisYear)!
  }

  // MARK: 学生証

  static let student = StudentCardData(
    displayName: "神戸 太郎",
    studentNumber: accountID,
    department: "ITエキスパート学科",
    fields: [
      "学年": "2年",
      "クラス": "IE2A",
      "学生NO": "12",
      "学籍番号": accountID,
      "学科": "ITエキスパート学科",
      "専攻": "システム開発専攻",
      "コース": "スマートフォンアプリコース",
      "氏名": "神戸 太郎",
      "ふりがな": "こうべ たろう",
      "生年月日": "2005/05/05",
      "性別": "男",
      "居住状態": "自宅",
    ])

  // MARK: 出欠・出席率

  /// 授業のある日（平日。長期休みは除く）
  private static func isSchoolDay(_ date: Date) -> Bool {
    guard (2...6).contains(calendar.component(.weekday, from: date)) else { return false }
    let m = calendar.component(.month, from: date), d = calendar.component(.day, from: date)
    if m == 8 || (m == 9 && d < 10) { return false }          // 夏休み
    if (m == 12 && d > 24) || (m == 1 && d < 7) { return false } // 冬休み
    if (m == 3 && d > 15) || (m == 4 && d < 7) { return false }  // 春休み
    return true
  }

  /// 入学日〜昨日の出欠（1日4コマ）。ほとんど出席、ときどき遅刻・欠席・就職・公欠。毎回同じ結果になる乱数を使う。
  static var attendance: [AttendanceDay] {
    var result: [AttendanceDay] = []
    var seed: UInt64 = 0x5EED
    func roll() -> Int {
      seed = seed &* 6364136223846793005 &+ 1442695040888963407
      return Int(seed >> 33) % 1000
    }
    var date = enrollment
    while date < today {
      if isSchoolDay(date) {
        let periods = (1...4).map { number -> AttendancePeriod in
          let r = roll()
          let status = r < 935 ? "出席" : r < 960 ? "遅刻" : r < 975 ? "就職" : r < 985 ? "公欠" : "欠席"
          return AttendancePeriod(number: number, rawStatus: status)
        }
        result.append(AttendanceDay(date: date, periods: periods))
      }
      date = day(1, from: date)
    }
    return result
  }

  /// 出欠から計算した月・年度・総合の出席率（学校の計算と同じく、就職・公欠は出席扱い）
  static func rates(for days: [AttendanceDay]) -> (rates: AttendanceRates, periods: Set<AttendanceRatePeriod>) {
    var months = Set(days.map { AttendanceRatePeriod.monthStart($0.date) })
    months.insert(AttendanceRatePeriod.monthStart(today))
    let periods = AttendanceRatePeriod.batch(months: Array(months), overallStart: enrollment, includeOverall: true)
    var rates = AttendanceRates()
    for period in periods {
      let marks = days.filter { $0.date >= period.from && $0.date <= period.through }.flatMap(\.periods)
      guard !marks.isEmpty else { rates.update(nil, for: period); continue }
      let counted = marks.filter { ["出席", "就職", "公欠"].contains($0.rawStatus) }.count
      rates.update((Double(counted) / Double(marks.count) * 10000).rounded() / 100, for: period)
    }
    return (rates, Set(periods))
  }

  // MARK: 時間割

  private static let weekSubjects: [Int: [String]] = [
    2: ["Swift アプリ開発", "Swift アプリ開発", "データベース", "ビジネス英語"],
    3: ["Web システム開発", "Web システム開発", "ネットワーク", "キャリアデザイン"],
    4: ["UI/UX デザイン", "UI/UX デザイン", "アルゴリズム", ""],
    5: ["チーム開発演習", "チーム開発演習", "チーム開発演習", "情報セキュリティ"],
    6: ["資格対策（応用情報）", "資格対策（応用情報）", "就職実務", ""],
  ]

  /// 先月の初め〜3か月後の授業
  static var timetable: [TimetableDay] {
    let start = calendar.date(byAdding: .month, value: -1, to: AttendanceRatePeriod.monthStart(today))!
    let end = calendar.date(byAdding: .month, value: 3, to: today)!
    var result: [TimetableDay] = []
    var date = start
    while date <= end {
      if isSchoolDay(date), let subjects = weekSubjects[calendar.component(.weekday, from: date)] {
        let lessons = subjects.enumerated().compactMap { index, name in
          name.isEmpty ? nil : TimetableLesson(period: "\(index + 1)限", name: name)
        }
        result.append(TimetableDay(date: date, lessons: lessons))
      }
      date = day(1, from: date)
    }
    return result
  }

  // MARK: 説明会

  /// 学校の書き方「26/11/05(木)」
  private static func portalDate(_ date: Date, year: Bool = true) -> String {
    let c = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
    let weekday = ["日", "月", "火", "水", "木", "金", "土"][c.weekday! - 1]
    let md = String(format: "%02d/%02d(%@)", c.month!, c.day!, weekday)
    return year ? String(format: "%02d/", c.year! % 100) + md : md
  }

  private struct EventSeed {
    let title: String
    let status: String
    let dayOffset: Int
    let time: (String, String)
    let apply: (Int, Int)
    let kind: String
    let capacity: String
    let remaining: String
    let room: String
    let content: String
  }

  private static let eventSeeds: [EventSeed] = [
    EventSeed(
      title: "【未経験者歓迎】株式会社ネオフィールド 学内説明会", status: "申込受付中", dayOffset: 5,
      time: ("13:00", "14:30"), apply: (-20, 3), kind: "学内説明会", capacity: "40", remaining: "12", room: "1号館 5F 501教室",
      content: """
        【会社概要】
        スマートフォンアプリと業務システムの受託開発を行う、社員80名の IT 企業です。
        神戸・大阪の2拠点で、若手エンジニアが中心となって活躍しています。

        【募集職種】
        ・アプリケーションエンジニア（iOS / Android）
        ・Web エンジニア

        【当日の内容】
        ■ 会社紹介・事業説明（30分）
        ■ 若手社員との座談会（40分）
        ■ 質疑応答

        【持ち物】
        筆記用具、学生証
        """),
    EventSeed(
      title: "ミライシステムズ株式会社 オンライン説明会", status: "申込済", dayOffset: 2,
      time: ("15:10", "16:10"), apply: (-14, 1), kind: "オンライン説明会", capacity: "100", remaining: "38", room: "オンライン（Zoom）",
      content: """
        【会社概要】
        物流・小売向けのクラウドサービスを自社開発しています。

        【参加方法】
        前日までに、登録したメールアドレスへ Zoom の URL をお送りします。
        カメラはオフでも参加できます。
        """),
    EventSeed(
      title: "株式会社ハーバーソフト 学内説明会", status: "申込受付中", dayOffset: 12,
      time: ("10:40", "12:10"), apply: (-3, 9), kind: "学内説明会", capacity: "30", remaining: "4", room: "2号館 3F 304教室",
      content: """
        【会社概要】
        港湾・物流の管理システムを開発する、神戸発のソフトウェア会社です。

        【当日の内容】
        ■ 事業説明
        ■ 社内の開発環境の紹介（Swift / Kotlin / TypeScript）
        ■ 選考スケジュールの案内
        """),
    EventSeed(
      title: "【留学生応募可能】ロッコウ情報サービス株式会社 オンライン説明会", status: "申込受付中", dayOffset: 16,
      time: ("14:00", "15:00"), apply: (-1, 13), kind: "オンライン説明会", capacity: "50", remaining: "27", room: "オンライン（Teams）",
      content: """
        【会社概要】
        自治体・医療機関向けのシステム運用と保守を行っています。
        外国籍の社員も多数在籍しています。
        """),
    EventSeed(
      title: "株式会社コウベデジタル 学内説明会", status: "満席", dayOffset: 8,
      time: ("13:00", "14:30"), apply: (-10, 6), kind: "学内説明会", capacity: "30", remaining: "0", room: "1号館 6F 602教室",
      content: """
        【会社概要】
        ゲーム・エンターテインメント系アプリの開発会社です。
        定員に達したため、受付を終了しました。
        """),
    EventSeed(
      title: "株式会社サンプルテック 学内説明会", status: "申込期間外", dayOffset: 1,
      time: ("16:20", "17:20"), apply: (-15, -2), kind: "学内説明会", capacity: "40", remaining: "", room: "1号館 5F 502教室",
      content: """
        【会社概要】
        業務効率化の SaaS を開発・提供しています。
        """),
  ]

  static var schoolEvents: [SchoolEvent] {
    eventSeeds.map { seed in
      SchoolEvent(
        title: seed.title, status: seed.status,
        date: "\(portalDate(day(seed.dayOffset))) \(seed.time.0)〜\(seed.time.1)",
        applyPeriod: "\(portalDate(day(seed.apply.0)))～\(portalDate(day(seed.apply.1), year: false))")
    }
  }

  static var eventDetails: [SchoolEventDetail] {
    eventSeeds.map { seed in
      SchoolEventDetail(
        title: seed.title, kind: seed.kind,
        date: "\(portalDate(day(seed.dayOffset))) \(seed.time.0)～\(seed.time.1)",
        applyPeriod: "\(portalDate(day(seed.apply.0)))～\(portalDate(day(seed.apply.1), year: false))",
        capacity: seed.capacity, remaining: seed.remaining, room: seed.room,
        publishFrom: portalDate(day(seed.apply.0)), publishTo: portalDate(day(seed.dayOffset)),
        status: seed.status,
        content: [SchoolEventDetail.Run(text: seed.content, url: nil)],
        attachments: [],
        hasApplyButton: seed.status == "申込受付中")
    }
  }

  // MARK: 成績

  static var grades: [GradeRecord] {
    let thisYear = calendar.component(.year, from: AttendanceRatePeriod.yearStart(today))
    let first = String(thisYear - 1), second = String(thisYear)
    func g(_ year: String, _ term: String, _ subject: String, _ category: String, _ credits: String,
           _ s1: String = "", _ g1: String = "", _ s2: String = "", _ g2: String = "") -> GradeRecord {
      GradeRecord(year: year, term: term, subject: subject, category: category, credits: credits,
        firstScore: s1, firstGrade: g1, secondScore: s2, secondGrade: g2)
    }
    return [
      g(first, "前期", "プログラミング基礎", "必修", "4", "92", "A"),
      g(first, "前期", "コンピュータ概論", "必修", "2", "85", "A"),
      g(first, "前期", "情報数学", "必修", "2", "74", "B"),
      g(first, "後期", "オブジェクト指向プログラミング", "必修", "4", "", "", "88", "A"),
      g(first, "後期", "Web デザイン基礎", "選択必修", "2", "", "", "79", "B"),
      g(first, "通年", "ビジネスマナー", "必修", "2", "81", "A", "90", "A"),
      g(first, "通年", "英語コミュニケーション", "必修", "4", "68", "C", "76", "B"),
      g(second, "前期", "Swift アプリ開発", "必修", "4", "95", "A"),
      g(second, "前期", "データベース", "必修", "2", "83", "A"),
      g(second, "前期", "ネットワーク", "必修", "2", "71", "B"),
      g(second, "後期", "チーム開発演習", "必修", "6"),
      g(second, "後期", "情報セキュリティ", "選択必修", "2"),
      g(second, "通年", "UI/UX デザイン", "選択必修", "4", "87", "A"),
      g(second, "通年", "資格対策（応用情報）", "選択", "2", "77", "B"),
    ]
  }

  // MARK: 公欠・就職活動

  static var huntActivities: [HuntActivity] {
    let year = String(calendar.component(.year, from: AttendanceRatePeriod.yearStart(today)))
    func a(_ offset: Int, _ kind: String, _ periods: String, _ mode: String, _ approval: String,
           _ company: String, _ job: String, _ place: String, _ result: String = "", _ resultOffset: Int? = nil) -> HuntActivity {
      HuntActivity(
        year: year, date: portalDate(day(offset)), kind: kind, periods: periods, mode: mode,
        attachment: "", attachmentHref: nil, approval: approval,
        company: company, jobType: job, location: place,
        result: result, resultDate: resultOffset.map { portalDate(day($0)) } ?? "")
    }
    return [
      a(3, "面接", "3・4限", "対面", "未承認", "株式会社ネオフィールド", "アプリケーションエンジニア", "神戸市中央区"),
      a(-6, "一次面接", "1・2限", "オンライン", "承認", "ミライシステムズ株式会社", "Web エンジニア", "大阪市北区", "通過", -2),
      a(-15, "会社説明会", "3限", "対面", "承認", "株式会社ハーバーソフト", "システムエンジニア", "神戸市中央区"),
      a(-28, "適性検査", "1限", "オンライン", "承認", "株式会社コウベデジタル", "ゲームプログラマー", "神戸市東灘区", "不合格", -20),
    ]
  }

  // MARK: プレビュー用（Xcode の Canvas）

  /// プレビューで表示する説明会の詳細。デモの説明会ならその詳細、そうでなければ1件目の内容を使う。
  static func previewDetail(title: String, source: SchoolEvent?) -> SchoolEventDetail {
    if let source, let detail = eventDetails.first(where: { $0.title == source.title }) { return detail }
    return SchoolEventDetail(
      title: title, kind: "学内説明会",
      date: source?.date ?? "", applyPeriod: source?.applyPeriod ?? "",
      capacity: "30", remaining: "12", room: "1号館 5F 501教室", publishFrom: "", publishTo: "",
      status: source?.status ?? "",
      content: [SchoolEventDetail.Run(text: eventSeeds[0].content, url: nil)],
      attachments: ["会社案内.pdf"], hasApplyButton: true)
  }

  /// 出席率カードのプレビューで使う値
  static let previewRateValues: [AttendanceRateScope: Double] = [.month: 95.50, .year: 92.30, .total: 89.90]
  /// 「更新」で切り替えたときの値（数字が入れ替わる動きを確かめる用）
  static let previewRateAlternative = 91.25

  /// 出席率カードのプレビュー用。範囲ごとに `value` の値を入れる（nil なら「値なし」）。
  static func previewRates(_ periods: [AttendanceRatePeriod], value: (AttendanceRateScope) -> Double?) -> AttendanceRates {
    var rates = AttendanceRates()
    for period in periods {
      rates.update(value(period.scope), for: period)
    }
    return rates
  }
}

// MARK: 学校からのお知らせ（デモ・プレビュー用。内容は架空）

extension DemoData {
  /// 今日から `daysAgo` 日前の日付（学校の表記「2026/11/06」）
  private static func noticeDate(_ daysAgo: Int) -> String {
    let calendar = AttendanceRatePeriod.calendar
    let date = calendar.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d/%02d/%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }

  static var notices: [SchoolNotice] {
    [
      SchoolNotice(section: "お知らせ", title: "【重要】今月分の出席状況確認のお願い", category: "連絡・スケジュール",
                   date: noticeDate(1), poster: "教務課", hasAttachment: true, eventTarget: "demo-1"),
      SchoolNotice(section: "授業関連", title: "後期 定期試験の時間割を掲載しました", category: "授業変更関連",
                   date: noticeDate(3), poster: "教務課", hasAttachment: false, eventTarget: "demo-2"),
      SchoolNotice(section: "お知らせ", title: "学内合同企業説明会（12月）の参加申込について", category: "キャリアセンター",
                   date: noticeDate(5), poster: "キャリアセンター", hasAttachment: false, eventTarget: "demo-3"),
      SchoolNotice(section: "連絡事項", title: "冬季休業中の図書室の開室日", category: "事務局窓口・奨学金",
                   date: noticeDate(9), poster: "事務局", hasAttachment: false, eventTarget: "demo-4")
    ]
  }

  static var noticeDetails: [SchoolNoticeDetail] {
    let items = notices
    return [
      SchoolNoticeDetail(key: items[0].key, poster: "教務課", startDate: items[0].date, endDate: noticeDate(-20),
                         title: items[0].title,
                         body: "ポータルサイトで今月分の出席状況を確認してください。\n\n※変更の申し出期限：今月20日 17時まで\n\n誤りを見つけた場合は、担任の先生へ連絡してください。",
                         attachments: []),
      SchoolNoticeDetail(key: items[1].key, poster: "教務課", startDate: items[1].date, endDate: noticeDate(-30),
                         title: items[1].title,
                         body: "後期定期試験の時間割を掲載しました。\n試験期間中は、学生証を必ず持参してください。",
                         attachments: []),
      SchoolNoticeDetail(key: items[2].key, poster: "キャリアセンター", startDate: items[2].date, endDate: noticeDate(-14),
                         title: items[2].title,
                         body: "12月の学内合同企業説明会の申込を受け付けています。\n参加希望者は「イベント申込」から申し込んでください。",
                         attachments: []),
      SchoolNoticeDetail(key: items[3].key, poster: "事務局", startDate: items[3].date, endDate: noticeDate(-40),
                         title: items[3].title,
                         body: "冬季休業中は、図書室を平日の 10:00〜16:00 に開室します。",
                         attachments: [])
    ]
  }
}
