import Foundation

/// 一覧に表示する説明会（学校の「イベント申込」の1件から作る）。
/// Codable：以前の Supabase のデータ（端末に残っているキャッシュ）を読むため。
struct KICEvent: Identifiable, Codable {
  let id: Int
  let title: String
  let companyName: String?
  let eventFormat: String?
  let specialTag: String?

  // 以前の Supabase の列名（スネークケース）に対応させる
  enum CodingKeys: String, CodingKey {
    case id
    case title
    case companyName = "company_name"
    case eventFormat = "event_format"
    case specialTag = "special_tag"
  }
}
