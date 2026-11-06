import Foundation

/// ユーザーが関心を持つタグ・卒業設定（ローカル保存）
final class UserPreferencesService {
  private let interestTagsKey = "kic_interest_tags"
  private let graduationDateKey = "kic_graduation_date"
  private let graduationLabelKey = "kic_graduation_label"
  private let jobHuntingCompletedKey = "kic_job_hunting_completed"

  var interestTags: [String] {
    get { UserDefaults.standard.stringArray(forKey: interestTagsKey) ?? [] }
    set { UserDefaults.standard.set(newValue, forKey: interestTagsKey) }
  }

  var graduationDate: Date {
    get {
      if let stored = UserDefaults.standard.object(forKey: graduationDateKey) as? Date {
        return stored
      }
      return Calendar.current.date(byAdding: .month, value: 6, to: Date()) ?? Date()
    }
    set { UserDefaults.standard.set(newValue, forKey: graduationDateKey) }
  }

  var graduationCountdownLabel: String {
    get {
      let value = UserDefaults.standard.string(forKey: graduationLabelKey)
      return value?.isEmpty == false ? value! : "卒業まで"
    }
    set { UserDefaults.standard.set(newValue, forKey: graduationLabelKey) }
  }

  var isJobHuntingCompleted: Bool {
    get { UserDefaults.standard.bool(forKey: jobHuntingCompletedKey) }
    set { UserDefaults.standard.set(newValue, forKey: jobHuntingCompletedKey) }
  }

  func toggleTag(_ tag: String) {
    var tags = interestTags
    if let index = tags.firstIndex(of: tag) {
      tags.remove(at: index)
    } else {
      tags.append(tag)
    }
    interestTags = tags
  }

  func isSelected(_ tag: String) -> Bool {
    interestTags.contains(tag)
  }
}
