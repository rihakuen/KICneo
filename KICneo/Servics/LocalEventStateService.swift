import Foundation

/// 説明会ごとの保存状態を端末内に保存する。
final class LocalEventStateService {
  private let storageKey: String
  private var states: [String: EventUserState] = [:]

  init(storageKey: String = "kic_event_user_states") {
    self.storageKey = storageKey
    load()
  }

  func status(for eventId: Int) -> EventApplicationStatus? {
    states[String(eventId)]?.status
  }

  func userState(for eventId: Int) -> EventUserState? {
    states[String(eventId)]
  }

  func setStatus(_ status: EventApplicationStatus, for eventId: Int) {
    var state = states[String(eventId)] ?? EventUserState(status: status)
    state.status = status
    states[String(eventId)] = state
    persist()
  }

  func remove(for eventId: Int) {
    states[String(eventId)] = nil
    persist()
  }

  /// 保存状態を別の ID へ移す（説明会の ID の付け方を変えたときの引き継ぎ用）。
  /// 移し先にすでに状態があればそちらを残し、移し元は消す。
  func moveState(from oldID: Int, to newID: Int) {
    guard oldID != newID, let state = states[String(oldID)] else { return }
    if states[String(newID)] == nil {
      states[String(newID)] = state
    }
    states[String(oldID)] = nil
    persist()
  }

  func ensureState(status: EventApplicationStatus, for eventId: Int) {
    states[String(eventId)] = EventUserState(status: status)
    persist()
  }

  private func load() {
    guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
    do {
      states = try JSONDecoder().decode([String: EventUserState].self, from: data)
    } catch {
      print("ローカル状態の読み込みに失敗: \(error.localizedDescription)")
    }
  }

  private func persist() {
    do {
      let data = try JSONEncoder().encode(states)
      UserDefaults.standard.set(data, forKey: storageKey)
    } catch {
      print("ローカル状態の保存に失敗: \(error.localizedDescription)")
    }
  }
}
