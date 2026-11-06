import Foundation

/// 成績の1科目（学校ポータル「成績」ページの1行）。値はすべて学校の原文。まだ評価のない欄は空文字。
nonisolated struct GradeRecord: Identifiable, Codable, Equatable, Sendable {
  /// 履修年度（例: "2025"）
  let year: String
  /// 期間（"通年" / "前期" / "後期"）
  let term: String
  let subject: String
  /// 区分（"必修" / "選択必修" など）
  let category: String
  /// 単位
  let credits: String
  let firstScore: String
  let firstGrade: String
  let secondScore: String
  let secondGrade: String

  var id: String { [year, term, subject].joined(separator: "|") }

  /// 画面に出す評価の欄。前期の科目は前期だけ、後期の科目は後期だけ、通年は両方。
  var gradeSlots: [(label: String, score: String, grade: String)] {
    switch term {
    case let t where t.contains("前期"): return [("前期", firstScore, firstGrade)]
    case let t where t.contains("後期"): return [("後期", secondScore, secondGrade)]
    default: return [("前期", firstScore, firstGrade), ("後期", secondScore, secondGrade)]
    }
  }

  /// 点数（全角数字も読む）。数字でなければ nil。
  static func number(_ text: String) -> Double? {
    let normalized = (text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return Double(normalized)
  }
}
