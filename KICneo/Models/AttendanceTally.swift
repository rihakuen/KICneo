import Foundation

/// 出欠のコマ数を、学校の数え方で数える。
/// - 「出席」は出席。「遅刻」も出席に数えるが、遅刻3回で欠席1回になる（3回ごとに出席を1つ減らし、欠席を1つ増やす）
/// - 「就職」「公欠」は出席扱い（出席率の分子に入る）。内訳では別に数える
/// - それ以外（「欠席」など）は欠席。空の欄は数えない
nonisolated struct AttendanceTally: Equatable, Sendable {
  /// 出席（遅刻を含む。遅刻による欠席の分は引く前）
  private(set) var rawPresent = 0
  private(set) var late = 0
  private(set) var excused = 0
  private(set) var rawAbsent = 0

  init() {}

  init(_ statuses: [String]) {
    for status in statuses { add(status) }
  }

  mutating func add(_ status: String) {
    let s = status.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !s.isEmpty else { return }
    if s.contains("遅刻") {
      rawPresent += 1
      late += 1
    } else if s == "出席" {
      rawPresent += 1
    } else if s == "就職" || s == "公欠" {
      excused += 1
    } else {
      rawAbsent += 1
    }
  }

  /// 遅刻で増える欠席の数（3回で1回）
  var latePenalty: Int { late / 3 }
  /// 出席（遅刻を含み、遅刻による欠席の分を引いたもの）
  var present: Int { rawPresent - latePenalty }
  /// 欠席（遅刻による欠席を含む）
  var absent: Int { rawAbsent + latePenalty }
  /// 全コマ
  var total: Int { rawPresent + excused + rawAbsent }
  /// 出席率の分子（出席＋就職・公欠）
  var attended: Int { present + excused }
  /// 出席率（%）。記録がなければ nil
  var rate: Double? { total > 0 ? Double(attended) / Double(total) * 100 : nil }
}
