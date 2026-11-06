import SwiftUI

// MARK: - 学校のデータの型（SchoolClient が取得し、画面はデータを受け取るだけ）
nonisolated struct AttendancePeriod: Identifiable, Codable, Equatable, Sendable {
  let number: Int
  let rawStatus: String
  var id: Int {
    number
  }
}

nonisolated struct AttendanceDay: Identifiable, Codable, Equatable, Sendable {
  let date: Date
  let periods: [AttendancePeriod]
  var id: Date {
    date
  }
}

/// 就職活動入力ページの活動1件（項目はすべて学校のページの原文）。
nonisolated struct HuntActivity: Identifiable, Sendable, Codable, Equatable {
  var id = UUID() // 保存しない。読み込むたびに作り直す
  let year: String
  let date: String
  let kind: String
  let periods: String
  let mode: String
  let attachment: String
  /// 添付ファイルのリンク（学校ページの原文。例: `/portal\kouketu_tempfile\…png`）
  let attachmentHref: String?
  let approval: String
  let company: String
  let jobType: String
  let location: String
  let result: String
  let resultDate: String

  private enum CodingKeys: String, CodingKey {
    case year, date, kind, periods, mode, attachment, attachmentHref, approval, company, jobType, location, result, resultDate
  }

  /// 内容が同じかどうか（id は読み込みのたびに変わるので比べない）。変わっていないときは画面を更新しないために使う。
  static func == (lhs: HuntActivity, rhs: HuntActivity) -> Bool {
    lhs.year == rhs.year && lhs.date == rhs.date && lhs.kind == rhs.kind && lhs.periods == rhs.periods
      && lhs.mode == rhs.mode && lhs.attachment == rhs.attachment && lhs.attachmentHref == rhs.attachmentHref && lhs.approval == rhs.approval
      && lhs.company == rhs.company && lhs.jobType == rhs.jobType && lhs.location == rhs.location
      && lhs.result == rhs.result && lhs.resultDate == rhs.resultDate
  }

  /// 添付ファイルの URL。学校のリンクは `/portal\…` とバックスラッシュ区切りなので、スラッシュに直してホスト名を補う。
  var attachmentURL: URL? {
    guard let href = attachmentHref, !href.isEmpty else { return nil }
    var path = href.replacingOccurrences(of: "\\", with: "/")
    if !path.hasPrefix("http") {
      path = "https://pt.kobedenshi.ac.jp" + (path.hasPrefix("/") ? path : "/" + path)
    }
    return URL(string: path) ?? path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
  }

  /// ページをまたいだ重複の除去用（学校が同じページを重ねて返したとき）。
  var key: String {
    [year, date, kind, periods, company, jobType].joined(separator: "|")
  }
}

nonisolated struct StudentCardData: Codable, Equatable, Sendable {
  let displayName: String
  let studentNumber: String
  /// 学科（学生カルテに表示がある場合）。以前の保存内容には無いので任意。
  var department: String? = nil
  /// 学生カルテの項目（見出し → 値、学校の原文）。以前の保存内容には無いので任意。
  var fields: [String: String]? = nil

  /// 学生カルテに出る項目。表示はこの順番。
  static let cardLabels = ["学年", "クラス", "学生NO", "学籍番号", "学科", "専攻", "コース", "氏名", "ふりがな", "生年月日", "性別", "居住状態"]

  func value(_ label: String) -> String? {
    switch label {
    case "氏名": return displayName
    case "学籍番号": return studentNumber
    case "学科": return fields?[label] ?? department
    default: return fields?[label]
    }
  }
}

