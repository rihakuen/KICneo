import Foundation

/// 時間割（月カレンダー）の1コマ。`period` は学校の原文（例: "1限"）。
nonisolated struct TimetableLesson: Identifiable, Codable, Sendable, Equatable {
  var id = UUID()
  let period: String
  let name: String

  private enum CodingKeys: String, CodingKey { case period, name }
}

/// 時間割の1日分。授業がない日は `lessons` が空。
nonisolated struct TimetableDay: Identifiable, Codable, Sendable, Equatable {
  let date: Date
  let lessons: [TimetableLesson]
  var id: Date {
    date
  }
}
