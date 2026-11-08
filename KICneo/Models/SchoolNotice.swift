import Foundation

/// 学校ポータルのトップページにある「未読のお知らせ／授業関連／連絡事項」の1件。
/// 学校側では、詳細を開くと既読になってトップページから消えるので、端末にも保存しておく。
nonisolated struct SchoolNotice: Codable, Hashable, Identifiable, Sendable {
  /// 「お知らせ」「授業関連」「連絡事項」（トップページのどの欄にあったか）
  let section: String
  let title: String
  /// 掲示板の分類（「キャリアセンター」「連絡・スケジュール」など）
  let category: String
  /// 掲示開始日（学校の表記のまま。例: 2026/11/06）
  let date: String
  let poster: String
  let hasAttachment: Bool
  /// 詳細を開く postback の対象。トップページから消えたもの（端末に保存していた分）は nil。
  var eventTarget: String?

  var id: String { key }
  /// 同じお知らせかどうかの判定用（postback の番号は毎回変わりうるので含めない）
  var key: String { [section, category, date, title].joined(separator: "|") }

  /// 並べ替え・保存期間の判定用の日付
  var postedAt: Date? {
    let digits = date.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
    guard digits.count >= 3 else { return nil }
    return AttendanceRatePeriod.calendar.date(from: DateComponents(year: digits[0], month: digits[1], day: digits[2]))
  }
}

/// お知らせの詳細（「掲示内容」の欄）
nonisolated struct SchoolNoticeDetail: Codable, Hashable, Sendable {
  /// どのお知らせの詳細か（SchoolNotice.key）
  let key: String
  let poster: String
  let startDate: String
  let endDate: String
  let title: String
  let body: String
  let attachments: [Attachment]

  nonisolated struct Attachment: Codable, Hashable, Sendable, Identifiable {
    let name: String
    /// 添付をダウンロードする postback の対象（詳細ページの中の番号）
    let eventTarget: String
    var id: String { name + eventTarget }

    var isImage: Bool {
      ["jpg", "jpeg", "png", "gif", "heic", "webp", "bmp"].contains((name as NSString).pathExtension.lowercased())
    }
  }
}
