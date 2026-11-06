import SwiftUI

/// 成績。学校ポータル「成績」ページの全科目を、学年次（1年次〜）ごと、または通算で並べる。
/// ふだんは評価（A〜E）だけを出し、科目をタップするとその科目の点数を表示する（右上のボタンで全科目まとめて表示）。
/// 値（点数・評価・単位・区分）はすべて学校の原文。まだ評価のない欄は「—」。
struct GradesScreen: View {
  @ObservedObject var school: SchoolViewModel
  /// 表示する範囲。nil のときは最新の年度。
  @State private var selection: Scope?
  /// 点数を表示している科目
  @State private var revealed: Set<String> = []
  @State private var revealAll = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  enum Scope: Hashable {
    case year(String)
    case all
  }

  /// 古い年度から（1年次、2年次…の順）。4年制や留年で年度が増えても、そのまま並ぶ。
  private var years: [String] {
    Array(Set(school.grades.map(\.year))).sorted()
  }

  private var scope: Scope {
    if let selection {
      if case .year(let y) = selection, !years.contains(y) { return years.last.map(Scope.year) ?? .all }
      return selection
    }
    return years.last.map(Scope.year) ?? .all
  }

  private func yearLabel(_ year: String) -> String {
    "\((years.firstIndex(of: year) ?? 0) + 1)年次"
  }

  private var records: [GradeRecord] {
    switch scope {
    case .year(let y): school.grades.filter { $0.year == y }
    case .all: school.grades
    }
  }

