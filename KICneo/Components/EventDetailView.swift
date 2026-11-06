import SwiftUI

/// 学校の詳細を同じカードの中に展開する。取得とキャッシュは既存のサービスを使う。
struct EventDetailView: View {
  @ObservedObject var viewModel: EventViewModel
  @ObservedObject var school: SchoolViewModel
  let event: KICEvent
  var previewOnly = false
  @State private var portal: SchoolEventDetailResult?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
      Divider()
      Text(event.title).font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      detailBody
        .id(detailPhase)
        .modifier(EventTextReveal())
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(reduceMotion ? nil : .smooth(duration: 0.34), value: portal)
    .transaction { if reduceMotion { $0.animation = nil } }
    .task(id: viewModel.schoolEvent(for: event)?.id) {
      if previewOnly { portal = .loaded(sampleDetail); return }
      await loadDetail()
    }
  }

  private var detailPhase: String {
    switch portal {
    case nil: "loading"
    case .loaded: "loaded"
    case .failed: "failed"
    case .unavailable: "unavailable"
    }
  }

  @ViewBuilder private var detailBody: some View {
    switch portal {
    case nil:
      ProgressView("詳細を読み込み中…").font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
    case .loaded(let detail):
      VStack(alignment: .leading, spacing: 18) {
        ForEach(detailRows(detail), id: \.0) { row in
          VStack(alignment: .leading, spacing: 4) {
            Text(row.0).font(.caption).foregroundStyle(.secondary)
            Text(row.1).font(.subheadline).textSelection(.enabled)
          }
        }
        if !detail.content.isEmpty {
          Text(attributed(detail.content))
            .font(.body).lineSpacing(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        ForEach(Array(detail.attachments.enumerated()), id: \.offset) { _, name in
          Label(name, systemImage: "paperclip").font(.subheadline).foregroundStyle(.secondary)
        }
      }
    case .failed:
      VStack(alignment: .leading, spacing: 12) {
        Text("詳細を読み込めませんでした。")
          .font(.subheadline).foregroundStyle(.secondary)
        Button("再読み込み") { Task { await loadDetail() } }
          .frame(minHeight: 44)
      }
    case .unavailable:
      Text("詳細は学校サイトで確認してください。")
        .font(.subheadline).foregroundStyle(.secondary)
    }
  }

  private func loadDetail() async {
    guard let source = viewModel.schoolEvent(for: event) else { portal = .unavailable; return }
    let cached = school.cachedEventDetail(title: source.title, date: source.date)
    if let cached { portal = .loaded(cached) }
    let fresh = await school.eventDetail(title: source.title, date: source.date)
    guard !Task.isCancelled else { return }
    if case .loaded = fresh { portal = fresh }
    else if cached == nil { portal = fresh }
  }

  private func detailRows(_ detail: SchoolEventDetail) -> [(String, String)] {
    [("開催日時", detail.date), ("会場", detail.room), ("申込期間", detail.applyPeriod),
     ("定員", detail.capacity), ("残席", detail.remaining), ("申込状況", detail.status)]
      .filter { !$0.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  private func attributed(_ runs: [SchoolEventDetail.Run]) -> AttributedString {
    var text = AttributedString()
    for run in runs {
      var part = AttributedString(run.text)
      if let url = run.url { part.link = url }
      text += part
    }
    return text
  }

  private var sampleDetail: SchoolEventDetail {
    DemoData.previewDetail(title: event.title, source: viewModel.schoolEvent(for: event))
  }
}
