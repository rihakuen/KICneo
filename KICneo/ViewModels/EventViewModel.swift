import Combine
import Foundation
import SwiftUI
import UIKit

enum ActionFeedbackEffect: Equatable {
  case interested
}

/// 説明会リストの状態フィルタ。
enum EventStatusFilter: String, CaseIterable {
  case applying = "参加中"
  case saved = "保存"
}

/// 説明会の一覧。データはすべて学校ポータルの「イベント申込」一覧（SchoolViewModel が取得）から、端末内で作る。
/// 外部のサーバー（以前の Supabase）には問い合わせない。
@MainActor
class EventViewModel: ObservableObject {
  @Published var searchText = ""
  @Published var selectedTagFilter: String?
  @Published var selectedStatusFilter: EventStatusFilter?
  /// 学校の「イベント申込」一覧。申込済みの説明会に「参加中」タグを付ける根拠。
  @Published var schoolEvents: [SchoolEvent] = [] {
    didSet { rebuildDisplay() }
  }

  @Published var toastMessage: String?
  @Published var toastIcon = "checkmark.circle.fill"
  @Published var activeEffect: ActionFeedbackEffect?
  @Published var showCelebration = false
  @Published private(set) var stateRevision = 0

  private let localStateService: LocalEventStateService
  private let preferencesService = UserPreferencesService()
  /// 以前 Supabase から取得して端末に残っている説明会（読むだけ・通信しない）。
  /// その頃の「気になる」は Supabase の ID で保存されているので、新しい ID へ引き継ぐためだけに使う。
  private let legacyEvents: [KICEvent]

  init() {
    localStateService = LocalEventStateService(storageKey: "kic_event_user_states")
    legacyEvents = LocalCacheService().load().flatMap { try? JSONDecoder().decode([KICEvent].self, from: $0) } ?? []
  }

  /// 一覧に出す説明会。学校の「イベント申込」の一覧そのもので、形式・特記タグ・企業名はタイトルから読み取る。
  /// タイトルの解析は正規表現を使って重いので、描画のたびに計算せず、元のデータが変わったときだけ作り直す。
  @Published private(set) var displayEvents: [KICEvent] = []
  private var schoolEventByEventID: [Int: SchoolEvent] = [:]
  private var applyingEventIDs: Set<Int> = []

  private func rebuildDisplay() {
    var display: [KICEvent] = []
    var byID: [Int: SchoolEvent] = [:]
    var applying: Set<Int> = []
    var usedIDs: Set<Int> = []
    for school in schoolEvents {
      var event = Self.event(from: school)
      // 同じタイトルの説明会が別の日にもあるとき、2つ目以降は開催日も含めた ID にする
      // （1つ目はこれまでと同じ ID なので、保存済みの「気になる」はそのまま）
      if usedIDs.contains(event.id) {
        event = Self.event(from: school, id: Self.stableID(for: school, includingDate: true))
      }
      usedIDs.insert(event.id)
      migrateLegacyState(for: school, to: event.id)
      display.append(event)
      byID[event.id] = school
      if school.isApplied {
        applying.insert(event.id)
      }
    }
    displayEvents = display
    schoolEventByEventID = byID
    applyingEventIDs = applying
  }

  var totalEventCount: Int {
    displayEvents.count
  }

  var graduationCountdownLabel: String {
    _ = stateRevision
    return preferencesService.graduationCountdownLabel
  }

  var graduationDate: Date {
    get {
      _ = stateRevision
      return preferencesService.graduationDate
    }
    set {
      preferencesService.graduationDate = newValue
      bumpState()
    }
  }

  var daysUntilGraduation: Int {
    _ = stateRevision
    let start = Calendar.current.startOfDay(for: Date())
    let end = Calendar.current.startOfDay(for: preferencesService.graduationDate)
    return Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
  }

  var graduationCountdownText: String {
    let days = daysUntilGraduation
    if days > 0 {
      return "\(days) 日"
    }
    if days == 0 {
      return "今日"
    }
    return "\(abs(days)) 日超過"
  }

  var availableTags: [String] {
    let tags = displayEvents.flatMap { event -> [String] in
      [event.eventFormat, event.specialTag].compactMap { $0 }.filter { !$0.isEmpty }
    }
    return Array(Set(tags)).sorted()
  }

