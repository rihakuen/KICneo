import SwiftUI

struct BrowseEventsView: View {
  @ObservedObject var viewModel: EventViewModel
  @ObservedObject var school: SchoolViewModel
  @Binding var showInterestSheet: Bool
  var onRefresh: () async -> Void
  @Binding var showGraduationSettings: Bool
  @Binding var showEndJobHuntingConfirm: Bool
  // プレビューでは学校への通信も、データの変更も行わない。
  var previewOnly = false
  var previewActionID: Int? = nil
  var previewDetailID: Int? = nil
  /// 詳細シートで開いている説明会
  /// 詳細を広げている説明会（同時に1枚だけ）
  @State private var expandedEventID: Int?
  @Environment(\.openURL) private var openURL
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        DashboardHeaderView(viewModel: viewModel)
        Picker("表示", selection: $viewModel.selectedStatusFilter) {
          Text("すべて").tag(Optional<EventStatusFilter>.none)
          Text("気になる").tag(Optional(EventStatusFilter.saved))
          Text("申込済").tag(Optional(EventStatusFilter.applying))
        }
        .pickerStyle(.segmented)
        .accessibilityLabel("説明会の絞り込み")
        if let tag = viewModel.selectedTagFilter {
          HStack {
            Text(tag).font(.subheadline)
            Spacer()
            Button("解除") { viewModel.selectedTagFilter = nil }
          }
        }
        if viewModel.displayEvents.isEmpty, school.schoolEventsLoadFailed {
          ConnectionNotice(text: "学校の説明会一覧を取得できませんでした。下に引いて再読み込みしてください。")
        }
        TimelineView(.periodic(from: .now, by: 60)) { context in
          eventsSection(now: context.date)
        }
      }
      .padding(.horizontal, EventDesign.pageInset)
      .padding(.bottom, 32)
    }
    .background(EventDesign.background)
    .navigationTitle("説明会")
    .navigationBarTitleDisplayMode(.large)
    .searchable(text: $viewModel.searchText, prompt: "企業名で検索")
    .autocorrectionDisabled()
    .tint(AppTheme.primaryAction)
    .refreshable { if !previewOnly { await onRefresh() } }
    .toolbar { ToolbarItem(placement: .topBarTrailing) { optionsMenu } }
    // 一覧が変わって、広げていた説明会が見えなくなったら閉じる
    .onChange(of: viewModel.filteredEvents.map(\.id)) { _, ids in
      if let expandedEventID, !ids.contains(expandedEventID) { self.expandedEventID = nil }
    }
    .onAppear {
      if previewOnly {
        expandedEventID = previewDetailID
      }
    }
  }

  @ViewBuilder private func eventsSection(now: Date) -> some View {
    if school.isLoadingSchoolEvents && viewModel.displayEvents.isEmpty {
      ProgressView("読み込み中…").frame(maxWidth: .infinity).padding(.vertical, 40)
    } else if viewModel.filteredEvents.isEmpty {
      ContentUnavailableView(viewModel.displayEvents.isEmpty ? "説明会はありません" : "見つかりませんでした",
        systemImage: "magnifyingglass",
        description: Text(viewModel.displayEvents.isEmpty ? "下に引いて更新できます。" : "検索や絞り込みを変更してください。"))
    } else {
      LazyVStack(spacing: AppTheme.Space.cardGap) {
        HStack(alignment: .firstTextBaseline) {
          Text(viewModel.selectedStatusFilter == .saved ? "気になる" : "締切が近い順")
            .font(.subheadline.weight(.semibold))
            .contentTransition(.interpolate)
          Spacer()
          Text("\(viewModel.filteredEvents.count)件").font(.footnote).monospacedDigit().foregroundStyle(.secondary)
            .contentTransition(.numericText(value: Double(viewModel.filteredEvents.count)))
        }
        .animation(AppTheme.Motion.text(reduce: reduceMotion), value: viewModel.filteredEvents.count)
        .animation(AppTheme.Motion.text(reduce: reduceMotion), value: viewModel.selectedStatusFilter)
        .padding(.bottom, AppTheme.Space.xs)
        ForEach(EventApplicationDeadline.ordered(viewModel.filteredEvents, source: { viewModel.schoolEvent(for: $0) }, now: now)) { event in
          eventRow(event, now: now)
        }
      }
    }
  }

  private func eventRow(_ event: KICEvent, now: Date) -> some View {
    // カードをタップすると、その場で下に広がって詳細を出す。「気になる」と学校サイトは広げた詳細のいちばん下
    let expanded = expandedEventID == event.id
    return EventCardView(event: event, source: viewModel.schoolEvent(for: event), now: now,
      isApplying: viewModel.isApplying(event), isSaved: viewModel.isSaved(event), isExpanded: expanded,
      onToggleExpanded: {
        AppHaptics.light()
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .smooth(duration: 0.38)) {
          expandedEventID = expanded ? nil : event.id
        }
      }) {
        EventDetailPanel(viewModel: viewModel, school: school, event: event, previewOnly: previewOnly,
          onOpenSchool: openSchool, onToggleSaved: { toggleSaved(event) })
      }
  }

  private func openSchool() {
    AppHaptics.light()
    if !previewOnly, let url = URL(string: "https://pt.kobedenshi.ac.jp/portal/mobile/recruit/EventSP.aspx") { openURL(url) }
  }

  private func toggleSaved(_ event: KICEvent) {
    guard !previewOnly else { return }
    if viewModel.isSaved(event) { AppHaptics.light() }
    viewModel.toggleSaved(event)
  }

  private var optionsMenu: some View {
    Menu {
      if !viewModel.availableTags.isEmpty {
        Menu("種類で絞り込む") {
          Button("すべて") { viewModel.selectedTagFilter = nil }
          ForEach(viewModel.availableTags, id: \.self) { tag in
            Button { viewModel.selectedTagFilter = tag } label: {
              if viewModel.selectedTagFilter == tag { Label(tag, systemImage: "checkmark") }
              else { Text(tag) }
            }
          }
        }
      }
      Button("関心タグ", systemImage: "tag") { showInterestSheet = true }
      Button("卒業日を設定", systemImage: "calendar") { showGraduationSettings = true }
      Divider()
      Button("就活を終了", systemImage: "checkmark.circle") { showEndJobHuntingConfirm = true }
    } label: {
      Image(systemName: "ellipsis").accessibilityLabel("表示と設定")
    }
  }
}

