import SwiftUI

/// 説明会カードを展開したときに、カードの中（概要の下）に出す詳細。
/// 表示する値はすべて学校ポータルから取得したもの：
/// 開催日時・申込期間・申込状況は一覧（SchoolEvent）、会場・定員・残席・内容・添付は詳細ページ（SchoolEventDetail）。
/// 詳細は保存済みの内容を先に出し、学校から取り直せたら差し替える。いちばん下に「気になる」と「学校サイト」を置く。
/// （以前はシートで開いていたので、ファイル名は EventDetailSheet のまま）
struct EventDetailPanel: View {
  @ObservedObject var viewModel: EventViewModel
  @ObservedObject var school: SchoolViewModel
  let event: KICEvent
  var previewOnly = false
  var onOpenSchool: () -> Void
  var onToggleSaved: () -> Void
  @State private var portal: SchoolEventDetailResult?
  /// 長い本文を全部表示しているか
  @State private var showsFullText = false
  @State private var showsApplyConfirmation = false
  /// 申込の結果（成功・失敗・学校サイトで、のお知らせ）
  @State private var applyResult: SchoolViewModel.ApplyResult?
  /// iPhone の「カレンダー」App に追加する予定（あるときに追加の画面を開く）
  @State private var calendarDraft: CalendarDraft?
  /// カレンダーに追加し終えたか（ボタンの表示を変える）
  @State private var addedToCalendar = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var source: SchoolEvent? { viewModel.schoolEvent(for: event) }