  var savedCount: Int {
    _ = stateRevision
    return displayEvents.filter { isSaved($0) }.count
  }

  var applyingCount: Int {
    displayEvents.filter { isApplying($0) }.count
  }

  /// 参加中（学校で申込済み）を先頭に。それ以外は学校の一覧の順序のまま（関心タグによる並べ替えはしない）。
  var sortedEvents: [KICEvent] {
    _ = stateRevision
    return displayEvents.filter { isApplying($0) } + displayEvents.filter { !isApplying($0) }
  }

  var filteredEvents: [KICEvent] {
    var result = sortedEvents

    if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
      let query = searchText.lowercased()
      result = result.filter {
        $0.title.lowercased().contains(query)
          || ($0.companyName?.lowercased().contains(query) ?? false)
      }
    }

    if let filter = selectedTagFilter {
      result = result.filter {
        $0.eventFormat == filter || $0.specialTag == filter
      }
    }

    switch selectedStatusFilter {
    case .applying: result = result.filter { isApplying($0) }
    case .saved: result = result.filter { isSaved($0) }
    case nil: break
    }

    return result
  }

  /// 端末内に保存（ブックマーク）しているか。以前の「申込済み」「参加済み」の記録も保存として扱う。
  func isSaved(_ event: KICEvent) -> Bool {
    _ = stateRevision
    return localStateService.status(for: event.id) != nil
  }

  /// 学校のイベント申込一覧にある、この説明会に対応するイベント（掲載が終わっていれば nil）。
  func schoolEvent(for event: KICEvent) -> SchoolEvent? {
    schoolEventByEventID[event.id]
  }

  /// 学校のイベント申込一覧で「申込済」になっているか（参加中）。
  func isApplying(_ event: KICEvent) -> Bool {
    applyingEventIDs.contains(event.id)
  }

  /// 保存 / 保存解除。
  func toggleSaved(_ event: KICEvent) {
    if isSaved(event) {
      localStateService.remove(for: event.id)
      showToast("保存を解除しました", icon: "bookmark.slash.fill")
    } else {
      localStateService.ensureState(status: .interested, for: event.id)
      triggerEffect(.interested)
      showToast("保存しました", icon: "bookmark.fill")
    }
    bumpState()
  }

  func updateGraduationLabel(_ label: String) {
    preferencesService.graduationCountdownLabel = label
    bumpState()
  }

  func completeJobHunting() {
    preferencesService.isJobHuntingCompleted = true
    AppHaptics.success()
    withAnimation(AppTheme.Motion.transition(reduce: UIAccessibility.isReduceMotionEnabled)) {
      showCelebration = true
    }
  }

  func dismissCelebration() {
    withAnimation(AppTheme.Motion.transition(reduce: UIAccessibility.isReduceMotionEnabled)) {
      showCelebration = false
    }
  }

  func isInterestTagSelected(_ tag: String) -> Bool {
    preferencesService.isSelected(tag)
  }

  func toggleInterestTag(_ tag: String) {
    preferencesService.toggleTag(tag)
    bumpState()
  }

  func matchesInterestTags(_ event: KICEvent) -> Bool {
    let tags = preferencesService.interestTags
    guard !tags.isEmpty else { return false }
    let eventTags = [event.eventFormat, event.specialTag].compactMap { $0 }
    return !Set(tags).isDisjoint(with: Set(eventTags))
  }

  func dismissToast() {
    toastMessage = nil
  }

  private func triggerEffect(_ effect: ActionFeedbackEffect) {
    activeEffect = effect
    switch effect {
    case .interested:
      AppHaptics.light()
    }

    Task {
      try? await Task.sleep(nanoseconds: 1_200_000_000)
      if activeEffect == effect {
        activeEffect = nil
      }
    }
  }

  /// 学校の「イベント申込」の1件から、一覧に出す説明会を作る。
  /// 例：「【未経験者・留学生応募可能】0304 藤岡金属株式会社 オンライン説明会」
  ///   → 特記タグ「未経験者・留学生応募可能」、形式「オンライン」、表示名「藤岡金属株式会社 オンライン説明会」
  /// ID は「気になる」の保存キーなので、起動ごとに変わらない値（タイトルの FNV-1a ハッシュ）を負の数で使う。
  /// 計算は以前と同じなので、これまで学校の一覧から作っていた説明会の「気になる」はそのまま残る。
  static func event(from school: SchoolEvent, id: Int? = nil) -> KICEvent {
    let normalized = school.title
      .replacingOccurrences(of: "\u{3000}", with: " ")
      .trimmingCharacters(in: .whitespaces)
    // 先頭の【…】を特記タグとして取り出す（複数あればつなげる）
    var rest = Substring(normalized)
    var tags: [String] = []
    while rest.hasPrefix("【"), let end = rest.firstIndex(of: "】") {
      let tag = rest[rest.index(after: rest.startIndex)..<end].trimmingCharacters(in: .whitespaces)
      if !tag.isEmpty { tags.append(tag) }
      rest = rest[rest.index(after: end)...].drop(while: { $0 == " " })
    }
    // 学校の並び番号（先頭の4桁）を除く
    let title = String(rest)
      .replacingOccurrences(of: #"^\d{4}\s*"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    var format: String?
    if title.contains("オンライン") {
      format = "オンライン"
    } else if title.contains("学内") || title.contains("校内") {
      format = "校内"
    }
    return KICEvent(id: id ?? stableID(for: school), title: title.isEmpty ? normalized : title,
      companyName: nil, eventFormat: format, specialTag: tags.isEmpty ? nil : tags.joined(separator: "・"))
  }

  private static func stableID(for school: SchoolEvent, includingDate: Bool = false) -> Int {
    let key = school.title
      .replacingOccurrences(of: "\u{3000}", with: " ")
      .replacingOccurrences(of: #"^\d{4}\s*"#, with: "", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in (matchKey(key) + (includingDate ? "|" + SchoolClient.dateKey(school.date) : "")).utf8 {
      hash = (hash ^ UInt64(byte)) &* 0x100000001b3
    }
    return -Int(hash & 0x3fffffffffffffff) - 1
  }

  /// 以前 Supabase の ID で保存した「気になる」を、学校の一覧から作った ID へ移す（移し終えたものは何もしない）。
  private func migrateLegacyState(for school: SchoolEvent, to newID: Int) {
    guard !legacyEvents.isEmpty,
          let legacy = legacyEvents.first(where: { Self.matches($0, schoolTitle: school.title) }) else { return }
    localStateService.moveState(from: legacy.id, to: newID)
  }

  /// 以前の Supabase の説明会と学校ポータルのイベントを、タイトル（なければ企業名）で突き合わせる（引き継ぎ専用）。
  private static func matches(_ event: KICEvent, schoolTitle: String) -> Bool {
    let school = matchKey(schoolTitle)
    let title = matchKey(event.title)
    if !title.isEmpty, !school.isEmpty {
      if title == school {
        return true
      }
      if min(title.count, school.count) >= 6, title.contains(school) || school.contains(title) {
        return true
      }
    }
    let company = matchKey(event.companyName ?? "")
    return company.count >= 4 && school.contains(company)
  }

  /// 比較用に、先頭の「27卒」・空白・記号・「株式会社」・先頭の数字（学校側の並び番号）を取り除く。
  private static var matchKeyCache: [String: String] = [:]

  private static func matchKey(_ text: String) -> String {
    if let cached = matchKeyCache[text] {
      return cached
    }
    let key = computeMatchKey(text)
    matchKeyCache[text] = key
    return key
  }

  private static func computeMatchKey(_ text: String) -> String {
    var t = text.replacingOccurrences(of: #"^\s*\d+卒\s*"#, with: "", options: .regularExpression)
    t = String(t.lowercased().filter { $0.isLetter || $0.isNumber })
    for word in ["株式会社", "有限会社"] {
      t = t.replacingOccurrences(of: word, with: "")
    }
    return String(t.drop(while: { $0.isNumber }))
  }

  private func showToast(_ message: String, icon: String) {
    toastMessage = message
    toastIcon = icon

    Task {
      try? await Task.sleep(nanoseconds: 2_500_000_000)
      if toastMessage == message {
        toastMessage = nil
      }
    }
  }

  private func bumpState() {
    stateRevision += 1
    objectWillChange.send()
  }
}
