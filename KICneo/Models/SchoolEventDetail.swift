import Foundation

/// 学校ポータルの説明会詳細ページ。値は学校の原文（空の項目は空文字）。
nonisolated struct SchoolEventDetail: Sendable, Equatable, Codable {
  /// 「内容」の文章の1区間。リンクなら `url` を持つ。
  struct Run: Sendable, Equatable, Codable {
    let text: String
    let url: URL?
  }

  let title: String
  let kind: String
  let date: String
  let applyPeriod: String
  let capacity: String
  let remaining: String
  let room: String
  let publishFrom: String
  let publishTo: String
  let status: String
  let content: [Run]
  let attachments: [String]
  /// ページに「申込」ボタンがあるか
  let hasApplyButton: Bool
}

/// 詳細の取得結果。掲載が終わった説明会は学校の一覧にないので `unavailable`。
nonisolated enum SchoolEventDetailResult: Sendable, Equatable {
  case loaded(SchoolEventDetail)
  case unavailable
  case failed
}
