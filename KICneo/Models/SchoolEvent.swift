import Foundation

/// 学校ポータル「イベント申込」一覧の1件。申込状況は学校の原文（申込済 / 申込受付中 / 申込期間外 / 満席）。
nonisolated struct SchoolEvent: Identifiable, Equatable, Sendable, Codable {
  let title: String
  let status: String
  let date: String
  let applyPeriod: String

  var id: String {
    title + date
  }

  private enum CodingKeys: String, CodingKey { case title, status, date, applyPeriod }
  /// 学校側で申込済みになっているか（アプリの「参加中」タグの根拠）
  var isApplied: Bool {
    status.contains("申込済")
  }
}
