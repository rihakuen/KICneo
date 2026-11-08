import Foundation
import SwiftSoup

enum SchoolError: Error {
  case loginFailed
  case parseFailed
  case notLoggedIn
  /// 出欠ページは正しく開けたが、その範囲に出欠の記録が1件もない（入学前・休みの月など）
  case noRecords
  case rejected(String) // 学校が返したエラーメッセージ
}

/// 説明会の申込の結果（学校側の本当の申込状況は、呼び出し側で一覧を取り直して確かめる）
nonisolated enum SchoolEventApplyOutcome: Sendable, Equatable {
  /// 申込ボタン（と確認ページの確定）を押し終えた。学校が出した文言があれば添える
  case submitted(message: String?)
  /// アプリからは申し込めない（ボタンが無い・入力が必要 など）。申込は確定していない
  case needsWebsite(String)
  /// 学校がエラーを返した
  case rejected(String)
}

/// 神戸電子の Web ポータル：ブラウザと同じ手順でログインし、ASP.NET の postback を送り、HTML を解析する。
actor SchoolClient {
  private let base = URL(string: "https://pt.kobedenshi.ac.jp/portal/mobile/")!
  private let session = URLSession(configuration: .default) // cookie は自動で管理される
  /// 就職活動の追加フォームの今のページ（postback のたびに更新）。
  private var huntPage: (html: String, url: URL?)?
  /// 学校側の「表示中の画面」に依存する処理を1つずつにする鍵（出欠の日別・集計、説明会の詳細・申込）。
  /// 学校側は同じセッションで「日別/集計」のどちらを表示中かを覚えているらしく、並行すると集計に移った直後に
  /// 日別の検索が割り込み、日別ページが返ってくることがある。説明会の申込（一覧→詳細→申込ボタン）も、
  /// 途中に別の画面の通信が割り込まないように、同じ鍵で1つずつ行う。
  private var pageLocked = false
  private var pageWaiters: [CheckedContinuation<Void, Never>] = []

  private func withPageLock<T>(_ body: () async throws -> T) async rethrows -> T {
    while pageLocked {
      await withCheckedContinuation { pageWaiters.append($0) }
    }
    pageLocked = true
    defer {
      pageLocked = false
      if !pageWaiters.isEmpty {
        pageWaiters.removeFirst().resume()
      }
    }
    return try await body()
  }

  /// 実行中の再ログイン。Session 切れに複数の取得が同時に気づいても、ログインし直すのは1回だけにする
  /// （以前はそれぞれがログインし直し、互いの topFields を上書きして取得が失敗することがあった）。
  private var reloginTask: Task<Void, Error>?
  /// 最後にログインできた時刻
  private var lastLoginAt: Date?

  /// Session 切れのときの再ログイン。ほかの処理が再ログイン中ならその完了を待ち、
  /// 直前（数秒以内）にログインし直したばかりなら、ログインせずにそのままやり直させる。
  private func relogin(_ credentials: (id: String, password: String)) async throws {
    if let reloginTask {
      return try await reloginTask.value
    }
    if let lastLoginAt, Date().timeIntervalSince(lastLoginAt) < 10 {
      return
    }
    let task = Task { try await self.login(id: credentials.id, password: credentials.password) }
    reloginTask = task
    defer { reloginTask = nil }
    try await task.value
  }

  private var topFields: [String: String] = [:] // トップページの hidden 項目（ログイン時に1回読み取る）
  /// トップページの HTML。メニューの引数がコードに無い機能（成績など）は、ここのリンクから読み取る。
  private var topHTML = ""

  private enum Menu {
    static let attendance = "?category=ctg_km_002&\\?function=menu_km_008_mb&"
    static let studentCard = "?category=ctg_km_002&\\?function=menu_km_005_mb&"
    static let huntActivities = "?category=ctg_sh_001&\\?function=menu_sh_002_mb&"
    static let schoolEvents = "?category=ctg_sh_001&\\?function=menu_sh_005_mb&"
    static let timetable = "?category=ctg_km_002&\\?function=menu_km_007_mb&"
    /// 成績：トップページのリンクから見つからなかったときだけ、順に試す候補（学籍・出欠と同じ分類の近い番号）。
    static let gradeFallbacks = [
      "?category=ctg_km_002&\\?function=menu_km_006_mb&",
      "?category=ctg_km_002&\\?function=menu_km_009_mb&",
      "?category=ctg_km_002&\\?function=menu_km_004_mb&"
    ]
  }

  // MARK: 低レベルの処理

  private nonisolated static func hiddenFields(_ doc: Document) throws -> [String: String] {
    var d: [String: String] = [:]
    for e in try doc.select("input[type=hidden][name]") {
      try d[e.attr("name")] = try e.attr("value")
    }
    return d
  }

  /// HTML と、（リダイレクト後の）応答の URL を返す。フォームの相対的な action はこの URL を基準にする。
  private func post(_ url: URL, _ fields: [String: String]) async throws -> (html: String, url: URL?) {
    let (data, response) = try await postData(url, fields)
    return (String(decoding: data, as: UTF8.self), response.url)
  }

  /// フォームを送り、応答をそのまま返す（添付ファイルのように HTML でない応答を受け取るとき用）。
  private func postData(_ url: URL, _ fields: [String: String]) async throws -> (Data, URLResponse) {
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    let ok = CharacterSet(charactersIn:
      "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    req.httpBody = fields.map { k, v in
      "\(k.addingPercentEncoding(withAllowedCharacters: ok)!)="
        + "\(v.addingPercentEncoding(withAllowedCharacters: ok)!)"
    }.joined(separator: "&").data(using: .utf8)
    return try await session.data(for: req)
  }

  /// __doPostBack の再現：トップページの hidden 項目をすべて付けて POST する。
  private func menu(_ argument: String) async throws -> (html: String, url: URL?) {
    guard !topFields.isEmpty else { throw SchoolError.notLoggedIn }
    var f = topFields
    f["__EVENTTARGET"] = "ctl00$msp_asp_menu"
    f["__EVENTARGUMENT"] = argument
    return try await post(base.appendingPathComponent("TopSP.aspx"), f)
  }

  // MARK: 外部向けの API

  func login(id: String, password: String) async throws {
    let url = base.appendingPathComponent("loginSP.aspx")
    let (d, _) = try await session.data(from: url)
    var f = try Self.hiddenFields(SwiftSoup.parse(String(decoding: d, as: UTF8.self)))
    f["Login$UserName"] = id
    f["Login$Password"] = password
    f["Login$LoginButton"] = "ログイン"
    let result = try await post(url, f)

    // 判定は cookie だけに頼らない。前回のログインの `.ASPXAUTH` が残っていると、
    // パスワードが違っていても（学校側で変更された後でも）「ログインできた」と判定してしまうため。
    // ID・パスワードが違うと、学校はログインページをもう一度返す。
    let hasAuth = session.configuration.httpCookieStorage?
      .cookies(for: base)?.contains { $0.name == ".ASPXAUTH" } ?? false
    guard hasAuth, !Self.isLoginPage(result.html) else { throw SchoolError.loginFailed }

    let (t, _) = try await session.data(from: base.appendingPathComponent("TopSP.aspx"))
    let top = String(decoding: t, as: UTF8.self)
    // トップページの代わりにログインページが返ってきたら、ログインは成立していない
    guard !Self.isLoginPage(top) else { throw SchoolError.notLoggedIn }
    topHTML = top
    topFields = try Self.hiddenFields(SwiftSoup.parse(topHTML))
    lastLoginAt = Date()
  }

  /// 出欠を取得する。`range` があるときは、出欠ページで日付範囲の postback（`btn_検索`）を送る。
  /// Session 切れ（ログインページが返って解析に失敗）のときは、`credentials` で再ログインして1回だけやり直す。
  func attendance(
    range: (from: Date, through: Date)? = nil,
    retryWith credentials: (id: String, password: String)? = nil
  ) async throws -> [AttendanceDay] {
    do {
      return try await fetchAttendance(range: range)
    } catch SchoolError.parseFailed, SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.parseFailed }
      try await relogin(credentials)
      return try await fetchAttendance(range: range)
    }
  }

  private func fetchAttendance(range: (from: Date, through: Date)?) async throws -> [AttendanceDay] {
    let page = try await withPageLock {
      var page = try await menu(Menu.attendance)
      if let range {
        page = try await search(page, from: range.from, through: range.through)
      }
      return page
    }
    // 範囲を指定しない初期ページは未来の日付を含むことがあるので 40 日まで許す。範囲を指定したときは、範囲内の日付だけを採用する。
    return try await Self.parseAttendance(
      page.html, range: range, notAfter: range?.through ?? Date(), toleranceDays: range == nil ? 40 : 0)
  }

  /// 出欠ページに日付範囲を入れて `btn_検索` を送る。項目の実際の name はページから読む（ASP.NET が接頭辞を付けるため）。
  private func search(_ page: (html: String, url: URL?), from: Date, through: Date) async throws -> (html: String, url: URL?) {
    let (fields, action) = try await Self.prepareSearch(page.html, from: from, through: through)
    let pageURL = page.url ?? base.appendingPathComponent("student/AttendStudentSP.aspx")
    let url = action.isEmpty ? pageURL : (URL(string: action, relativeTo: pageURL)?.absoluteURL ?? pageURL)
    return try await post(url, fields)
  }

  /// 学生カルテのページから氏名・学籍番号などを読む。Session 切れのときは `attendance` と同じく再ログインしてやり直す。
  func studentCard(retryWith credentials: (id: String, password: String)? = nil) async throws -> StudentCardData {
    do {
      let page = try await menu(studentCardArgument)
      return try await Self.parseStudentCard(page.html)
    } catch SchoolError.parseFailed, SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.parseFailed }
      try await relogin(credentials)
      return try await Self.parseStudentCard(await menu(studentCardArgument).html)
    }
  }

  /// 学生カルテのメニューの引数。学科・学年によってメニューの番号が違うことがあるので、
  /// まずトップページのリンクの文字から探し、見つからなければ決め打ちの番号を使う。
  private var studentCardArgument: String {
    for title in ["学生カルテ", "カルテ", "学籍情報", "学生情報"] {
      if let found = Self.menuArgument(in: topHTML, titled: title) { return found }
    }
    return Menu.studentCard
  }

  // MARK: 学校からのお知らせ

  /// 今開いているお知らせの詳細ページ（添付のダウンロードは、このページのフォームから送る）
  private var noticePage: (key: String, html: String, url: URL?)?
  /// 掲示板の分類ごとの一覧のページ（詳細を開く postback は、このページのフォームから送る）
  private var noticeLists: [String: (html: String, url: URL)] = [:]

  /// 掲示板の分類（番号 → 名前）。ポータルの PC 版の掲示板のページ（information/Personal.aspx?cat=）
  nonisolated static let noticeCategories: [(code: String, name: String)] = [
    ("01", "連絡・スケジュール"), ("02", "事務局窓口・奨学金"), ("03", "学科からのお知らせ"),
    ("04", "キャリアセンター"), ("99", "システム管理者からのお知らせ")
  ]

  private func noticeListURL(_ code: String) -> URL {
    var components = URLComponents(url: base.deletingLastPathComponent().appendingPathComponent("information/Personal.aspx"),
                                   resolvingAgainstBaseURL: false)!
    components.queryItems = [URLQueryItem(name: "cat", value: code)]
    return components.url!
  }

  /// 掲示板の全分類の、掲載中のお知らせ（既読のものも含む）。分類ごとに一覧のページを1回ずつ読む。
  func schoolNotices(retryWith credentials: (id: String, password: String)? = nil) async throws -> [SchoolNotice] {
    do {
      return try await withPageLock { try await loadNoticeLists() }
    } catch SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.notLoggedIn }
      try await relogin(credentials)
      return try await withPageLock { try await loadNoticeLists() }
    }
  }

  private func loadNoticeLists() async throws -> [SchoolNotice] {
    var all: [SchoolNotice] = []
    for category in Self.noticeCategories {
      let url = noticeListURL(category.code)
      let (data, response) = try await session.data(from: url)
      let html = String(decoding: data, as: UTF8.self)
      guard !Self.isLoginPage(html) else { throw SchoolError.notLoggedIn }
      noticeLists[category.code] = (html, response.url ?? url)
      all += try Self.parseNoticeList(html, code: category.code, name: category.name)
    }
    return all
  }

  /// お知らせの詳細を開く（学校側でも既読になる）。
  func noticeDetail(_ notice: SchoolNotice,
                    retryWith credentials: (id: String, password: String)? = nil) async throws -> SchoolNoticeDetail {
    do {
      return try await withPageLock { try await openNotice(notice) }
    } catch SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.notLoggedIn }
      try await relogin(credentials)
      noticeLists = [:]
      return try await withPageLock { try await openNotice(notice) }
    }
  }

  private func openNotice(_ notice: SchoolNotice) async throws -> SchoolNoticeDetail {
    guard let target = notice.eventTarget, let code = notice.listCategory else { throw SchoolError.parseFailed }
    // 一覧のページを持っていなければ開き直す（行の番号は一覧の並びのまま）
    if noticeLists[code] == nil {
      let url = noticeListURL(code)
      let (data, response) = try await session.data(from: url)
      let html = String(decoding: data, as: UTF8.self)
      guard !Self.isLoginPage(html) else { throw SchoolError.notLoggedIn }
      noticeLists[code] = (html, response.url ?? url)
    }
    guard let list = noticeLists[code] else { throw SchoolError.parseFailed }
    let doc = try SwiftSoup.parse(list.html)
    var f = try Self.hiddenFields(doc)
    f["__EVENTTARGET"] = target
    f["__EVENTARGUMENT"] = ""
    let action = try doc.select("form").first()?.attr("action") ?? ""
    let url = action.isEmpty ? list.url : (URL(string: action, relativeTo: list.url)?.absoluteURL ?? list.url)
    let page = try await post(url, f)
    guard !Self.isLoginPage(page.html) else { throw SchoolError.notLoggedIn }
    let detail = try await Self.parseNoticeDetail(page.html, key: notice.key)
    noticePage = (notice.key, page.html, page.url ?? url)
    return detail
  }

  /// お知らせの添付ファイル。詳細ページの添付名のリンク（postback）を送り、返ってきたファイルを返す。
  func noticeAttachment(_ attachment: SchoolNoticeDetail.Attachment, of notice: SchoolNotice,
                        retryWith credentials: (id: String, password: String)? = nil) async throws -> Data {
    do {
      return try await withPageLock { try await downloadNoticeAttachment(attachment, of: notice) }
    } catch SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.notLoggedIn }
      try await relogin(credentials)
      noticePage = nil
      return try await withPageLock { try await downloadNoticeAttachment(attachment, of: notice) }
    }
  }

  private func downloadNoticeAttachment(_ attachment: SchoolNoticeDetail.Attachment,
                                        of notice: SchoolNotice) async throws -> Data {
    // 別のお知らせの詳細を開いている（またはまだ開いていない）ときは、先にこのお知らせを開き直す
    if noticePage?.key != notice.key {
      _ = try await openNotice(notice)
    }
    guard let page = noticePage else { throw SchoolError.parseFailed }
    let doc = try SwiftSoup.parse(page.html)
    var f = try Self.hiddenFields(doc)
    f["__EVENTTARGET"] = attachment.eventTarget
    f["__EVENTARGUMENT"] = ""
    let pageURL = page.url ?? noticeListURL(notice.listCategory ?? "01")
    let action = try doc.select("form").first()?.attr("action") ?? ""
    let url = action.isEmpty ? pageURL : (URL(string: action, relativeTo: pageURL)?.absoluteURL ?? pageURL)
    let (data, response) = try await postData(url, f)
    let type = ((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
    #if DEBUG
    print("[School] お知らせの添付 \(type) \(data.count / 1000)KB")
    #endif
    guard type.contains("text/html") else { return data }
    // HTML が返ってきたとき：ログインページなら Session 切れ。ファイルへのリンクや移動先が書いてあれば、そこから取る
    let html = String(decoding: data, as: UTF8.self)
    guard !Self.isLoginPage(html) else { throw SchoolError.notLoggedIn }
    if let file = Self.fileLink(in: html, relativeTo: response.url ?? url) {
      return try await fetchAttachment(file)
    }
    throw SchoolError.parseFailed
  }

  /// 「成績」ページの全科目。Session 切れのときは `credentials` で再ログインして1回だけやり直す。
  func grades(retryWith credentials: (id: String, password: String)? = nil) async throws -> [GradeRecord] {
    do {
      return try await fetchGrades()
    } catch SchoolError.parseFailed, SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.parseFailed }
      try await relogin(credentials)
      return try await fetchGrades()
    }
  }

  /// 成績のメニュー引数は、まずトップページの「成績」リンクから読み取り、無ければ候補を順に試す。
  /// 「科目名」の見出しがあるページだけを成績ページとして解析する。
  private func fetchGrades() async throws -> [GradeRecord] {
    guard !topFields.isEmpty else { throw SchoolError.notLoggedIn }
    var candidates: [String] = []
    if let found = Self.menuArgument(in: topHTML, titled: "成績") {
      candidates.append(found)
    }
    candidates += Menu.gradeFallbacks.filter { !candidates.contains($0) }
    for argument in candidates {
      let page = try await menu(argument)
      guard page.html.contains("科目") else { continue }
      #if DEBUG
      print("[School] 成績ページ: \(argument.contains("function=") ? String(argument.split(separator: "=").last ?? "") : argument)")
      #endif
      return try await Self.parseGrades(page.html)
    }
    throw SchoolError.parseFailed
  }

  /// 出欠「集計」の出席率（％）を、指定した日付範囲ごとに返す。学校が計算した値をそのまま使い、範囲に授業がなければ nil。
  ///
  /// 学校は同じセッションで「日別 / 集計」のどちらを表示中かを覚えているらしく、集計ページを開きっぱなしにして
  /// 後から検索すると、間に日別の取得が入った場合に日別ページが返って値が取れない。そのため、集計ページへ移ってから
  /// 全部の範囲を続けて検索する（途中に他の出欠の処理を挟ませない）。
  func attendanceRates(
    ranges: [(from: Date, through: Date)],
    retryWith credentials: (id: String, password: String)? = nil
  ) async throws -> [Double?] {
    do {
      return try await withPageLock { try await ratesLocked(ranges) }
    } catch SchoolError.parseFailed, SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.notLoggedIn }
      try await relogin(credentials)
      return try await withPageLock { try await ratesLocked(ranges) }
    }
  }

  private func ratesLocked(_ ranges: [(from: Date, through: Date)]) async throws -> [Double?] {
    var page = try await openSummaryPage()
    var results: [Double?] = []
    for range in ranges {
      let (fields, action) = try await Self.prepareSearch(page.html, from: range.from, through: range.through, scope: "uc_AttendCount")
      let pageURL = page.url ?? base.appendingPathComponent("student/AttendStudentSP.aspx")
      let url = action.isEmpty ? pageURL : (URL(string: action, relativeTo: pageURL)?.absoluteURL ?? pageURL)
      let result = try await post(url, fields)
      let value = try await Self.parseAttendanceRate(result.html)
      #if DEBUG
      let f = DateFormatter(); f.dateFormat = "yyyy/MM/dd"
      print("[School] 出席率 \(f.string(from: range.from))〜\(f.string(from: range.through)): \(value.map { String($0) } ?? "値なし")（HTML \(result.html.utf8.count / 1000)KB）")
      #endif
      results.append(value)
      page = result // 最新の VIEWSTATE と検証用の項目を、次の範囲の検索に引き継ぐ。
    }
    return results
  }

  /// 出欠ページを開き、「集計」リンクの postback で集計ページへ移る。
  private func openSummaryPage() async throws -> (html: String, url: URL?) {
    // 集計に移れず日別ページが返ってくることがあるので、数回まで取り直す
    for attempt in 0..<3 {
      let attendance = try await menu(Menu.attendance)
      let (fields, action) = try await Self.formBasics(attendance.html)
      var f = fields
      f["__EVENTTARGET"] = "ctl00$msp_asp_cph1$lb集計"
      f["__EVENTARGUMENT"] = ""
      let pageURL = attendance.url ?? base.appendingPathComponent("student/AttendStudentSP.aspx")
      let url = action.isEmpty ? pageURL : (URL(string: action, relativeTo: pageURL)?.absoluteURL ?? pageURL)
      let page = try await post(url, f)
      // 集計の検索欄（name に uc_AttendCount$ を含む入力）があれば集計ページ
      if page.html.contains("uc_AttendCount$txt_検索_日付01") {
        return page
      }
      #if DEBUG
      print("[School] 集計ページに移れませんでした（\(attempt + 1)回目、HTML \(page.html.utf8.count / 1000)KB）")
      #endif
      try? await Task.sleep(for: .milliseconds(400))
    }
    throw SchoolError.parseFailed
  }

  /// 添付ファイル（公欠申請の画像など）を取得する。ログインの Cookie で取得し、ログインページが返ってきたら
  /// （Session 切れ）`credentials` で再ログインして1回だけやり直す。
  func downloadAttachment(
    from url: URL,
    retryWith credentials: (id: String, password: String)? = nil
  ) async throws -> Data {
    do {
      return try await fetchAttachment(url)
    } catch SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.notLoggedIn }
      try await relogin(credentials)
      return try await fetchAttachment(url)
    }
  }

  private func fetchAttachment(_ url: URL) async throws -> Data {
    let (data, response) = try await session.data(from: url)
    let http = response as? HTTPURLResponse
    let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
    #if DEBUG
    print("[School] 添付 HTTP \(http?.statusCode ?? -1) \(type) \(data.count / 1000)KB \(url.lastPathComponent)")
    #endif
    guard let status = http?.statusCode, (200..<300).contains(status), !data.isEmpty else { throw SchoolError.parseFailed }
    // 画像や PDF ではなく HTML が返ってきたら、ログインページ（Session 切れ）とみなす
    if type.lowercased().contains("text/html") {
      throw SchoolError.notLoggedIn
    }
    return data
  }

  /// 学校の「イベント申込」一覧から、`title` と開催日 `date` が一致する説明会を開いて詳細を返す。
  /// 一覧にない（掲載が終わった）ときは nil。Session 切れのときは `credentials` で再ログインしてやり直す。
  func schoolEventDetail(
    title: String,
    date: String,
    retryWith credentials: (id: String, password: String)? = nil
  ) async throws -> SchoolEventDetail? {
    do {
      return try await fetchSchoolEventDetail(title: title, date: date)
    } catch SchoolError.parseFailed, SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.parseFailed }
      try await relogin(credentials)
      return try await fetchSchoolEventDetail(title: title, date: date)
    }
  }

  private func fetchSchoolEventDetail(title: String, date: String) async throws -> SchoolEventDetail? {
    guard let detail = try await withPageLock({ try await openSchoolEventDetailPage(title: title, date: date) }) else {
      #if DEBUG
      print("[School] 詳細: 一覧にタイトルが見つかりません（\(title)）")
      #endif
      return nil
    }
    do {
      return try await Self.parseSchoolEventDetail(detail.html, baseURL: detail.url)
    } catch {
      #if DEBUG
      print("[School] 詳細: ページを読めません url=\(detail.url.lastPathComponent) \(Self.formOutline(detail.html))")
      #endif
      throw error
    }
  }

  /// 「イベント申込」一覧から、`title` と開催日 `date` が一致する説明会の詳細ページを開く。
  /// 一致する行が無い、または複数ある（どれか決められない）ときは nil。
  private func openSchoolEventDetailPage(title: String, date: String) async throws -> (html: String, url: URL)? {
    let list = try await menu(Menu.schoolEvents)
    let found: (target: String, fields: [String: String], action: String)?
    do {
      found = try await Self.findSchoolEventLink(list.html, title: title, date: date)
    } catch {
      #if DEBUG
      print("[School] 詳細: 一覧ページを読めません url=\(list.url?.lastPathComponent ?? "-") login=\(Self.isLoginPage(list.html))")
      #endif
      throw error
    }
    guard let link = found else { return nil }
    var fields = link.fields
    fields["__EVENTTARGET"] = link.target
    fields["__EVENTARGUMENT"] = ""
    let pageURL = list.url ?? base.appendingPathComponent("recruit/EventSP.aspx")
    let url = Self.resolve(link.action, against: pageURL)
    let detail = try await post(url, fields)
    return (detail.html, detail.url ?? pageURL)
  }

  private nonisolated static func resolve(_ action: String, against pageURL: URL) -> URL {
    action.isEmpty ? pageURL : (URL(string: action, relativeTo: pageURL)?.absoluteURL ?? pageURL)
  }

  // MARK: 説明会の申込

  /// 説明会に申し込む。学校のページと同じ順に、詳細ページの「申込」ボタンを押し、確認ページがあれば1回だけ確定する。
  /// - 申込ボタンを押す前（一覧・詳細を開く段階）だけ、Session 切れのときに再ログインしてやり直す。
  ///   ボタンを押した後は、二重の申込を避けるため、どんな結果でもやり直さない。
  /// - 入力や選択が必要なページが出たら、何も確定せずに `.needsWebsite` を返す。
  /// - 本当に申し込めたかは、呼び出し側で「イベント申込」一覧の申込状況を取り直して確かめる。
  func applySchoolEvent(title: String, date: String, retryWith credentials: (id: String, password: String)? = nil) async throws -> SchoolEventApplyOutcome {
    try await withPageLock { try await applySchoolEventLocked(title: title, date: date, retryWith: credentials) }
  }

  private func applySchoolEventLocked(title: String, date: String, retryWith credentials: (id: String, password: String)?) async throws -> SchoolEventApplyOutcome {
    var page: (html: String, url: URL)?
    do {
      page = try await openSchoolEventDetailPage(title: title, date: date)
      if let html = page?.html, Self.isLoginPage(html) { throw SchoolError.notLoggedIn }
    } catch SchoolError.parseFailed, SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.notLoggedIn }
      try await relogin(credentials)
      page = try await openSchoolEventDetailPage(title: title, date: date)
    }
    guard let page else { return .needsWebsite("学校の一覧にこの説明会が見つかりませんでした。") }
    guard let form = try await Self.applyForm(page.html) else {
      return .needsWebsite("この説明会には申込ボタンがありません（受付期間外・満席・申込済みの可能性があります）。")
    }
    #if DEBUG
    print("[School] 申込: 詳細ページ \(Self.formOutline(page.html))")
    #endif
    let first = try await post(Self.resolve(form.action, against: page.url), form.fields)
    #if DEBUG
    print("[School] 申込: ボタン後のページ \(Self.formOutline(first.html))")
    #endif
    switch try await Self.applyStep(first.html) {
    case .done(let message): return .submitted(message: message)
    case .error(let message): return .rejected(message)
    case .needsInput: return .needsWebsite("この説明会は申込に入力や選択が必要です。学校サイトで申し込んでください。")
    case .unknown: return .submitted(message: nil)
    case .confirm(let fields, let action):
      // 確認ページ：確定ボタンを1回だけ押す
      let second = try await post(Self.resolve(action, against: first.url ?? page.url), fields)
      #if DEBUG
      print("[School] 申込: 確定後のページ \(Self.formOutline(second.html))")
      #endif
      switch try await Self.applyStep(second.html) {
      case .done(let message): return .submitted(message: message)
      case .error(let message): return .rejected(message)
      default: return .submitted(message: nil)
      }
    }
  }

  /// 時間割（月カレンダー）。表示中の月を先に返し、前月・次月は1か月ずつしか辿れないため、
  /// 「前へ」「次へ」の2本を並行して順に辿る（それぞれ、授業が6か月続けて無くなるまで。`monthsBack/Forward` は暴走を防ぐ上限）。
  /// 1か月取得できるたびに `onUpdate` で累計を回報する。
  func timetable(
    monthsBack: Int = 120,
    monthsForward: Int = 120,
    retryWith credentials: (id: String, password: String)? = nil,
    onUpdate: @escaping @Sendable @MainActor ([TimetableDay]) -> Void
  ) async throws -> [TimetableDay] {
    do {
      return try await fetchTimetable(monthsBack: monthsBack, monthsForward: monthsForward, onUpdate: onUpdate)
    } catch SchoolError.parseFailed, SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.parseFailed }
      try await relogin(credentials)
      return try await fetchTimetable(monthsBack: monthsBack, monthsForward: monthsForward, onUpdate: onUpdate)
    }
  }

  private func fetchTimetable(
    monthsBack: Int, monthsForward: Int,
    onUpdate: @escaping @Sendable @MainActor ([TimetableDay]) -> Void
  ) async throws -> [TimetableDay] {
    let top = try await menu(Menu.timetable)
    let first = try await Self.parseTimetable(top.html, url: top.url)
    var byDate: [Date: TimetableDay] = [:]
    func merge(_ page: ParsedTimetable) {
      for day in page.days where !day.lessons.isEmpty || byDate[day.date] == nil {
        byDate[day.date] = day
      }
    }
    func combined() -> [TimetableDay] {
      byDate.values.sorted { $0.date < $1.date }
    }

    merge(first)
    await onUpdate(combined())

    let (stream, continuation) = AsyncStream.makeStream(of: ParsedTimetable.self)
    await withTaskGroup(of: Void.self) { group in
      group.addTask {
        await withTaskGroup(of: Void.self) { chains in
          chains.addTask { await self.timetableChain(from: first, step: -1, count: monthsBack, into: continuation) }
          chains.addTask { await self.timetableChain(from: first, step: 1, count: monthsForward, into: continuation) }
        }
        continuation.finish()
      }
      for await page in stream {
        merge(page)
        await onUpdate(combined())
      }
    }
    return combined()
  }

  /// 前月（step = -1）または次月（step = 1）のボタンを順に押して、月ごとのページを `continuation` に流す。
  /// 授業のない月が6か月続いたら止める。途中のエラーはそこで打ち切る（取得済みの分は残す）。
  private func timetableChain(from page: ParsedTimetable, step: Int, count: Int, into continuation: AsyncStream<ParsedTimetable>.Continuation) async {
    var current = page
    var emptyStreak = 0
    for _ in 0..<count {
      guard let button = step < 0 ? current.prevButton : current.nextButton else { return }
      var fields = current.fields
      fields[button + ".x"] = "5"
      fields[button + ".y"] = "5"
      let pageURL = current.url ?? base.appendingPathComponent("student/TimeTableSP.aspx")
      let url = current.action.isEmpty ? pageURL : (URL(string: current.action, relativeTo: pageURL)?.absoluteURL ?? pageURL)
      guard let result = try? await post(url, fields),
            let parsed = try? await Self.parseTimetable(result.html, url: result.url) else { return }
      continuation.yield(parsed)
      emptyStreak = parsed.hasLessons ? 0 : emptyStreak + 1
      if emptyStreak >= 6 {
        return
      }
      current = parsed
    }
  }

  /// 「イベント申込」一覧（説明会ごとの申込状況）。Session 切れのときは `attendance` と同じく再ログインしてやり直す。
  func schoolEvents(retryWith credentials: (id: String, password: String)? = nil) async throws -> [SchoolEvent] {
    do {
      return try await Self.parseSchoolEvents(await menu(Menu.schoolEvents).html)
    } catch SchoolError.parseFailed, SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.parseFailed }
      try await relogin(credentials)
      return try await Self.parseSchoolEvents(await menu(Menu.schoolEvents).html)
    }
  }

  /// 就職活動入力ページの活動一覧（公欠申請の承認状況を含む）。1ページ目を取得したらすぐ `onUpdate` で知らせ、
  /// 残りのページはページ番号のボタンから並行して取得し、1ページ取るたびに、それまでの結果（ページ順）を知らせる。
  func huntActivities(
    retryWith credentials: (id: String, password: String)? = nil,
    onUpdate: @escaping @Sendable @MainActor ([HuntActivity]) -> Void
  ) async throws -> [HuntActivity] {
    do {
      return try await fetchHuntActivities(onUpdate: onUpdate)
    } catch SchoolError.parseFailed, SchoolError.notLoggedIn {
      guard let credentials else { throw SchoolError.parseFailed }
      try await relogin(credentials)
      return try await fetchHuntActivities(onUpdate: onUpdate)
    }
  }

  private struct HuntPage {
    let number: Int
    let html: String
    let url: URL?
    let items: [HuntActivity]
    let pager: [PagerButton]
    let fields: [String: String]
    let action: String
  }

  private func fetchHuntPage(from page: HuntPage, button: PagerButton, number: Int) async throws -> HuntPage {
    var f = page.fields
    f[button.name] = button.value
    let pageURL = page.url ?? base.appendingPathComponent("recruit/HuntSP.aspx")
    let url = page.action.isEmpty ? pageURL : (URL(string: page.action, relativeTo: pageURL)?.absoluteURL ?? pageURL)
    let result = try await post(url, f)
    let parsed = try await Self.parseHunt(result.html)
    return HuntPage(number: number, html: result.html, url: result.url, items: parsed.items, pager: parsed.pager,
                    fields: parsed.fields, action: parsed.action)
  }

  private func fetchHuntActivities(onUpdate: @escaping @Sendable @MainActor ([HuntActivity]) -> Void) async throws -> [HuntActivity] {
    #if DEBUG
    let began = Date()
    func lap(_ label: String) {
      print("[School] 就職活動 \(label): \(String(format: "%.1f", Date().timeIntervalSince(began)))s")
    }
    #endif
    let top = try await menu(Menu.huntActivities)
    #if DEBUG
    lap("menu済み（HTML \(top.html.utf8.count / 1000)KB）")
    #endif
    let firstParsed = try await Self.parseHunt(top.html)
    var current = HuntPage(number: 1, html: top.html, url: top.url, items: firstParsed.items, pager: firstParsed.pager,
                           fields: firstParsed.fields, action: firstParsed.action)

    var pages: [Int: [HuntActivity]] = [:]
    var seen = Set<String>()
    func add(_ page: HuntPage) -> Bool {
      let fresh = page.items.filter { seen.insert($0.key).inserted }
      guard !fresh.isEmpty else { return false }
      pages[page.number] = fresh
      return true
    }
    func combined() -> [HuntActivity] {
      pages.keys.sorted().flatMap { pages[$0] ?? [] }
    }

    _ = add(current)
    await onUpdate(combined())
    #if DEBUG
    lap("1ページ目を表示")
    #endif

    // ページ番号のボタン1組（例：2〜5）を並行して取得し、「...」で次の組へ進む
    for _ in 0..<12 {
      let targets = current.pager
        .compactMap { b in Int(b.value).map { (number: $0, button: b) } }
        .filter { $0.number > current.number }
      var fetched: [HuntPage] = []
      try await withThrowingTaskGroup(of: HuntPage.self) { group in
        for t in targets {
          group.addTask { try await self.fetchHuntPage(from: current, button: t.button, number: t.number) }
        }
        for try await page in group {
          if add(page) {
            await onUpdate(combined())
          }
          #if DEBUG
          lap("\(page.number)ページ目")
          #endif
          fetched.append(page)
        }
      }
      let last = fetched.max { $0.number < $1.number } ?? current
      guard let dots = last.pager.last(where: { $0.value == "..." }) else { break }
      let top = (last.pager.compactMap { Int($0.value) } + [last.number]).max() ?? last.number
      let next = try await fetchHuntPage(from: last, button: dots, number: top + 1)
      guard add(next) else { break }
      await onUpdate(combined())
      current = next
    }
    return combined()
  }

  // MARK: 就職活動の追加

  /// 追加フォームを開き、最初の状態を返す。
  func beginHuntEntry() async throws -> HuntFormState {
    let page = try await menu(Menu.huntActivities)
    let state = try await Self.parseHuntForm(page.html)
    huntPage = page
    return state
  }

  /// 項目の値が変わったら、学校のページの AutoPostBack と同じく postback を1回送り、更新後の状態を返す。
  func updateHuntEntry(_ values: HuntEntryValues, trigger: HuntField) async throws -> HuntFormState {
    guard let page = huntPage else { throw SchoolError.notLoggedIn }
    var fields = try await Self.collectFormState(page.html)
    Self.applyHuntValues(values, to: &fields)
    fields["__EVENTTARGET"] = Self.huntPrefix + trigger.controlName
    fields["__EVENTARGUMENT"] = ""
    let result = try await post(await formURL(page), fields)
    let state = try await Self.parseHuntForm(result.html)
    huntPage = result
    return state
  }

  /// 「追加」を押す。学校がエラーメッセージを返したら `SchoolError.rejected` を投げる。
  func submitHuntEntry(_ values: HuntEntryValues) async throws {
    guard let page = huntPage else { throw SchoolError.notLoggedIn }
    var fields = try await Self.collectFormState(page.html)
    Self.applyHuntValues(values, to: &fields)
    fields["__EVENTTARGET"] = ""
    fields["__EVENTARGUMENT"] = ""
    fields[Self.huntPrefix + "追加"] = "追加"

    let boundary = "----KICneo\(UUID().uuidString)"
    var req = try URLRequest(url: await formURL(page))
    req.httpMethod = "POST"
    req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    req.httpBody = Self.multipartBody(
      fields: fields,
      file: (Self.huntPrefix + "fileup添付", values.attachment),
      boundary: boundary)
    let (data, response) = try await session.data(for: req)
    let html = String(decoding: data, as: UTF8.self)
    let state = try await Self.parseHuntForm(html)
    huntPage = (html, response.url)
    if !state.message.isEmpty {
      throw SchoolError.rejected(state.message)
    }
  }

  private func formURL(_ page: (html: String, url: URL?)) async throws -> URL {
    let (_, action) = try await Self.formBasics(page.html)
    let pageURL = page.url ?? base.appendingPathComponent("recruit/HuntSP.aspx")
    return action.isEmpty ? pageURL : (URL(string: action, relativeTo: pageURL)?.absoluteURL ?? pageURL)
  }

  func logout() {
    topFields = [:]
    topHTML = ""
    lastLoginAt = nil
    session.configuration.httpCookieStorage?.cookies(for: base)?.forEach {
      session.configuration.httpCookieStorage?.deleteCookie($0)
    }
  }

  // MARK: 解析

  /// 解析は CPU を使うので actor の外で行う（複数の月の取得を本当に並行させるため）。
  /// HTML は1回だけ解析し、POST する項目とフォームの action を返す。
  /// `scope` を指定すると、名前にそれを含む欄だけを使う（日別と集計の両方の部品を含むページ対策）。
  @concurrent
  private static func prepareSearch(_ html: String, from: Date, through: Date, scope: String? = nil) async throws -> (fields: [String: String], action: String) {
    let doc = try SwiftSoup.parse(html)
    func input(_ key: String) throws -> Element? {
      try doc.select("input").array().first {
        guard let name = try? $0.attr("name") else { return false }
        return name.contains(key) && (scope.map { name.contains($0) } ?? true)
      }
    }
    guard let fromInput = try input("txt_検索_日付01"),
          let throughInput = try input("txt_検索_日付02"),
          let button = try input("btn_検索") else { throw SchoolError.parseFailed }

    var f = try hiddenFields(doc)
    try f[fromInput.attr("name")] = try format(from, like: fromInput.attr("value"), timeZone: AttendanceRatePeriod.calendar.timeZone)
    try f[throughInput.attr("name")] = try format(through, like: throughInput.attr("value"), timeZone: AttendanceRatePeriod.calendar.timeZone)
    let buttonValue = try button.attr("value")
    try f[button.attr("name")] = buttonValue.isEmpty ? "検索" : buttonValue
    return try (f, doc.select("form").first()?.attr("action") ?? "")
  }

  /// 「見出し + 値」の表の行、dt/dd、または id にキーワードを含む要素から、氏名と学籍番号を探す。
  @concurrent
  static func parseStudentCard(_ html: String) async throws -> StudentCardData {
    let doc = try SwiftSoup.parse(html)
    func clean(_ t: String) -> String {
      t.replacingOccurrences(of: "\u{3000}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// 見出しの比較用：全角の英数字（「ＮＯ」など）を半角にし、大文字にそろえ、空白を除く。
    /// 「学生NO」「学生No」「学生ＮＯ」「学籍 番号」のような表記ゆれでも同じ項目として扱うため。
    func normalized(_ label: String) -> String {
      label.precomposedStringWithCompatibilityMapping.uppercased()
        .filter { !$0.isWhitespace && $0 != ":" && $0 != "：" }
    }
    func isName(_ label: String) -> Bool {
      let l = normalized(label)
      return (l.contains("氏名") || l == "名前" || l == "学生名")
        && !l.contains("カナ") && !l.contains("フリガナ") && !l.contains("ふりがな") && !l.contains("ローマ")
    }
    /// 学籍番号の見出し。「学籍番号」「学籍NO」を優先する。
    /// 「学生NO」はクラスの中の出席番号（2桁ほど）のことがあるので、学籍番号が無いときだけ使う。
    func isNumber(_ label: String) -> Bool {
      let l = normalized(label)
      return ["学籍番号", "学生番号", "学籍NO"].contains { l.contains($0) }
    }
    func isWeakNumber(_ label: String) -> Bool {
      normalized(label).contains("学生NO")
    }
    var weakNumber: String?
    func isDepartment(_ label: String) -> Bool {
      label.contains("学科") && !label.contains("コード")
    }
    var name: String?
    var number: String?
    var department: String?
    // 学生カルテの各項目（見出しが完全に一致したものだけ。値が別の見出しなら、その項目は空）
    let known = Set(StudentCardData.cardLabels)
    var fields: [String: String] = [:]
    func take(_ label: String, _ value: String) {
      let v = clean(value)
      guard !v.isEmpty else { return }
      let key = clean(label)
      if known.contains(key), !known.contains(v), fields[key] == nil {
        fields[key] = v
      }
      if name == nil, isName(label) {
        name = v
      }
      if number == nil, isNumber(label) {
        number = v
      } else if weakNumber == nil, isWeakNumber(label) {
        weakNumber = v
      }
      if department == nil, isDepartment(label), !isDepartment(v) {
        department = v
      }
    }
    for tr in try doc.select("tr") {
      let cells = try tr.children().array()
        .filter { ["th", "td"].contains($0.tagName()) }
        .map { try clean($0.text()) }
      for i in 0..<max(cells.count - 1, 0) {
        take(cells[i], cells[i + 1])
      }
    }
    for dt in try doc.select("dt") {
      if let dd = try dt.nextElementSibling(), dd.tagName() == "dd" {
        try take(clean(dt.text()), dd.text())
      }
    }
    for e in try doc.select("[id]") {
      let id = e.id()
      if name == nil, isName(id) {
        try take("氏名", e.text())
      }
      if number == nil, isNumber(id) {
        try take("学籍番号", e.text())
      }
      if department == nil, isDepartment(id) {
        try take("学科", e.text())
      }
    }
    if number == nil { number = weakNumber }
    guard let name, let number else {
      #if DEBUG
      // th の見出しと id だけを出す（個人のデータの値は出さない）。ページの構造の確認用。
      let labels = (try? doc.select("th, dt").array().map { clean((try? $0.text()) ?? "") }) ?? []
      let ids = (try? doc.select("[id]").array().map { $0.id() }.filter { !$0.hasPrefix("__") }) ?? []
      print("[School] 学生証を読み取れませんでした。labels: \(labels.prefix(40)) ids: \(ids.prefix(60))")
      #endif
      throw SchoolError.parseFailed
    }
    return StudentCardData(displayName: name, studentNumber: number, department: fields["学科"] ?? department,
      fields: fields)
  }

  /// postback のリンクの対象（`__doPostBack('対象','')` の「対象」）
  nonisolated static func postbackTarget(_ href: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: #"__doPostBack\(\s*'([^']+)'"#),
          let match = regex.firstMatch(in: href, range: NSRange(href.startIndex..., in: href)),
          let range = Range(match.range(at: 1), in: href) else { return nil }
    return String(href[range])
  }

  /// 掲示板の一覧の表（gv_info）から、お知らせを読む。1行に タイトル・掲載者・掲載開始日・掲載終了日・未読処理。
  nonisolated static func parseNoticeList(_ html: String, code: String, name: String) throws -> [SchoolNotice] {
    let doc = try SwiftSoup.parse(html)
    func text(_ row: Element, _ suffix: String) -> String {
      guard let element = try? row.select("[id$=\(suffix)]").first(), let value = try? element.text() else { return "" }
      return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var notices: [SchoolNotice] = []
    for link in try doc.select("table[id*=gv_info] a[id$=_title]") {
      guard let target = postbackTarget(try link.attr("href")) else { continue }
      guard let row = link.parents().array().first(where: { $0.tagName() == "tr" }) else { continue }
      let title = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
      // 「既読にする」のリンクがあれば、学校側ではまだ未読
      let readToggle = text(row, "_lb_未読処理")
      notices.append(SchoolNotice(
        section: name,
        title: title,
        category: name,
        date: text(row, "_Label4"),
        poster: text(row, "掲示者"),
        hasAttachment: (try? row.select("img[id$=_img_添付]").array().isEmpty) == false,
        eventTarget: target,
        listCategory: code,
        endDate: text(row, "_Label5"),
        unreadOnServer: readToggle.contains("既読")))
    }
    return notices
  }

  /// お知らせの詳細（「掲示内容」）。見出し（掲載者・掲載開始日・…）の次にある値を読む。
  /// 詳細の本文は改行を残す。添付は「添付名」のリンク（postback）。
  @concurrent
  static func parseNoticeDetail(_ html: String, key: String) async throws -> SchoolNoticeDetail {
    let doc = try SwiftSoup.parse(html)
    let headings: Set<String> = ["掲示内容", "掲載者", "掲示者", "掲載開始日", "掲示開始日", "掲載終了日", "掲示終了日",
                                 "タイトル", "詳細", "内容", "添付ファイル"]
    // frm_info の中の文字の要素（見出しと値が交互に並ぶ）。無ければページ全体の span から探す
    var spans = try doc.select("[id*=frm_info] span").array()
    if spans.isEmpty { spans = try doc.select("span[id]").array() }
    var values: [String: String] = [:]
    var index = 0
    while index < spans.count {
      let label = try spans[index].text().trimmingCharacters(in: .whitespacesAndNewlines)
      if headings.contains(label), index + 1 < spans.count {
        let next = spans[index + 1]
        let nextText = try next.text().trimmingCharacters(in: .whitespacesAndNewlines)
        if !headings.contains(nextText) {
          values[label] = label == "詳細" || label == "内容" ? multilineText(next) : nextText
          index += 2
          continue
        }
      }
      index += 1
    }
    let title = values["タイトル"] ?? ""
    guard !title.isEmpty || values["詳細"] != nil else {
      #if DEBUG
      let ids = (try? doc.select("[id]").array().map { $0.id() }.filter { !$0.hasPrefix("__") }) ?? []
      print("[School] お知らせの詳細を読み取れませんでした。ids: \(ids.prefix(60))")
      #endif
      throw SchoolError.parseFailed
    }
    let attachments = try doc.select("a[id*=添付][href*=__doPostBack]").array().compactMap { link -> SchoolNoticeDetail.Attachment? in
      guard let target = postbackTarget(try link.attr("href")) else { return nil }
      let name = try link.text().trimmingCharacters(in: .whitespacesAndNewlines)
      return name.isEmpty ? nil : SchoolNoticeDetail.Attachment(name: name, eventTarget: target)
    }
    return SchoolNoticeDetail(
      key: key,
      poster: values["掲載者"] ?? values["掲示者"] ?? "",
      startDate: values["掲載開始日"] ?? values["掲示開始日"] ?? "",
      endDate: values["掲載終了日"] ?? values["掲示終了日"] ?? "",
      title: title,
      body: values["詳細"] ?? values["内容"] ?? "",
      attachments: attachments)
  }

  /// 要素の文字を、<br> や段落の区切りを改行にして取り出す（SwiftSoup の text() は改行をつぶすため）
  nonisolated static func multilineText(_ element: Element) -> String {
    var out = ""
    func walk(_ node: Node) {
      if let text = node as? TextNode {
        out += text.getWholeText().replacingOccurrences(of: "\n", with: " ")
      } else if let el = node as? Element {
        let tag = el.tagName()
        if tag == "br" { out += "\n"; return }
        let block = ["p", "div", "li", "tr"].contains(tag)
        if block, !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        for child in el.getChildNodes() { walk(child) }
        if block, !out.hasSuffix("\n") { out += "\n" }
      }
    }
    walk(element)
    // 行ごとの前後の空白を除き、3行以上の空行は2行にまとめる
    let lines = out.replacingOccurrences(of: "\u{00A0}", with: " ").components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
    var result: [String] = []
    for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
    return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// 添付のリンクを押したとき、ファイルではなく HTML が返ってきた場合に、その中のファイルへのリンク・移動先を探す
  nonisolated static func fileLink(in html: String, relativeTo base: URL) -> URL? {
    let patterns = [#"(?:window\.open|location\.href\s*=|location\.replace)\(?\s*['"]([^'"]+)['"]"#,
                    #"href=['"]([^'"]+\.(?:jpe?g|png|gif|pdf|docx?|xlsx?|pptx?|zip))['"]"#]
    for pattern in patterns {
      guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
            let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
            let range = Range(match.range(at: 1), in: html) else { continue }
      let raw = String(html[range]).replacingOccurrences(of: "&amp;", with: "&")
      if let url = URL(string: raw, relativeTo: base)?.absoluteURL { return url }
    }
    return nil
  }

  /// トップページのメニューで、文字が `title` のリンクの `__doPostBack('…','引数')` の引数を返す。
  /// 文字が完全に一致するものを優先し、無ければ `title` を含むものを使う。
  nonisolated static func menuArgument(in html: String, titled title: String) -> String? {
    guard !html.isEmpty, let doc = try? SwiftSoup.parse(html),
          let links = try? doc.select("a").array(),
          let pattern = try? NSRegularExpression(pattern: #"__doPostBack\(\s*'[^']*'\s*,\s*'([^']*)'"#) else { return nil }
    func argument(_ link: Element) -> String? {
      for attribute in ["href", "onclick"] {
        let js = (try? link.attr(attribute)) ?? ""
        let range = NSRange(js.startIndex..., in: js)
        if let match = pattern.firstMatch(in: js, range: range), let r = Range(match.range(at: 1), in: js) {
          // JavaScript の文字列の中では「\」が「\\」と書かれている
          return String(js[r]).replacingOccurrences(of: "\\\\", with: "\\")
        }
      }
      return nil
    }
    func text(_ link: Element) -> String {
      ((try? link.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let exact = links.first(where: { text($0) == title }), let value = argument(exact) { return value }
    return links.first(where: { text($0).contains(title) }).flatMap(argument)
  }

  /// 成績ページの表。見出し行（「科目名」を含む行）から列の位置を決めるので、列の並びが変わっても読める。
  /// 表の形でないとき（行ごとに `..._lbl科目名` のような id を持つ形）にも対応する。
  @concurrent
  static func parseGrades(_ html: String) async throws -> [GradeRecord] {
    let doc = try SwiftSoup.parse(html)
    func clean(_ t: String) -> String {
      t.replacingOccurrences(of: "\u{3000}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // 各項目の見出し（候補）。前のものほど優先。
    let fields: [[String]] = [["履修年度", "年度"], ["期間", "学期"], ["科目名", "科目"], ["区分"], ["単位", "単位数"],
      ["前期点数"], ["前期評価"], ["後期点数"], ["後期評価"]]
    func record(_ value: (Int) -> String) -> GradeRecord? {
      let subject = value(2)
      guard !subject.isEmpty else { return nil }
      return GradeRecord(year: value(0), term: value(1), subject: subject, category: value(3), credits: value(4),
        firstScore: value(5), firstGrade: value(6), secondScore: value(7), secondGrade: value(8))
    }
    // 1) 見出し行のある表（入れ子の表の外側は使わない）
    for table in try doc.select("table") {
      guard try table.getElementsByTag("table").size() == 1 else { continue }
      let rows = try table.select("tr").array()
      // 結合したセル（colspan）は、その数だけ同じ文字を並べて列の位置をそろえる
      let cellTexts: [[String]] = try rows.map { row in
        try row.children().array().flatMap { cell -> [String] in
          let span = max(1, Int(try cell.attr("colspan")) ?? 1)
          return Array(repeating: clean(try cell.text()), count: span)
        }
      }
      guard let headerIndex = cellTexts.firstIndex(where: { $0.contains { $0.contains("科目") } }) else { continue }
      var headers = cellTexts[headerIndex].map { $0.filter { !$0.isWhitespace } }
      var dataStart = headerIndex + 1
      // 見出しが2段（上の段「前期」「後期」、下の段「点数」「評価」）なら、上と下をつなげて1つの見出しにする
      if dataStart < cellTexts.count {
        let next = cellTexts[dataStart].map { $0.filter { !$0.isWhitespace } }
        let isSubHeader = next.contains { $0.contains("点") || $0.contains("評価") }
          && !next.contains { GradeRecord.number($0) != nil }
        if isSubHeader {
          // 下の段は、上の段で1列だけの見出し（科目名など）を飛ばして並んでいる
          var subs = next[...]
          headers = headers.enumerated().map { index, top in
            let spanned = headers.filter { $0 == top }.count > 1
            guard spanned, let sub = subs.first else { return top }
            subs = subs.dropFirst()
            return top + sub
          }
          dataStart += 1
        }
      }
      func column(_ index: Int) -> Int? {
        // 前期・後期の点数と評価は、見出しに「前期/後期」と「点/評価」の両方を含む列
        let term: String? = [5, 6].contains(index) ? "前期" : ([7, 8].contains(index) ? "後期" : nil)
        if let term {
          let kind = index % 2 == 1 ? "点" : "評価"
          return headers.firstIndex { $0.contains(term) && $0.contains(kind) }
        }
        let names = fields[index]
        for name in names { if let i = headers.firstIndex(of: name) { return i } }
        for name in names { if let i = headers.firstIndex(where: { $0.contains(name) }) { return i } }
        return nil
      }
      let columns = (0..<fields.count).map(column)
      guard columns[2] != nil else { continue }
      #if DEBUG
      // 見出しの文字と、どの列に対応させたかだけを出す（成績の値は出さない）
      print("[School] 成績の見出し: \(headers) → 列: \(columns.map { $0.map(String.init) ?? "-" })")
      #endif
      return cellTexts[dataStart...].compactMap { cells in
        record { index in
          guard let c = columns[index], c < cells.count else { return "" }
          return cells[c]
        }
      }
    }
    // 2) 行ごとに id で項目を持つ形（例: ..._ctl02_lbl科目名）
    let subjects = try doc.select("[id$=科目名]").array()
    if !subjects.isEmpty {
      return subjects.compactMap { element in
        let prefix = String(element.id().dropLast("科目名".count))
        return record { index in
          for name in fields[index] {
            if let e = try? doc.getElementById(prefix + name) { return clean((try? e.text()) ?? "") }
          }
          return ""
        }
      }
    }
    #if DEBUG
    // 値（個人の成績）は出さず、見出しと id だけを出して、ページの形を確認できるようにする
    let labels = (try? doc.select("th").array().map { clean((try? $0.text()) ?? "") }) ?? []
    let ids = (try? doc.select("[id]").array().map { $0.id() }.filter { !$0.hasPrefix("__") }) ?? []
    print("[School] 成績を読み取れませんでした。labels: \(labels.prefix(30)) ids: \(ids.prefix(60))")
    #endif
    throw SchoolError.parseFailed
  }

  /// 一覧の各行は `..._grvイベント_ctlNN_lblタイトル` などの id を持つ。タイトルの id から行の接頭辞を求める。
  @concurrent
  static func parseSchoolEvents(_ html: String) async throws -> [SchoolEvent] {
    let doc = try SwiftSoup.parse(html)
    guard try !doc.select("[id$=\"grvイベント\"]").isEmpty() else { throw SchoolError.parseFailed }
    func text(_ prefix: String, _ field: String) throws -> String {
      try (doc.getElementById(prefix + field)?.text() ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var events: [SchoolEvent] = []
    for title in try doc.select("[id$=_lblタイトル]") {
      let prefix = String(title.id().dropLast("lblタイトル".count))
      let from = try text(prefix, "lbl時間01"), to = try text(prefix, "lbl時間02")
      let time = [from, to].filter { !$0.isEmpty }.joined(separator: "〜")
      try events.append(SchoolEvent(
        title: title.text().trimmingCharacters(in: .whitespacesAndNewlines),
        status: text(prefix, "lblイベント申込状況"),
        date: [text(prefix, "lbl開催日"), time].filter { !$0.isEmpty }.joined(separator: " "),
        applyPeriod: text(prefix, "lbl申込期間")))
    }
    return events
  }

  /// 集計の結果行（`grv出欠`）の出席率。行がない・数値でない場合は nil。
  @concurrent
  static func parseAttendanceRate(_ html: String) async throws -> Double? {
    let doc = try SwiftSoup.parse(html)
    guard let grid = try doc.select("[id*=uc_AttendCount][id$=grv出欠]").first() else { throw SchoolError.parseFailed }
    let fields = try grid.select("[id$=lbl出席率]").array()
    guard fields.count <= 1 else { throw SchoolError.parseFailed }
    guard let field = fields.first else { return nil }
    let raw = try field.text()
    let normalized = (raw.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? raw)
      .replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    if ["", "-", "--", "—", "未集計"].contains(normalized) { return nil }
    guard normalized.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
      let value = Double(normalized), value.isFinite, (0...100).contains(value) else { throw SchoolError.parseFailed }
    return value
  }

  /// 一覧から、タイトルと開催日（日付・時刻の数字）がどちらも一致する行のリンクを探す。
  /// 同じタイトルの説明会が別の日にもあるため、タイトルだけでは決めない（違う回に申し込まないため）。
  /// 一致する行が1つに決まらないときは nil。
  @concurrent
  static func findSchoolEventLink(_ html: String, title: String, date: String) async throws -> (target: String, fields: [String: String], action: String)? {
    let doc = try SwiftSoup.parse(html)
    guard try !doc.select("[id$=\"grvイベント\"]").isEmpty() else { throw SchoolError.parseFailed }
    func key(_ s: String) -> String {
      s.filter { $0.isLetter || $0.isNumber }
    }
    func text(_ id: String) -> String {
      ((try? doc.getElementById(id)?.text()) ?? nil) ?? ""
    }
    var targets: [String] = []
    for a in try doc.select("a[id$=_lblタイトル]") where try key(a.text()) == key(title) {
      let prefix = String(a.id().dropLast("lblタイトル".count))
      let rowDate = text(prefix + "lbl開催日") + text(prefix + "lbl時間01") + text(prefix + "lbl時間02")
      guard dateKey(rowDate) == dateKey(date) else { continue }
      let blob = try a.attr("href") + " " + a.attr("onclick")
      guard let range = blob.range(of: #"__doPostBack\('([^']*)'"#, options: .regularExpression) else { continue }
      targets.append(String(String(blob[range]).replacingOccurrences(of: "__doPostBack('", with: "").dropLast()))
    }
    guard targets.count == 1, let target = targets.first else {
      #if DEBUG
      if targets.count > 1 { print("[School] 詳細: タイトルと開催日が同じ行が\(targets.count)件あり、決められません") }
      #endif
      return nil
    }
    return try (target, hiddenFields(doc), doc.select("form").first()?.attr("action") ?? "")
  }

  /// 開催日の比較用。数字だけを残す（「26/11/05(木) 11:20〜12:10」と「26/11/05(木) 11:20～12:10」を同じとみなす）。
  nonisolated static func dateKey(_ text: String) -> String {
    let normalized = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
    return normalized.filter { $0.isASCII && $0.isNumber }
  }

  nonisolated static func isLoginPage(_ html: String) -> Bool {
    html.contains("Login$UserName") || html.contains("Login_UserName")
  }

  /// ブラウザがフォームを送るときと同じ値（hidden・入力欄の今の値・選ばれている選択肢）。ボタンの値は含めない。
  nonisolated static func formValues(_ doc: Document) throws -> [String: String] {
    var values = try hiddenFields(doc)
    for input in try doc.select("input[name]") {
      let type = try input.attr("type").lowercased()
      let name = try input.attr("name")
      switch type {
      case "hidden", "submit", "button", "image", "reset", "file": continue
      case "checkbox", "radio": if input.hasAttr("checked") { values[name] = try input.attr("value") }
      default: values[name] = try input.attr("value")
      }
    }
    for select in try doc.select("select[name]") {
      let chosen = try select.select("option[selected]").first() ?? select.select("option").first()
      if let chosen { values[try select.attr("name")] = try chosen.attr("value") }
    }
    for area in try doc.select("textarea[name]") {
      values[try area.attr("name")] = try area.text()
    }
    return values
  }

  /// 詳細ページの「申込」ボタン（id が `btn申込` で終わるもの）を押すときに送る値。押せないときは nil。
  @concurrent
  static func applyForm(_ html: String) async throws -> (fields: [String: String], action: String)? {
    let doc = try SwiftSoup.parse(html)
    guard let button = try doc.select("input[id$=btn申込], button[id$=btn申込], a[id$=btn申込]").first(),
          !button.hasAttr("disabled") else { return nil }
    return (try pressFields(button, in: doc), try doc.select("form").first()?.attr("action") ?? "")
  }

  /// ボタンを押したときにブラウザが送る値。ASP.NET のボタンは書き方で送り方が違う：
  /// - `__doPostBack('名前','引数')` で送るもの（LinkButton・UseSubmitBehavior=false のボタン）→ `__EVENTTARGET` に名前
  /// - 画像のボタン（type=image）→ `名前.x` / `名前.y`（押した位置）
  /// - ふつうの送信ボタン → `名前=表示文字`
  nonisolated static func pressFields(_ button: Element, in doc: Document) throws -> [String: String] {
    var fields = try formValues(doc)
    let name = try button.attr("name")
    let type = try button.attr("type").lowercased()
    let script = try button.attr("href") + " " + button.attr("onclick")
    if let postBack = doPostBack(in: script) {
      fields["__EVENTTARGET"] = postBack.target
      fields["__EVENTARGUMENT"] = postBack.argument
    } else if type == "image", !name.isEmpty {
      fields[name + ".x"] = "10"
      fields[name + ".y"] = "10"
    } else if !name.isEmpty {
      fields[name] = try button.attr("value")
      fields["__EVENTTARGET"] = ""
      fields["__EVENTARGUMENT"] = ""
    }
    return fields
  }

  /// `__doPostBack('対象','引数')` の対象と引数（JavaScript の「\\」は「\」に戻す）
  nonisolated static func doPostBack(in script: String) -> (target: String, argument: String)? {
    guard let pattern = try? NSRegularExpression(pattern: #"__doPostBack\(\s*'([^']*)'\s*,\s*'([^']*)'"#),
          let match = pattern.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
          let target = Range(match.range(at: 1), in: script),
          let argument = Range(match.range(at: 2), in: script) else { return nil }
    func unescape(_ s: Substring) -> String { String(s).replacingOccurrences(of: "\\\\", with: "\\") }
    return (unescape(script[target]), unescape(script[argument]))
  }

  enum ApplyStep: Sendable {
    case done(String?)
    case error(String)
    case confirm(fields: [String: String], action: String)
    case needsInput
    case unknown
  }

  /// 申込ボタン（または確定ボタン）を押した後のページを読み、次に何をするかを決める。
  @concurrent
  static func applyStep(_ html: String) async throws -> ApplyStep {
    let doc = try SwiftSoup.parse(html)
    func clean(_ t: String) -> String {
      t.replacingOccurrences(of: "\u{3000}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    // 1) 完了の文言
    let successWords = ["申込みました", "申し込みました", "申込が完了", "申込を受け付け", "受け付けました", "申込完了", "登録しました"]
    for element in try doc.select("span, label, div, p, td") where element.children().isEmpty() {
      let text = clean(try element.text())
      if successWords.contains(where: { text.contains($0) }) { return .done(text) }
    }
    // 2) 学校が出したエラーの文言（id に Err / Msg / メッセージ / エラー を含む要素）
    for element in try doc.select("[id]") {
      let id = element.id()
      guard ["Err", "err", "Msg", "msg", "メッセージ", "エラー"].contains(where: { id.contains($0) }) else { continue }
      let text = clean(try element.text())
      if !text.isEmpty { return .error(text) }
    }
    // 3) 入力や選択が必要なページ（アプリでは中身を決められないので、学校サイトへ）
    let editable = try doc.select("input[type=text], input[type=radio], input[type=checkbox], input[type=number], textarea, select")
      .array().filter { !$0.hasAttr("readonly") && !$0.hasAttr("disabled") }
    // 4) 確認ページ：確定する送信ボタンが1つだけあるとき
    let confirmWords = ["確定", "はい", "OK", "ＯＫ", "申込", "申し込む", "登録", "送信"]
    let cancelWords = ["戻る", "キャンセル", "取消", "取り消", "いいえ", "閉じる"]
    let buttons = try doc.select("input[type=submit][name], input[type=image][name], input[type=button][onclick*=__doPostBack], button[name], a[href*=__doPostBack]").array().filter { button in
      let label = (try? button.attr("value")).flatMap { $0.isEmpty ? nil : $0 } ?? ((try? button.text()) ?? "")
      return confirmWords.contains { label.contains($0) } && !cancelWords.contains { label.contains($0) }
        && !button.hasAttr("disabled")
    }
    if !editable.isEmpty, !buttons.isEmpty { return .needsInput }
    if buttons.count == 1, let button = buttons.first {
      return .confirm(fields: try pressFields(button, in: doc), action: try doc.select("form").first()?.attr("action") ?? "")
    }
    return .unknown
  }

  #if DEBUG
  /// ページの形だけ（ボタンの id と表示文字、入力欄の種類、メッセージ欄の id）。入力値や個人の情報は出さない。
  nonisolated static func formOutline(_ html: String) -> String {
    guard let doc = try? SwiftSoup.parse(html) else { return "解析できません" }
    let buttons = (try? doc.select("input[type=submit], input[type=button], input[type=image], button, a[href*=__doPostBack]").array()
      .filter { !$0.id().contains("msp_asp_menu") }
      .map { element -> String in
        let label = ((try? element.attr("value")).flatMap { $0.isEmpty ? nil : $0 }) ?? ((try? element.text()) ?? "")
        let kind = doPostBack(in: ((try? element.attr("href")) ?? "") + " " + ((try? element.attr("onclick")) ?? "")) != nil
          ? "postback" : ((try? element.attr("type")) ?? element.tagName())
        return "\(element.id())[\(kind)]=\(label)"
      }) ?? []
    let inputs = (try? doc.select("input:not([type=hidden]):not([type=submit]), textarea, select").array().map {
      "\($0.tagName()):\((try? $0.attr("type")) ?? "")#\($0.id())"
    }) ?? []
    let messages = (try? doc.select("[id*=Msg], [id*=msg], [id*=Err], [id*=メッセージ]").array().map { $0.id() }) ?? []
    return "buttons: \(buttons.prefix(12)) inputs: \(inputs.prefix(12)) messages: \(messages.prefix(8)) login: \(isLoginPage(html))"
  }
  #endif

  /// 詳細ページ（`..._frmEvent_lbl〜`）を読む。「内容」は `<br>` を改行に、`<a>` をリンクにして区間に分ける。
  @concurrent
  static func parseSchoolEventDetail(_ html: String, baseURL: URL) async throws -> SchoolEventDetail {
    let doc = try SwiftSoup.parse(html)
    guard try !doc.select("[id$=frmEvent]").isEmpty() else { throw SchoolError.parseFailed }
    func text(_ field: String) throws -> String {
      try (doc.select("[id$=frmEvent_\(field)]").first()?.text() ?? "")
        .replacingOccurrences(of: "\u{3000}", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var runs: [SchoolEventDetail.Run] = []
    func walk(_ node: Node, link: URL?) {
      if let textNode = node as? TextNode {
        let t = textNode.getWholeText().replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        if !t.isEmpty {
          runs.append(.init(text: t, url: link))
        }
      } else if let element = node as? Element {
        if element.tagName() == "br" {
          runs.append(.init(text: "\n", url: nil)); return
        }
        var next = link
        if element.tagName() == "a", let href = try? element.attr("href"), !href.hasPrefix("javascript") {
          next = URL(string: href, relativeTo: baseURL)?.absoluteURL
        }
        for child in element.getChildNodes() {
          walk(child, link: next)
        }
      }
    }
    if let content = try doc.select("[id$=frmEvent_lbl内容]").first() {
      for child in content.getChildNodes() {
        walk(child, link: nil)
      }
    }
    return try SchoolEventDetail(
      title: text("lblタイトル"),
      kind: text("lbl種別"),
      date: text("lbl開催日時"),
      applyPeriod: text("lbl申込期間"),
      capacity: text("lbl定員"),
      remaining: text("lbl残り定員数表示"),
      room: text("lbl教室名"),
      publishFrom: text("lbl掲示開始日"),
      publishTo: text("lbl掲示終了日"),
      status: text("lblイベント申込状況"),
      content: runs,
      attachments: doc.select("[id$=lbtn_添付名]").array().map { try $0.text().trimmingCharacters(in: .whitespacesAndNewlines) },
      hasApplyButton: !doc.select("input[id$=btn申込], button[id$=btn申込], a[id$=btn申込]").isEmpty())
  }

  struct ParsedTimetable: Sendable {
    let days: [TimetableDay]
    let hasLessons: Bool
    let fields: [String: String]
    let action: String
    let url: URL?
    let prevButton: String?
    let nextButton: String?
  }

  /// `span.year-month` の月と、`table.calendar` の各セル（`span.schedule-date` + `li.schedule-list-item`）を読む。
  /// 先頭の週にある大きい日付は前月、末尾の週にある小さい日付は翌月のセル。
  @concurrent
  static func parseTimetable(_ html: String, url: URL?) async throws -> ParsedTimetable {
    let doc = try SwiftSoup.parse(html)
    guard let calendarTable = try doc.select("table.calendar").first() else { throw SchoolError.parseFailed }
    let numbers = try (doc.select("span.year-month").first()?.text() ?? "")
      .split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    guard numbers.count >= 2 else { throw SchoolError.parseFailed }
    let (year, month) = (numbers[0], numbers[1])

    let cal = AttendanceRatePeriod.calendar
    let weeks = try calendarTable.select("tr").array().filter { try !$0.select("td.calendar-cell").isEmpty() }
    var days: [TimetableDay] = []
    // 表示中の月そのものに授業があるか。ページの端には前月・翌月の日付も出るので、それは数えない。
    var ownMonthHasLessons = false
    for (weekIndex, week) in weeks.enumerated() {
      for cell in try week.select("td.calendar-cell") {
        guard let day = try Int(cell.select("span.schedule-date").first()?.text().trimmingCharacters(in: .whitespaces) ?? "")
        else { continue }
        var cellMonth = month
        if weekIndex == 0, day > 7 {
          cellMonth -= 1
        }
        if weekIndex >= weeks.count - 2, day < 15 {
          cellMonth += 1
        }
        guard let date = cal.date(from: DateComponents(year: year, month: cellMonth, day: day)) else { continue }
        let lessons: [TimetableLesson] = try cell.select("li.schedule-list-item").array().map { li in
          let raw = try li.attr("data-overall").isEmpty ? li.text() : li.attr("data-overall")
          let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
          if let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) {
            return TimetableLesson(period: String(text[..<colon]).trimmingCharacters(in: .whitespaces),
                                   name: String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
          }
          return TimetableLesson(period: "", name: text)
        }
        if cellMonth == month, !lessons.isEmpty { ownMonthHasLessons = true }
        days.append(TimetableDay(date: cal.startOfDay(for: date), lessons: lessons))
      }
    }
    func button(_ key: String) throws -> String? {
      try doc.select("input[type=image]").array().compactMap { try? $0.attr("name") }.first { $0.contains(key) }
    }
    return try ParsedTimetable(
      days: days,
      hasLessons: ownMonthHasLessons,
      fields: hiddenFields(doc),
      action: doc.select("form").first()?.attr("action") ?? "",
      url: url,
      prevButton: button("btn_prev_month"),
      nextButton: button("btn_next_month"))
  }

  struct PagerButton: Sendable { let name: String; let value: String }

  /// hidden 項目とフォームの action（ページ送りのボタンを押すときに使う）。
  @concurrent
  static func formBasics(_ html: String) async throws -> (fields: [String: String], action: String) {
    let doc = try SwiftSoup.parse(html)
    return try (hiddenFields(doc), doc.select("form").first()?.attr("action") ?? "")
  }

  /// 活動一覧は1件が5行。項目は id の末尾（`_ctrl{n}_活動日` など）で見分ける。`ctrl0` は追加用の行なので飛ばす。
  @concurrent
  static func parseHunt(_ html: String) async throws -> (items: [HuntActivity], pager: [PagerButton], fields: [String: String], action: String) {
    // 企業選択（4411 件の選択肢）は一覧の解析に不要で、HTML の大半を占めるので除いてから解析する
    let doc = try SwiftSoup.parse(withoutCompanySelect(html))
    guard try !doc.select("[id$=\"_ctrl0_追加\"]").isEmpty() else { throw SchoolError.parseFailed }
    func text(_ n: Int, _ field: String, tag: String = "") throws -> String {
      try (doc.select("\(tag)[id$=\"_ctrl\(n)_\(field)\"]").first()?.text() ?? "")
        .replacingOccurrences(of: "\u{3000}", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var items: [HuntActivity] = []
    var n = 1
    while try !doc.select("[id$=\"_ctrl\(n)_活動日\"]").isEmpty() {
      let manual = try text(n, "企業名手入力")
      let company = try [text(n, "企業名"), manual].filter { !$0.isEmpty }.joined(separator: " ")
      try items.append(HuntActivity(
        year: text(n, "活動年度"),
        date: text(n, "活動日"),
        kind: text(n, "活動区分"),
        periods: text(n, "時限表示"),
        mode: text(n, "オンライン訪問区分名"),
        attachment: text(n, "link_添付ファイル", tag: "a"),
        attachmentHref: doc.select("a[id$=_ctrl\(n)_link_添付ファイル]").first()?.attr("href"),
        approval: text(n, "承認状況"),
        company: company,
        jobType: text(n, "職種名"),
        location: text(n, "lbl_勤務地手入力"),
        result: text(n, "採否"),
        resultDate: text(n, "採否日")))
      n += 1
    }
    let pager = try doc.select("input[type=submit]").array().compactMap { e -> PagerButton? in
      let name = try e.attr("name")
      guard name.contains("_top$dp_pager") else { return nil }
      return try PagerButton(name: name, value: e.attr("value"))
    }
    return try (items, pager, hiddenFields(doc), doc.select("form").first()?.attr("action") ?? "")
  }

  /// 新增列の「企業選択」`<select>` を丸ごと取り除く（見つからなければそのまま返す）。
  nonisolated static func withoutCompanySelect(_ html: String) -> String {
    guard let marker = html.range(of: "企業選択\""),
          let open = html.range(of: "<select", options: .backwards, range: html.startIndex..<marker.lowerBound),
          let close = html.range(of: "</select>", range: marker.upperBound..<html.endIndex) else { return html }
    return String(html[..<open.lowerBound]) + String(html[close.upperBound...])
  }

  @concurrent
  /// `range` を指定した検索の結果は、その範囲に入る日付だけを採用する。
  /// 学校が範囲を無視して今月のページを返したときに、今月の記録に別の年を付けて混ぜてしまわないための検査。
  static func parseAttendance(
    _ html: String, range: (from: Date, through: Date)?, notAfter: Date, toleranceDays: Int
  ) async throws -> [AttendanceDay] {
    let doc = try SwiftSoup.parse(html)
    let days: [AttendanceDay] = try doc.select("tr").compactMap { tr in
      let cells = try tr.select("> td").array().map { try $0.text() }
      guard cells.count >= 11, cells[0].contains("/"),
            let date = resolveDate(cells[0], range: range, notAfter: notAfter, toleranceDays: toleranceDays) else { return nil }
      let periods = cells[1 ... 10].enumerated().map {
        AttendancePeriod(number: $0.offset + 1, rawStatus: $0.element)
      }
      return AttendanceDay(date: date, periods: periods)
    }
    guard days.isEmpty else { return days }
    // 記録が無いとき、「出欠ページは開けたが記録が無い」のか「出欠ページではない（エラー・メンテナンス・ログイン切れ）」のかを分ける。
    // 前者だけを「空の月」として確定させ、後者は取り直せるようにする（以前は両方を空の月として確定させていた）。
    let isAttendancePage = try !isLoginPage(html)
      && !doc.select("input[name*=txt_検索_日付01]").isEmpty()
      && !doc.select("input[name*=btn_検索]").isEmpty()
    throw isAttendancePage ? SchoolError.noRecords : SchoolError.parseFailed
  }

  /// 欄位の現在の値（ページの既定値）から日付の書式を推測する。判断できなければ yyyy/MM/dd。
  nonisolated static func format(_ date: Date, like sample: String, timeZone: TimeZone = AttendanceRatePeriod.calendar.timeZone) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = timeZone
    f.calendar = Calendar(identifier: .gregorian)
    let trimmed = sample.trimmingCharacters(in: .whitespaces)
    if trimmed.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil {
      f.dateFormat = "yyyy-MM-dd"
    } else if trimmed.range(of: #"^\d{1,2}/\d{1,2}$"#, options: .regularExpression) != nil {
      f.dateFormat = "M/d"
    } else {
      f.dateFormat = "yyyy/MM/dd"
    }
    return f.string(from: date)
  }

  /// "10/07(水)" → Date。表に年が無いので、曜日が合う年を探す（新しい年から最大 7 年前まで）。
  /// 範囲があればその範囲内、無ければ `notAfter`（＋許容日数）以前の日付だけを採用し、合う年が無ければ nil。
  nonisolated static func resolveDate(
    _ text: String, range: (from: Date, through: Date)?, notAfter: Date, toleranceDays: Int
  ) -> Date? {
    let head = text.prefix { $0 != "(" && $0 != "（" }
    let parts = head.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard parts.count == 2 else { return nil }
    let weekdaySymbols = ["日", "月", "火", "水", "木", "金", "土"]
    let weekdayChar = text.first { weekdaySymbols.contains(String($0)) }
    let cal = AttendanceRatePeriod.calendar
    let upper = range?.through ?? (cal.date(byAdding: .day, value: toleranceDays, to: notAfter) ?? notAfter)
    let startYear = cal.component(.year, from: upper)
    for year in stride(from: startYear, through: startYear - 7, by: -1) {
      // 2/29 などで存在しない日付は、暗黙に繰り上がらないよう日・月を確かめる
      guard let date = cal.date(from: DateComponents(year: year, month: parts[0], day: parts[1])),
            cal.component(.month, from: date) == parts[0], cal.component(.day, from: date) == parts[1],
            date <= upper else { continue }
      if let range, date < cal.startOfDay(for: range.from) { continue }
      if let weekdayChar, weekdaySymbols[cal.component(.weekday, from: date) - 1] != String(weekdayChar) { continue }
      return date
    }
    return nil
  }
}