  var body: some View {
    ZStack {
      AppBackgroundView()
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.cardGap) {
          if school.grades.isEmpty {
            emptyState
          } else {
            scopePicker
            summary
            switch scope {
            case .year:
              ForEach(termGroups(records), id: \.title) { group in
                section(group.title, group.items)
              }
            case .all:
              ForEach(years.reversed(), id: \.self) { year in
                section("\(yearLabel(year)) · \(year)年度", school.grades.filter { $0.year == year })
              }
            }
          }
        }
        .padding(AppTheme.Space.page)
        .animation(AppTheme.Motion.transition(reduce: reduceMotion), value: scope)
      }
    }
    .foregroundStyle(AppTheme.textPrimary)
    .navigationTitle("成績")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !school.grades.isEmpty {
        ToolbarItem(placement: .topBarTrailing) {
          Button(revealAll ? "点数を隠す" : "点数を表示", systemImage: revealAll ? "eye.slash" : "eye") {
            AppHaptics.selection()
            withAnimation(AppTheme.Motion.feedback(reduce: reduceMotion)) {
              revealAll.toggle()
              if !revealAll { revealed = [] }
            }
          }
          .contentTransition(.symbolEffect(.replace))
        }
      }
    }
    .task { await school.loadGrades() }
    .refreshable { await school.loadGrades(force: true) }
  }

  @ViewBuilder private var emptyState: some View {
    if school.isLoadingGrades {
      ProgressView("読み込み中…").frame(maxWidth: .infinity).padding(.vertical, 40)
    } else if school.gradesLoadFailed {
      EmptyStateView(icon: "exclamationmark.triangle", title: "取得できませんでした", message: "下に引いて再読み込みしてください。")
    } else {
      EmptyStateView(icon: "tray", title: "成績はまだありません", message: "学校のポータルに成績が登録されると、ここに表示されます。")
    }
  }

  // MARK: 範囲の切り替え

  private var scopeBinding: Binding<Scope> {
    Binding(
      get: { scope },
      set: { newValue in
        AppHaptics.selection()
        withAnimation(AppTheme.Motion.transition(reduce: reduceMotion)) { selection = newValue }
      })
  }

  /// 年度が4つまでなら分段（1年次〜4年次＋通算）、それより多いときはメニューにする
  @ViewBuilder private var scopePicker: some View {
    let picker = Picker("表示する学年", selection: scopeBinding) {
      ForEach(years, id: \.self) { year in
        Text(yearLabel(year)).tag(Scope.year(year))
      }
      Text("通算").tag(Scope.all)
    }
    if years.count <= 4 {
      picker.pickerStyle(.segmented)
    } else {
      picker.pickerStyle(.menu)
    }
  }

  // MARK: まとめ

  /// 科目数・単位の合計・評価の出た科目数（平均点は出さない）
  private var summary: some View {
    let credits = records.compactMap { GradeRecord.number($0.credits) }.reduce(0, +)
    let graded = records.filter { record in record.gradeSlots.contains { !$0.grade.isEmpty } }.count
    let title: String = switch scope {
    case .year(let y): "\(y)年度 · \(yearLabel(y))"
    case .all: years.count > 1 ? "通算 · \(years.first ?? "")〜\(years.last ?? "")年度" : "通算"
    }
    return VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text(title)
        .font(AppTheme.Typography.label)
        .foregroundStyle(AppTheme.textSecondary)
        .contentTransition(.numericText())
      HStack(spacing: 0) {
        summaryItem(value: "\(records.count)", unit: "科目", label: "履修")
        Divider().frame(height: 36)
        summaryItem(value: credits.formatted(.number.precision(.fractionLength(0...1))), unit: "単位", label: "合計")
        Divider().frame(height: 36)
        summaryItem(value: "\(graded)", unit: "科目", label: "評価済み")
      }
    }
    .padding(AppTheme.Space.card)
    .walletCard()
  }

  private func summaryItem(value: String, unit: String, label: String) -> some View {
    VStack(spacing: 2) {
      HStack(alignment: .firstTextBaseline, spacing: 2) {
        Text(value)
          .font(AppTheme.Typography.stat)
          .monospacedDigit()
          .contentTransition(.numericText())
        Text(unit).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.textSecondary)
      }
      Text(label)
        .font(AppTheme.Typography.caption)
        .foregroundStyle(AppTheme.textSecondary)
        .lineLimit(1).minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }

  // MARK: 科目

  /// 通年 → 前期 → 後期 → その他の順。各グループの中は学校の並び順のまま。
  private func termGroups(_ items: [GradeRecord]) -> [(title: String, items: [GradeRecord])] {
    let order = ["通年", "前期", "後期"]
    var groups: [String: [GradeRecord]] = [:]
    var others: [String] = []
    for record in items {
      let key = order.first { record.term.contains($0) } ?? record.term
      if groups[key] == nil, !order.contains(key) { others.append(key) }
      groups[key, default: []].append(record)
    }
    return (order + others).compactMap { term in groups[term].map { (term, $0) } }
  }

  private func section(_ title: String, _ items: [GradeRecord]) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(title).font(AppTheme.Typography.label)
        Text("\(items.count)").font(AppTheme.Typography.label).monospacedDigit().foregroundStyle(AppTheme.textSecondary)
      }
      .padding(.leading, AppTheme.Space.xs)
      VStack(spacing: 0) {
        ForEach(items) { record in
          gradeRow(record)
          if record.id != items.last?.id { Divider().padding(.leading, AppTheme.Space.card) }
        }
      }
      .walletCard()
    }
  }

  /// 1科目の行。タップで、その科目の点数を表示 / 非表示にする。
  private func gradeRow(_ record: GradeRecord) -> some View {
    let showsScore = revealAll || revealed.contains(record.id)
    return Button {
      AppHaptics.selection()
      withAnimation(AppTheme.Motion.feedback(reduce: reduceMotion)) {
        if revealed.contains(record.id) { revealed.remove(record.id) } else { revealed.insert(record.id) }
      }
    } label: {
      HStack(alignment: .center, spacing: AppTheme.Space.md) {
        VStack(alignment: .leading, spacing: 3) {
          Text(record.subject)
            .font(AppTheme.Typography.headline)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
          Text([record.term, record.category, record.credits.isEmpty ? "" : "\(record.credits)単位"]
            .filter { !$0.isEmpty }.joined(separator: " · "))
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.textSecondary)
        }
        Spacer(minLength: AppTheme.Space.sm)
        HStack(spacing: AppTheme.Space.sm) {
          ForEach(record.gradeSlots, id: \.label) { slot in
            gradeBadge(slot, showsLabel: record.gradeSlots.count > 1, showsScore: showsScore)
          }
        }
      }
      .padding(.horizontal, AppTheme.Space.card)
      .padding(.vertical, AppTheme.Space.md)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .buttonStyle(CardPressStyle())
    .accessibilityElement(children: .combine)
    .accessibilityHint(showsScore ? "タップで点数を隠します" : "タップで点数を表示します")
  }

  /// 評価の文字（A〜E）を色付きの角丸に。点数はその下に、表示中のときだけ出す（高さは常に確保して行が跳ねないようにする）。
  private func gradeBadge(_ slot: (label: String, score: String, grade: String), showsLabel: Bool, showsScore: Bool) -> some View {
    let tint = color(for: slot.grade)
    let graded = !slot.grade.isEmpty
    return VStack(spacing: 2) {
      if showsLabel {
        Text(slot.label).font(.caption2.weight(.semibold)).foregroundStyle(AppTheme.textSecondary)
      }
      Text(graded ? slot.grade : "—")
        .font(.title3.bold())
        .foregroundStyle(graded ? tint : AppTheme.textTertiary)
        .frame(width: 40, height: 40)
        .background(graded ? tint.opacity(0.14) : AppTheme.elevatedBackground,
          in: .rect(cornerRadius: AppTheme.Radius.chip, style: .continuous))
      Text(slot.score.isEmpty ? "—" : "\(slot.score)点")
        .font(.caption2.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(AppTheme.textSecondary)
        .opacity(showsScore ? 1 : 0)
        .blur(radius: showsScore || reduceMotion ? 0 : 4)
        .accessibilityHidden(!showsScore)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(graded
      ? "\(slot.label) 評価\(slot.grade)" + (showsScore && !slot.score.isEmpty ? " \(slot.score)点" : "")
      : "\(slot.label) 未評価")
  }

  private func color(for grade: String) -> Color {
    switch grade.applyingTransform(.fullwidthToHalfwidth, reverse: false)?.uppercased() ?? grade {
    case "A", "S": return AppTheme.success
    case "B": return AppTheme.primaryAction
    case "C": return AppTheme.textSecondary
    case "D": return AppTheme.warning
    case "E", "F": return AppTheme.holiday
    default: return AppTheme.textSecondary
    }
  }
}
