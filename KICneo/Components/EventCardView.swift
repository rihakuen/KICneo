import SwiftUI

/// 説明会画面の寸法。値はアプリ共通の AppTheme から取り、他のタブと同じ見た目にそろえる。
enum EventDesign {
  static let pageInset: CGFloat = AppTheme.Space.page
  static let cardRadius: CGFloat = AppTheme.Radius.large
  static let cardInset: CGFloat = AppTheme.Space.card
  static let background = AppTheme.background
  static let cardBackground = AppTheme.cardBackground
}

/// 説明会のカード。カード（概要）をタップすると、その場で下に広がって詳細を出す（もう一度タップで閉じる）。
/// 「気になる」と学校サイトのボタンは、広げた詳細のいちばん下に出る（EventDetailPanel）。
struct EventCardView<Detail: View>: View {
  let event: KICEvent
  let source: SchoolEvent?
  let now: Date
  let isApplying: Bool
  let isSaved: Bool
  let isExpanded: Bool
  var onToggleExpanded: () -> Void
  @ViewBuilder var detail: () -> Detail
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var deadline: EventApplicationDeadline { .init(source: source, now: now) }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Button(action: onToggleExpanded) { summary }
        .buttonStyle(CardPressStyle())
        .accessibilityIdentifier("event-summary-\(event.id)")
        .accessibilityHint(isExpanded ? "タップで詳細を閉じます" : "タップで詳細を表示します")
        .accessibilityAddTraits(isExpanded ? .isSelected : [])
      if isExpanded {
        detail()
          .padding(.horizontal, EventDesign.cardInset)
          .padding(.bottom, EventDesign.cardInset)
          .transition(reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: -8)))
      }
    }
    // 他のタブのカードと同じ背景・角丸・枠線・影。広がる途中の中身がカードの外にはみ出さないよう切り抜く
    .walletCard(cornerRadius: EventDesign.cardRadius)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("event-card-\(event.id)")
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.cardStack) {
      HStack(alignment: .top, spacing: AppTheme.Space.md) {
        VStack(alignment: .leading, spacing: 2) {
          Text("申込締切").font(AppTheme.Typography.label).foregroundStyle(AppTheme.textSecondary)
          Text(deadline.value).font(AppTheme.Typography.headline).monospacedDigit()
            .contentTransition(.numericText(countsDown: true))
            .animation(AppTheme.Motion.text(reduce: reduceMotion), value: deadline.value)
        }
        Spacer(minLength: 0)
        VStack(alignment: .trailing, spacing: 6) {
          if let format = event.eventFormat, !format.isEmpty { Text(format).font(AppTheme.Typography.label).foregroundStyle(AppTheme.textSecondary) }
          if isApplying { Text("申込済").font(AppTheme.Typography.label).foregroundStyle(AppTheme.primaryAction) }
          if isSaved {
            Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(AppTheme.primaryAction)
              .accessibilityLabel("気になるに登録済み")
          }
        }
      }
      Text(EventPresentation.companyTitle(event))
        .font(AppTheme.Typography.cardTitle)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      VStack(alignment: .leading, spacing: 5) {
        if let date = source?.date, !date.isEmpty {
          Text(date).font(AppTheme.Typography.body).monospacedDigit().foregroundStyle(AppTheme.textSecondary)
        }
        if isSaved, let source {
          let countdown = EventCountdown(timing: SchoolEventTiming(schedule: source.date, applicationPeriod: source.applyPeriod),
            applied: source.isApplied, status: source.status, now: now)
          if !countdown.label.hasPrefix("申込締切"), countdown.label != "開催日", countdown.label != "日程未定" {
            Text(countdown.value.isEmpty ? countdown.label : "\(countdown.label) \(countdown.value)")
              .font(AppTheme.Typography.caption).monospacedDigit()
          }
        }
      }
      HStack {
        Text(deadline.dateText).font(AppTheme.Typography.caption).monospacedDigit().foregroundStyle(AppTheme.textSecondary)
        Spacer(minLength: 12)
        // 開いているときは上向き（回転して切り替わる）
        Image(systemName: "chevron.down")
          .font(.caption.weight(.semibold))
          .foregroundStyle(AppTheme.textTertiary)
          .rotationEffect(.degrees(isExpanded ? 180 : 0))
          .accessibilityHidden(true)
      }
    }
    .padding(EventDesign.cardInset)
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(.primary)
  }
}

/// 共通の文字の切り替え。視差効果を減らす設定のときは、ぼかしと移動を行わない。
struct EventTextReveal: ViewModifier {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func body(content: Content) -> some View {
    content
      .transition(.blurReplace)
      .transaction { if reduceMotion { $0.animation = nil } }
  }
}

#Preview("説明会・カード") {
  @Previewable @State var expanded = false
  let source = DemoData.schoolEvents[0]
  EventCardView(event: EventViewModel.event(from: source),
    source: source,
    now: .now, isApplying: false, isSaved: true, isExpanded: expanded,
    onToggleExpanded: { withAnimation(.smooth(duration: 0.34)) { expanded.toggle() } }) {
      VStack(alignment: .leading, spacing: 12) {
        Divider()
        Text("（プレビュー）ここに詳細と「気になる」「学校サイト」が出ます").font(.subheadline)
      }
    }
    .padding(EventDesign.pageInset)
    .background(EventDesign.background)
}
