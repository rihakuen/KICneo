import EventKit
import EventKitUI
import SwiftUI

/// iPhone の「カレンダー」App に予定を追加する、iOS 標準の画面（タイトル・日時・場所を入れた状態で開く）。
/// この画面はアプリとは別のプロセスで動き、ユーザーが「追加」を押したときだけ保存されるので、
/// カレンダーへのアクセス許可は求めない（アプリからカレンダーの中身は読めない）。
struct CalendarEventSheet: UIViewControllerRepresentable {
  let draft: CalendarDraft
  /// 閉じたときに呼ぶ。カレンダーに追加されたら true
  var onFinish: (_ added: Bool) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onFinish: onFinish)
  }

  func makeUIViewController(context: Context) -> EKEventEditViewController {
    let store = EKEventStore()
    let event = EKEvent(eventStore: store)
    event.title = draft.title
    event.startDate = draft.start
    event.endDate = draft.end
    event.isAllDay = draft.isAllDay
    event.timeZone = AttendanceRatePeriod.calendar.timeZone
    event.location = draft.location
    event.notes = draft.notes

    let controller = EKEventEditViewController()
    controller.eventStore = store
    controller.event = event
    controller.editViewDelegate = context.coordinator
    return controller
  }

  func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {
    context.coordinator.onFinish = onFinish
  }

  final class Coordinator: NSObject, EKEventEditViewDelegate {
    var onFinish: (Bool) -> Void

    init(onFinish: @escaping (Bool) -> Void) {
      self.onFinish = onFinish
    }

    func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
      onFinish(action == .saved)
    }
  }
}