struct ConnectionNotice: View {
  let text: String
  var body: some View {
    Label(text, systemImage: "info.circle")
      .font(AppTheme.Typography.caption)
      .foregroundStyle(AppTheme.textSecondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(AppTheme.Space.md)
      // ページの背景（systemGroupedBackground）の上に直接置くので、カードと同じ色で浮かせる
      .background(AppTheme.cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
  }
}

struct SchoolLoginView: View {
  @ObservedObject var school: SchoolViewModel
  let onLoggedIn: () -> Void
  @State private var username = ""
  @State private var password = ""
  @FocusState private var focused: Field?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private enum Field { case username, password }

  var body: some View {
    ZStack {
      AppBackgroundView()
      ScrollView {
        VStack(alignment: .leading, spacing: 32) {
          VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
            Image(systemName: "graduationcap.fill")
              .font(.system(size: 24, weight: .medium))
              .foregroundStyle(AppTheme.primaryAction)
              .frame(width: 56, height: 56)
              .background(AppTheme.formatTagBackground)
              .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
              .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
              Text("KICneo")
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
              Text("学校ポータルのアカウントでログイン")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.textSecondary)
            }
          }
          .padding(.top, AppTheme.Space.section)

          VStack(alignment: .leading, spacing: AppTheme.Space.section) {
            VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
              Text("ログインID")
                .font(.subheadline.weight(.medium))
              TextField("IDを入力", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .username)
                .submitLabel(.next)
                .onSubmit { focused = .password }
                .schoolField()
                .disabled(school.isLoading)
            }

            VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
              Text("パスワード")
                .font(.subheadline.weight(.medium))
              SecureField("パスワードを入力", text: $password)
                .textContentType(.password)
                .focused($focused, equals: .password)
                .schoolField()
                .disabled(school.isLoading)
            }

            if let error = school.errorMessage {
              Label(error, systemImage: "exclamationmark.circle")
                .font(AppTheme.Typography.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
            }

            Button {
              focused = nil
              Task {
                await school.login(id: username, password: password)
                if school.isLoggedIn {
                  password = ""
                  onLoggedIn()
                }
              }
            } label: {
              HStack(spacing: AppTheme.Space.sm) {
                if school.isLoading {
                  ProgressView()
                    .tint(.white)
                    .accessibilityHidden(true)
                }
                Text(school.isLoading ? "ログイン中…" : "ログイン")
                  .contentTransition(.interpolate)
              }
              .animation(AppTheme.Motion.text(reduce: reduceMotion), value: school.isLoading)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(school.isLoading || username.isEmpty || password.isEmpty)
            .opacity(username.isEmpty || password.isEmpty ? 0.5 : 1)
          }
          .padding(AppTheme.Space.card)
          .walletCard()

          Label("パスワードは端末のキーチェーンに保存されます。", systemImage: "lock")
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(AppTheme.textPrimary)
        .padding(AppTheme.Space.page)
        .frame(maxWidth: 480)
        .frame(maxWidth: .infinity)
      }
      .scrollDismissesKeyboard(.interactively)
    }
  }
}

private struct SchoolFieldModifier: ViewModifier {
  func body(content: Content) -> some View {
    content
      .padding(AppTheme.Space.lg)
      .frame(minHeight: 52)
      .background(AppTheme.elevatedBackground)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous)
          .strokeBorder(AppTheme.border, lineWidth: 0.5)
      }
  }
}

extension View {
  func schoolField() -> some View {
    modifier(SchoolFieldModifier())
  }
}