  private var loadedDetail: SchoolEventDetail? {
    if case .loaded(let detail) = portal { return detail }
    return nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
      Divider()
      // 原題（「〜 学内説明会」など）と申込状況
      HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.sm) {
        Text(event.title)
          .font(.footnote)
          .foregroundStyle(AppTheme.textSecondary)
          .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        if let status = statusText { statusChip(status) }
      }
      keyFacts
      message
        .id(phase)
        .transition(.blurReplace)
      if let detail = loadedDetail, !detail.attachments.isEmpty {
        attachments(detail.attachments)
      }
      actions
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(AppTheme.Motion.text(reduce: reduceMotion), value: portal)
    // 申込状況が変わったら（申し込んだ後など）、詳細も取り直す
    .task(id: "\(source?.id ?? "")|\(source?.status ?? "")|\(school.isLoggedIn)") {
      if previewOnly { portal = .loaded(sampleDetail); return }
      await loadDetail()
    }
  }

  // MARK: 内容

  private var phase: String {
    switch portal {
    case nil: "loading"
    case .loaded: "loaded"
    case .failed: "failed"
    case .unavailable: "unavailable"
    }
  }

  @ViewBuilder private var message: some View {
    switch portal {
    case nil:
      ProgressView("詳細を読み込み中…").font(AppTheme.Typography.body)
    case .loaded(let detail):
      if !detail.content.isEmpty {
        contentText(detail.content)
      }
    case .failed:
      HStack {
        Text("詳細を読み込めませんでした。").font(AppTheme.Typography.body).foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Button("再読み込み") { Task { await loadDetail() } }.frame(minHeight: 44)
      }
    case .unavailable:
      Text("この説明会の詳細ページは掲載が終わっています。下の内容は一覧の情報です。")
        .font(AppTheme.Typography.body).foregroundStyle(AppTheme.textSecondary)
    }
  }

  // MARK: 要点（日時・会場・残席・申込期間）

  /// 詳細ページの値を優先し、まだ無いときは一覧の値で埋める（取得中・失敗中でも中身が出る）
  private func pick(_ portalValue: String?, _ listValue: String?) -> String {
    let value = portalValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? (listValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : value
  }

  private var statusText: String? {
    let value = pick(loadedDetail?.status, source?.status)
    return value.isEmpty ? nil : value
  }

  /// 申込状況の色：受付中＝緑、申込済＝青、満席・締切＝赤、それ以外（期間外など）＝灰
  private func statusChip(_ status: String) -> some View {
    let tint: Color = status.contains("申込済") ? AppTheme.primaryAction
      : (status.contains("満") || status.contains("締切") ? AppTheme.holiday
      : (status.contains("受付中") ? AppTheme.success : AppTheme.textSecondary))
    return Text(status)
      .font(.caption.weight(.bold))
      .foregroundStyle(tint)
      .padding(.horizontal, AppTheme.Space.sm).padding(.vertical, AppTheme.Space.xs)
      .background(tint.opacity(0.14), in: Capsule())
      .fixedSize()
  }

  /// 開催日時・会場・残席・申込期間を、アイコン付きで大きめに。値が無い項目は出さない。
  private var keyFacts: some View {
    let detail = loadedDetail
    let seats = seatsText(remaining: pick(detail?.remaining, nil), capacity: pick(detail?.capacity, nil))
    let facts: [(icon: String, label: String, value: String, tint: Color)] = [
      ("calendar", "開催日時", pick(detail?.date, source?.date), AppTheme.primaryAction),
      ("mappin.and.ellipse", "会場", pick(detail?.room, nil), AppTheme.primaryAction),
      ("person.2.fill", "残席", seats.text, seats.tint),
      ("clock", "申込期間", pick(detail?.applyPeriod, source?.applyPeriod), AppTheme.primaryAction)
    ].filter { !$0.value.isEmpty }
    return VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      ForEach(facts, id: \.label) { fact in
        HStack(alignment: .top, spacing: AppTheme.Space.md) {
          Image(systemName: fact.icon)
            .font(AppTheme.Typography.bodyEmphasis)
            .foregroundStyle(fact.tint)
            .frame(width: 30, height: 30)
            .background(fact.tint.opacity(0.12), in: .rect(cornerRadius: AppTheme.Radius.chip, style: .continuous))
            .accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 1) {
            Text(fact.label).font(AppTheme.Typography.captionEmphasis).foregroundStyle(AppTheme.textSecondary)
            Text(fact.value)
              .font(AppTheme.Typography.bodyEmphasis)
              .monospacedDigit()
              .foregroundStyle(fact.label == "残席" ? fact.tint : AppTheme.textPrimary)
              .fixedSize(horizontal: false, vertical: true)
              .textSelection(.enabled)
              .contentTransition(.numericText())
          }
          Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(AppTheme.Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppTheme.elevatedBackground, in: .rect(cornerRadius: AppTheme.Radius.small, style: .continuous))
  }

  /// 「残り12名 / 定員30名」。数字が読めれば残りが少ないほど目立たせる（2割以下＝黄、0＝赤）。
  private func seatsText(remaining: String, capacity: String) -> (text: String, tint: Color) {
    func number(_ text: String) -> Int? {
      let digits = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text).filter(\.isNumber)
      return digits.isEmpty ? nil : Int(digits)
    }
    let text: String
    switch (remaining.isEmpty, capacity.isEmpty) {
    case (false, false): text = "残り\(remaining) / 定員\(capacity)"
    case (false, true): text = "残り\(remaining)"
    case (true, false): text = "定員\(capacity)"
    case (true, true): text = ""
    }
    guard let left = number(remaining) else { return (text, AppTheme.primaryAction) }
    if left == 0 { return (text, AppTheme.holiday) }
    if let total = number(capacity), total > 0, Double(left) / Double(total) <= 0.2 { return (text, AppTheme.warning) }
    return (text, AppTheme.success)
  }

  // MARK: 本文

  /// 本文を行に分け、「【…】」「■」「●」などで始まる行を小見出しとして太字にする。リンクはそのまま押せる。
  /// 10行を超えるときは最初の8行だけ出し、「続きを読む」で全部表示する。
  private func contentText(_ runs: [SchoolEventDetail.Run]) -> some View {
    let lines = Self.lines(runs)
    let isLong = lines.count > 10
    let visible = isLong && !showsFullText ? Array(lines.prefix(8)) : lines
    return VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("内容")
        .font(AppTheme.Typography.captionEmphasis)
        .tracking(1.5)
        .foregroundStyle(AppTheme.textSecondary)
      VStack(alignment: .leading, spacing: 6) {
        ForEach(visible.indices, id: \.self) { index in
          let line = visible[index]
          if line.isBlank {
            Color.clear.frame(height: 4)
          } else {
            Text(line.text)
              .font(line.isHeading ? .subheadline.weight(.bold) : .subheadline)
              .foregroundStyle(AppTheme.textPrimary)
              .lineSpacing(4)
              .padding(.top, line.isHeading && index > 0 ? AppTheme.Space.xs : 0)
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .textSelection(.enabled)
      // 折りたたんでいるときは、下の端を薄くして続きがあることを示す
      .mask {
        LinearGradient(stops: isLong && !showsFullText
          ? [.init(color: .black, location: 0.7), .init(color: .black.opacity(0.15), location: 1)]
          : [.init(color: .black, location: 0), .init(color: .black, location: 1)],
          startPoint: .top, endPoint: .bottom)
      }
      if isLong {
        Button {
          withAnimation(AppTheme.Motion.transition(reduce: reduceMotion)) { showsFullText.toggle() }
        } label: {
          Label(showsFullText ? "閉じる" : "続きを読む", systemImage: showsFullText ? "chevron.up" : "chevron.down")
            .font(AppTheme.Typography.bodyEmphasis)
            .contentTransition(.interpolate)
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.primaryAction)
        .frame(minHeight: 44)
      }
    }
  }

  private struct ContentLine {
    let text: AttributedString
    let isHeading: Bool
    let isBlank: Bool
  }

  private static let headingMarks: [Character] = ["【", "■", "□", "●", "○", "◆", "◇", "▼", "▲", "★", "☆", "◎", "≪", "＜"]

  /// 本文の区間（リンク付きを含む）を、改行ごとの行にする
  private static func lines(_ runs: [SchoolEventDetail.Run]) -> [ContentLine] {
    var result: [AttributedString] = [AttributedString()]
    for run in runs {
      let pieces = run.text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
      for (index, piece) in pieces.enumerated() {
        if index > 0 { result.append(AttributedString()) }
        var part = AttributedString(piece)
        if let url = run.url { part.link = url }
        result[result.count - 1] += part
      }
    }
    // 空行が続くときは1つにまとめ、先頭と末尾の空行は除く
    var lines: [ContentLine] = []
    for text in result {
      let plain = String(text.characters).trimmingCharacters(in: .whitespaces)
      if plain.isEmpty {
        if let last = lines.last, !last.isBlank { lines.append(ContentLine(text: text, isHeading: false, isBlank: true)) }
        continue
      }
      let isHeading = plain.first.map { headingMarks.contains($0) } ?? false
      lines.append(ContentLine(text: text, isHeading: isHeading, isBlank: false))
    }
    while lines.last?.isBlank == true { lines.removeLast() }
    return lines
  }

  private func attachments(_ names: [String]) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Text("添付")
        .font(AppTheme.Typography.captionEmphasis)
        .tracking(1.5)
        .foregroundStyle(AppTheme.textSecondary)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(names.enumerated()), id: \.offset) { index, name in
          Label(name, systemImage: "paperclip")
            .font(AppTheme.Typography.body)
            .foregroundStyle(AppTheme.textPrimary)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
          if index < names.count - 1 { Divider() }
        }
      }
      .padding(.horizontal, AppTheme.Space.md)
      .background(AppTheme.elevatedBackground, in: .rect(cornerRadius: AppTheme.Radius.small, style: .continuous))
    }
  }

  // MARK: 操作（詳細のいちばん下）

  /// アプリから申し込めるか：学校の詳細ページに申込ボタンがあり、まだ申込済みでないとき
  private var canApply: Bool {
    loadedDetail?.hasApplyButton == true && source?.isApplied != true
  }

  private var isApplying: Bool {
    source.map { school.applyingEventTitles.contains($0.title) } ?? false
  }

  private var actions: some View {
    let applied = source?.isApplied == true
    let saved = viewModel.isSaved(event)
    return VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      if let applyResult { resultBanner(applyResult) }
      if canApply || isApplying {
        // 学校サイトへ行かずに、その場で申し込む（確認してから送る）
        Button {
          AppHaptics.light()
          showsApplyConfirmation = true
        } label: {
          HStack(spacing: AppTheme.Space.sm) {
            if isApplying { ProgressView().tint(.white) }
            Text(isApplying ? "申し込んでいます…" : "この説明会に申し込む")
              .contentTransition(.interpolate)
          }
          .font(AppTheme.Typography.headline)
          .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(AppTheme.primaryAction)
        .disabled(isApplying || previewOnly)
        .accessibilityIdentifier("event-apply-\(event.id)")
      }
      if applied, eventCalendarDraft != nil {
        // 申込済みの説明会を、iPhone の「カレンダー」App に入れる
        Button {
          AppHaptics.light()
          calendarDraft = eventCalendarDraft
        } label: {
          Label(addedToCalendar ? "カレンダーに追加しました" : "カレンダーに追加",
                systemImage: addedToCalendar ? "checkmark.circle.fill" : "calendar.badge.plus")
            .contentTransition(.symbolEffect(.replace))
            .font(AppTheme.Typography.bodyEmphasis)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
        .tint(addedToCalendar ? AppTheme.success : AppTheme.primaryAction)
        .disabled(previewOnly)
        .accessibilityIdentifier("event-calendar-\(event.id)")
      }
      HStack(spacing: AppTheme.Space.sm) {
        Button(action: onToggleSaved) {
          Label("気になる", systemImage: saved ? "bookmark.fill" : "bookmark")
            .contentTransition(.symbolEffect(.replace))
            .frame(maxWidth: .infinity)
        }
        .tint(saved ? AppTheme.primaryAction : AppTheme.textSecondary)
        .accessibilityValue(saved ? "登録済み" : "未登録")
        Button(action: onOpenSchool) {
          Label(applied ? "学校サイトで確認" : "学校サイト", systemImage: "arrow.up.right")
            .contentTransition(.interpolate)
            .frame(maxWidth: .infinity)
        }
        .tint(AppTheme.primaryAction)
      }
      .font(AppTheme.Typography.bodyEmphasis)
      .lineLimit(1).minimumScaleFactor(0.8)
      .buttonStyle(.bordered)
      .buttonBorderShape(.capsule)
      .controlSize(.regular)
    }
    .animation(AppTheme.Motion.feedback(reduce: reduceMotion), value: saved)
    .animation(AppTheme.Motion.transition(reduce: reduceMotion), value: canApply)
    .animation(AppTheme.Motion.transition(reduce: reduceMotion), value: isApplying)
    .animation(AppTheme.Motion.transition(reduce: reduceMotion), value: applyResult)
    .animation(AppTheme.Motion.feedback(reduce: reduceMotion), value: addedToCalendar)
    .sheet(item: $calendarDraft) { draft in
      CalendarEventSheet(draft: draft) { added in
        calendarDraft = nil
        if added {
          addedToCalendar = true
          AppHaptics.success()
        }
      }
      .ignoresSafeArea()
    }
    .confirmationDialog("この説明会に申し込みますか？", isPresented: $showsApplyConfirmation, titleVisibility: .visible) {
      Button("申し込む") { Task { await apply() } }
      Button("キャンセル", role: .cancel) {}
    } message: {
      Text([EventPresentation.companyTitle(event), source?.date ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        + "\n学校のポータルに申込が送られます。")
    }
  }

  private func apply() async {
    guard let source else { return }
    applyResult = nil
    let result = await school.applySchoolEvent(source)
    applyResult = result
    if case .applied = result {
      AppHaptics.success()
      // 申し込めたら、そのまま「カレンダー」App に追加する画面を開く（追加するかは選べる）
      if let draft = eventCalendarDraft {
        try? await Task.sleep(for: .seconds(0.6)) // 成功のお知らせを先に見せる
        calendarDraft = draft
      }
    }
  }

  /// この説明会のカレンダーの予定。日時は一覧の開催日時（なければ詳細の開催日時）、場所は詳細の会場。
  private var eventCalendarDraft: CalendarDraft? {
    let schedule = pick(source?.date, loadedDetail?.date)
    let notes = [
      source?.title ?? event.title,
      loadedDetail.map { $0.kind }.flatMap { $0.isEmpty ? nil : $0 },
      "KICneo から追加（学校ポータルの説明会）",
    ].compactMap { $0 }.joined(separator: "\n")
    return CalendarDraft.make(
      title: event.title, schedule: schedule,
      location: loadedDetail?.room, notes: notes)
  }

  /// 申込の結果のお知らせ（成功＝緑、学校サイトで＝青、失敗＝黄）
  private func resultBanner(_ result: SchoolViewModel.ApplyResult) -> some View {
    let (icon, text, tint): (String, String, Color) = switch result {
    case .applied(let message): ("checkmark.circle.fill", message ?? "申し込みました。", AppTheme.success)
    case .needsWebsite(let reason): ("arrow.up.right.circle.fill", reason, AppTheme.primaryAction)
    case .failed(let reason): ("exclamationmark.triangle.fill", reason, AppTheme.warning)
    }
    return Label {
      Text(text).fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: icon).foregroundStyle(tint)
    }
    .font(AppTheme.Typography.bodyEmphasis)
    .padding(AppTheme.Space.md)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(tint.opacity(0.12), in: .rect(cornerRadius: AppTheme.Radius.small, style: .continuous))
    .transition(.blurReplace)
  }

  // MARK: 取得（保存済みを先に出し、取り直せたら差し替える）

  private func loadDetail() async {
    guard let source else { portal = .unavailable; return }
    let cached = school.cachedEventDetail(title: source.title, date: source.date)
    if let cached { portal = .loaded(cached) }
    let fresh = await school.eventDetail(title: source.title, date: source.date)
    guard !Task.isCancelled else { return }
    if case .loaded = fresh { portal = fresh }
    else if cached == nil { portal = fresh }
  }

  private var sampleDetail: SchoolEventDetail {
    DemoData.previewDetail(title: event.title, source: source)
  }
}
