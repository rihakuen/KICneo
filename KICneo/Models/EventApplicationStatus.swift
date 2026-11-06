import Foundation

/// 端末内の保存状態。保存（ブックマーク）は `interested` で表す。
/// `applied` / `attended` は以前のバージョンの保存データを読めるように残している（今は保存として扱う）。
enum EventApplicationStatus: String, Codable, CaseIterable {
  case interested = "気になる"
  case applied = "申込済み"
  case attended = "参加済み"

  var iconName: String {
    switch self {
    case .interested: return "star.fill"
    case .applied: return "paperplane.fill"
    case .attended: return "checkmark.circle.fill"
    }
  }

  var tintName: String {
    switch self {
    case .interested: return "amber"
    case .applied: return "blue"
    case .attended: return "green"
    }
  }
}

/// 保存済みの説明会ごとの状態。以前のバージョンが保存したメモは、読み込み時に無視される。
struct EventUserState: Codable, Equatable {
  var status: EventApplicationStatus
}