struct SchoolServicesScreen: View {
  @ObservedObject var school: SchoolViewModel
  let onShowLogin: () -> Void
  @AppStorage("ui_haptics_enabled") private var hapticsEnabled = true
  var body: some View {
    ZStack {
      AppBackgroundView()
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.cardGap) {
          VStack(alignment: .leading, spacing: AppTheme.Space.cardStack) {
            Label("学校アカウント", systemImage: "person.crop.circle")
              .font(AppTheme.Typography.headline)
            if school.isLoggedIn {
              Text(school.accountID ?? "接続済み").font(AppTheme.Typography.stat)
              Text("学校ポータルに接続済みです。")
                .font(AppTheme.Typography.body).foregroundStyle(AppTheme.textSecondary)
              Button("ログアウト") { Task { await school.logout(); onShowLogin() } }
                .buttonStyle(SecondaryButtonStyle())
            } else {
              Text("未接続").font(AppTheme.Typography.stat)
              Text("ログインすると、あなたの学校情報を確認できます。")
                .font(AppTheme.Typography.body).foregroundStyle(AppTheme.textSecondary)
              Button("ログイン", action: onShowLogin)
                .buttonStyle(PrimaryButtonStyle())
            }
          }.padding(AppTheme.Space.card).walletCard()
          VStack(spacing: 0) {
            NavigationLink { StudentCardScreen(school: school) } label: {
              serviceRow("学生証", subtitle: "氏名・学籍番号・学科を表示", icon: "person.text.rectangle")
            }
            Divider().padding(.leading, AppTheme.Space.card + 32 + AppTheme.Space.md)
            NavigationLink { GradesScreen(school: school) } label: {
              serviceRow("成績", subtitle: "科目ごとの点数と評価", icon: "chart.bar.doc.horizontal")
            }
          }.buttonStyle(CardPressStyle()).walletCard()
          VStack(alignment: .leading, spacing: AppTheme.Space.md) {
            Toggle("操作時の触覚フィードバック", isOn: $hapticsEnabled)
              .tint(AppTheme.primaryAction)
            Text("重要な操作に短いフィードバックを付けます。動きを減らす設定は端末の設定に従います。")
              .font(AppTheme.Typography.caption).foregroundStyle(AppTheme.textSecondary)
          }.padding(AppTheme.Space.card).walletCard()
          ConnectionNotice(text: "学校データはこの端末にのみ取得され、共有データベースには送信されません。")
        }.padding(AppTheme.Space.page)
      }
    }
    .foregroundStyle(AppTheme.textPrimary)
    .navigationTitle("個人情報")
    .navigationBarTitleDisplayMode(.large)
  }

  private func serviceRow(_ title: String, subtitle: String, icon: String) -> some View {
    HStack(spacing: AppTheme.Space.md) {
      Image(systemName: icon).font(.title3).foregroundStyle(AppTheme.primaryAction).frame(width: 32)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(AppTheme.Typography.headline)
        Text(subtitle).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.textSecondary)
      }
      Spacer(minLength: 0)
      Image(systemName: "chevron.right").font(AppTheme.Typography.caption).foregroundStyle(AppTheme.textTertiary)
    }
    .foregroundStyle(AppTheme.textPrimary)
    .padding(AppTheme.Space.card)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct LeaveApplicationScreen: View {
  @ObservedObject var school: SchoolViewModel
  @State private var showEntry = false
  var body: some View {
    ZStack {
      AppBackgroundView()
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.cardGap) {
          if school.huntActivities.isEmpty {
            if school.isLoadingHunt {
              ProgressView("読み込み中…").frame(maxWidth: .infinity)
            } else if school.huntLoadFailed {
              EmptyStateView(icon: "exclamationmark.triangle", title: "取得できませんでした", message: "下に引いて再読み込みしてください。")
            } else {
              EmptyStateView(icon: "tray", title: "まだ登録がありません", message: "学校のポータルで就職活動を登録すると、ここに表示されます。")
            }
          } else {
            ForEach(school.huntActivities) { activity in
              NavigationLink { HuntActivityDetailScreen(opened: activity, school: school) } label: {
                huntCard(activity)
              }
              .buttonStyle(CardPressStyle())
            }
            if school.isLoadingHunt {
              HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("続きを読み込み中…").font(AppTheme.Typography.caption).foregroundStyle(AppTheme.textSecondary)
              }.frame(maxWidth: .infinity)
            }
          }
        }.padding(AppTheme.Space.page)
      }
    }
    .foregroundStyle(AppTheme.textPrimary)
    .task { await school.loadHuntActivities() }
    .refreshable { await school.loadHuntActivities(force: true) }
    .navigationTitle("就職活動")
    .navigationBarTitleDisplayMode(.large)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button { showEntry = true } label: { Image(systemName: "plus") }
          .accessibilityLabel("就職活動を追加")
      }
    }
    .sheet(isPresented: $showEntry) { HuntEntryView(school: school) }
  }

  private func huntCard(_ a: HuntActivity) -> some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      HStack(alignment: .firstTextBaseline) {
        Text(a.date).font(AppTheme.Typography.bodyEmphasis)
        if !a.kind.isEmpty {
          Text(a.kind).font(AppTheme.Typography.captionEmphasis)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(AppTheme.formatTagBackground)
            .clipShape(Capsule())
        }
        Spacer()
        if !a.approval.isEmpty {
          Text(a.approval).font(AppTheme.Typography.captionEmphasis)
            .foregroundStyle(a.approval.contains("承認") && !a.approval.contains("未") ? AppTheme.success : AppTheme.warning)
        }
        Image(systemName: "chevron.right")
          .font(AppTheme.Typography.captionEmphasis)
          .foregroundStyle(AppTheme.textTertiary)
      }
      Text(a.company.isEmpty ? "—" : a.company).font(AppTheme.Typography.headline)
      if !a.jobType.isEmpty || !a.location.isEmpty {
        Text([a.jobType, a.location].filter { !$0.isEmpty }.joined(separator: " · "))
          .font(AppTheme.Typography.body).foregroundStyle(AppTheme.textSecondary)
      }
      let detail = [a.periods, a.mode].filter { !$0.isEmpty }.joined(separator: " · ")
      if !detail.isEmpty {
        Text(detail).font(AppTheme.Typography.caption).foregroundStyle(AppTheme.textSecondary)
      }
      if !a.result.isEmpty {
        Text("結果 \(a.result)" + (a.resultDate.isEmpty ? "" : " · \(a.resultDate)"))
          .font(AppTheme.Typography.caption).foregroundStyle(AppTheme.textSecondary)
      }
      if !a.attachment.isEmpty {
        Label(a.attachment, systemImage: "paperclip").font(AppTheme.Typography.caption).foregroundStyle(AppTheme.textSecondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(AppTheme.Space.card).walletCard()
  }
}