private struct EventScreenPreview: View {
  @StateObject private var viewModel: EventViewModel
  @StateObject private var school = SchoolViewModel()
  let expanded: Bool
  let showsDetails: Bool
  init(expanded: Bool = false, showsDetails: Bool = false) {
    self.expanded = expanded
    self.showsDetails = showsDetails
    let model = EventViewModel()
    model.schoolEvents = DemoData.schoolEvents
    _viewModel = StateObject(wrappedValue: model)
  }
  var body: some View {
    NavigationStack {
      BrowseEventsView(viewModel: viewModel, school: school, showInterestSheet: .constant(false),
        onRefresh: {}, showGraduationSettings: .constant(false), showEndJobHuntingConfirm: .constant(false),
        previewOnly: true, previewActionID: expanded ? viewModel.displayEvents.first?.id : nil,
        previewDetailID: showsDetails ? viewModel.displayEvents.first?.id : nil)
    }
  }
}

#Preview("説明会・ライト") { EventScreenPreview() }
#Preview("説明会・操作ページ") { EventScreenPreview(expanded: true) }
#Preview("説明会・詳細を展開") { EventScreenPreview(expanded: true, showsDetails: true) }
#Preview("説明会・ダーク") { EventScreenPreview(expanded: true, showsDetails: true).preferredColorScheme(.dark) }
#Preview("説明会・大きな文字") { EventScreenPreview(expanded: true).environment(\.dynamicTypeSize, .accessibility3) }