struct StudentCardScreen: View {
  @ObservedObject var school: SchoolViewModel
  private var student: StudentCardData? {
    school.student
  }

  private var statusText: String {
    if student != nil {
      return "学校情報"
    }
    if school.isLoadingStudent {
      return "読み込み中…"
    }
    return school.studentLoadFailed ? "取得できませんでした" : "未取得"
  }

  var body: some View {
    ZStack {
      AppBackgroundView()
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.cardGap) {
          VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
            HStack {
              Label("学生証", systemImage: "graduationcap.fill").font(AppTheme.Typography.headline)
              Spacer()
              Text(statusText)
                .font(AppTheme.Typography.captionEmphasis)
            }
            VStack(alignment: .leading, spacing: 2) {
              Text(student?.displayName ?? "氏名 —").font(AppTheme.Typography.stat)
              if let kana = student?.value("ふりがな"), !kana.isEmpty {
                Text(kana).font(AppTheme.Typography.body).foregroundStyle(AppTheme.textSecondary)
              }
            }
            // 学年・クラス・学生NOは1行にまとめ、その他は学校の学生カルテの順に1行ずつ
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: AppTheme.Space.md, verticalSpacing: AppTheme.Space.sm) {
              cardRow("学年 / クラス", [student?.value("学年").map { "\($0)年" }, student?.value("クラス").map { "\($0)組" },
                student?.value("学生NO").map { "\($0)番" }].compactMap { $0 }.joined(separator: " "))
              ForEach(["学籍番号", "学科", "専攻", "コース", "生年月日", "性別", "居住状態"], id: \.self) { label in
                cardRow(label, student?.value(label))
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(AppTheme.Space.card)
          .background(AppTheme.formatTagBackground)
          .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.large, style: .continuous))
          ConnectionNotice(text: "学生証の表示枠です。学校側の仕様・利用条件を確認するまで、正式な身分証としては使用できません。")
        }.padding(AppTheme.Space.page)
      }
    }
    .foregroundStyle(AppTheme.textPrimary)
    .task { await school.loadStudentCard() }
    .refreshable { await school.loadStudentCard(force: true) }
    .navigationTitle("学生証")
    .navigationBarTitleDisplayMode(.inline)
  }

  private func cardRow(_ label: String, _ value: String?) -> some View {
    GridRow {
      Text(label)
        .font(AppTheme.Typography.bodyEmphasis)
        .foregroundStyle(AppTheme.textSecondary)
        .gridColumnAlignment(.leading)
      Text(value.flatMap { $0.isEmpty ? nil : $0 } ?? "—")
        .font(AppTheme.Typography.body)
        .monospacedDigit()
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}


// ログイン画面だけのプレビュー（.task も学校への自動の通信もない）。
#Preview("ログイン · ライト") {
  SchoolLoginView(school: SchoolViewModel(), onLoggedIn: {})
    .preferredColorScheme(.light)
}

#Preview("ログイン · ダーク") {
  SchoolLoginView(school: SchoolViewModel(), onLoggedIn: {})
    .preferredColorScheme(.dark)
}
