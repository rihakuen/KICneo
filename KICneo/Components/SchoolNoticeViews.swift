import PDFKit
import SwiftUI

/// ホームの「学校からのお知らせ」。学校ポータルのトップページにある未読のお知らせを新しい順に並べる。
/// 3件まで出し、それより多いときは「すべて表示」で広げる。タップで詳細（本文・添付の画像）を下から開く。
struct SchoolNoticesCard: View {
  @ObservedObject var school: SchoolViewModel
  @State private var opened: SchoolNotice?
  @State private var showsAll = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let collapsedCount = 3

  var body: some View {
    let notices = school.notices
    let unread = notices.filter { school.isNoticeUnread($0) }.count
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      HStack(alignment: .firstTextBaseline, spacing: AppTheme.Space.sm) {
        Text("学校からのお知らせ")
          .font(AppTheme.Typography.cardTitle)
        if unread > 0 {
          Text("未読 \(unread)")
            .font(AppTheme.Typography.captionEmphasis)
            .foregroundStyle(AppTheme.primaryAction)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(AppTheme.formatTagBackground, in: Capsule())
            .contentTransition(.numericText(value: Double(unread)))
        }
        Spacer(minLength: 0)
        if school.isLoadingNotices {
          ProgressView().controlSize(.small)
        }
      }

      if notices.isEmpty {
        emptyState
      } else {
        VStack(spacing: 0) {
          let shown = showsAll ? notices : Array(notices.prefix(collapsedCount))
          ForEach(Array(shown.enumerated()), id: \.element.key) { index, notice in
            if index > 0 { Divider().padding(.leading, 16) }
            row(notice)
          }
        }
        if notices.count > collapsedCount {
          Button {
            AppHaptics.selection()
            withAnimation(AppTheme.Motion.transition(reduce: reduceMotion)) { showsAll.toggle() }
          } label: {
            Label(showsAll ? "閉じる" : "すべて表示（\(notices.count)件）",
                  systemImage: showsAll ? "chevron.up" : "chevron.down")
              .font(AppTheme.Typography.captionEmphasis)
              .foregroundStyle(AppTheme.primaryAction)
              .frame(maxWidth: .infinity, minHeight: 32)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(AppTheme.Space.card)
    .walletCard()
    .sheet(item: $opened) { notice in
      SchoolNoticeDetailSheet(notice: notice, school: school)
    }
  }

  @ViewBuilder
  private var emptyState: some View {
    if school.noticesLoadFailed {
      HStack {
        Text("お知らせを読み込めませんでした。")
          .font(AppTheme.Typography.body)
          .foregroundStyle(AppTheme.textSecondary)
        Spacer()
        Button("再読み込み") { Task { await school.loadNotices(force: true) } }
          .font(AppTheme.Typography.captionEmphasis)
      }
    } else {
      Text(school.isLoadingNotices ? "読み込み中…" : "新しいお知らせはありません")
        .font(AppTheme.Typography.body)
        .foregroundStyle(AppTheme.textSecondary)
    }
  }

  private func row(_ notice: SchoolNotice) -> some View {
    let unread = school.isNoticeUnread(notice)
    return Button {
      AppHaptics.light()
      opened = notice
    } label: {
      HStack(alignment: .top, spacing: 10) {
        Circle()
          .fill(unread ? AppTheme.primaryAction : .clear)
          .frame(width: 6, height: 6)
          .padding(.top, 7)
        VStack(alignment: .leading, spacing: 4) {
          Text(notice.title)
            .font(unread ? AppTheme.Typography.bodyEmphasis : AppTheme.Typography.body)
            .foregroundStyle(AppTheme.textPrimary)
            .lineLimit(2)
            .multilineTextAlignment(.leading)
          HStack(spacing: 6) {
            Text([notice.category, Self.shortDate(notice)].filter { !$0.isEmpty }.joined(separator: " · "))
            if notice.hasAttachment {
              Image(systemName: "paperclip").accessibilityLabel("添付あり")
            }
          }
          .font(AppTheme.Typography.caption)
          .foregroundStyle(AppTheme.textSecondary)
        }
        Spacer(minLength: 0)
        Image(systemName: "chevron.right")
          .font(AppTheme.Typography.captionEmphasis)
          .foregroundStyle(AppTheme.textTertiary)
          .padding(.top, 4)
      }
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityHint(unread ? "未読" : "")
  }

  /// 「2026/11/06」→「11/6」（今年でなければ年も付ける）
  static func shortDate(_ notice: SchoolNotice) -> String {
    guard let date = notice.postedAt else { return notice.date }
    let calendar = AttendanceRatePeriod.calendar
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    let thisYear = calendar.component(.year, from: .now)
    let monthDay = "\(c.month ?? 0)/\(c.day ?? 0)"
    return c.year == thisYear ? monthDay : "\(c.year ?? 0)/\(monthDay)"
  }
}

/// お知らせの詳細。本文（リンクは押せる）と添付ファイル（画像はその場で表示、タップで拡大）。
struct SchoolNoticeDetailSheet: View {
  let notice: SchoolNotice
  @ObservedObject var school: SchoolViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var detail: SchoolNoticeDetail?
  @State private var loading = true

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.lg) {
          VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
            Text([notice.section, notice.category].filter { !$0.isEmpty }.joined(separator: " · "))
              .font(AppTheme.Typography.captionEmphasis)
              .foregroundStyle(AppTheme.primaryAction)
            Text(detail?.title.isEmpty == false ? detail!.title : notice.title)
              .font(.title3.weight(.bold))
              .fixedSize(horizontal: false, vertical: true)
            Text(meta)
              .font(AppTheme.Typography.caption)
              .foregroundStyle(AppTheme.textSecondary)
          }

          if loading {
            ProgressView("読み込み中…").frame(maxWidth: .infinity, minHeight: 160)
          } else if let detail {
            if !detail.body.isEmpty {
              Text(Self.linkified(detail.body))
                .font(AppTheme.Typography.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !detail.attachments.isEmpty {
              VStack(alignment: .leading, spacing: AppTheme.Space.md) {
                Text("添付ファイル")
                  .font(AppTheme.Typography.label)
                  .foregroundStyle(AppTheme.textSecondary)
                ForEach(detail.attachments) { attachment in
                  NoticeAttachmentView(attachment: attachment, notice: notice, school: school)
                }
              }
            }
          } else {
            unavailable
          }
        }
        .foregroundStyle(AppTheme.textPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.Space.page)
      }
      .background(AppTheme.background)
      .navigationTitle("お知らせ")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button("閉じる", systemImage: "xmark") { dismiss() }
        }
      }
    }
    .task { await load() }
    .onDisappear { QuickLookPresenter.discardPrepared() }
  }

  private var meta: String {
    let poster = detail?.poster.isEmpty == false ? detail!.poster : notice.poster
    let start = detail?.startDate.isEmpty == false ? detail!.startDate : notice.date
    let end = detail?.endDate ?? ""
    let period = end.isEmpty ? start : "\(start) 〜 \(end)"
    return [poster, period].filter { !$0.isEmpty }.joined(separator: "  ·  ")
  }

  @ViewBuilder
  private var unavailable: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Text(notice.eventTarget == nil
           ? "学校のトップページから外れたお知らせのため、詳細を読み込めません。学校のポータルの掲示板で確認してください。"
           : "詳細を読み込めませんでした。")
        .font(AppTheme.Typography.body)
        .foregroundStyle(AppTheme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
      if notice.eventTarget != nil {
        Button("再読み込み") { Task { await load() } }
          .buttonStyle(SecondaryButtonStyle())
      }
    }
  }

  private func load() async {
    if let cached = school.cachedNoticeDetail(notice) {
      detail = cached
      loading = false
    }
    guard detail == nil else {
      _ = await school.noticeDetail(notice) // 未読の印を消す（保存済みの詳細があるので通信はしない）
      return
    }
    loading = true
    detail = await school.noticeDetail(notice)
    loading = false
  }

  /// 本文の URL を押せるリンクにする
  static func linkified(_ text: String) -> AttributedString {
    var result = AttributedString(text)
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
    for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
      guard let url = match.url, let range = Range(match.range, in: text),
            let attributed = Range(range, in: result) else { continue }
      result[attributed].link = url
      result[attributed].foregroundColor = AppTheme.primaryAction
    }
    return result
  }
}

/// お知らせの添付1件。画像はその場で表示（タップで QuickLook の拡大表示）、PDF はページを表示、それ以外は共有で開く。
private struct NoticeAttachmentView: View {
  let attachment: SchoolNoticeDetail.Attachment
  let notice: SchoolNotice
  @ObservedObject var school: SchoolViewModel

  private enum LoadState {
    case loading
    case image(UIImage, URL?)
    case pdf(PDFDocument)
    case file(URL)
    case failed
  }

  @State private var state: LoadState = .loading

  var body: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.sm) {
      Label(attachment.name, systemImage: attachment.isImage ? "photo" : "paperclip")
        .font(AppTheme.Typography.caption)
        .foregroundStyle(AppTheme.textSecondary)
        .lineLimit(1)
      switch state {
      case .loading:
        RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous)
          .fill(AppTheme.elevatedBackground)
          .frame(height: 180)
          .overlay { ProgressView() }
      case .image(let image, let url):
        QuickLookThumbnail(image: image, cornerRadius: AppTheme.Radius.small) { sourceView in
          if let url { QuickLookPresenter.present(fileURL: url, from: sourceView) }
        }
        .aspectRatio(image.size, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(attachment.name)を拡大して表示")
        .accessibilityAddTraits(.isButton)
      case .pdf(let document):
        AttachmentPDFView(document: document)
          .frame(height: 420)
          .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
      case .file(let url):
        ShareLink(item: url) {
          Label("ファイルを開く", systemImage: "square.and.arrow.up")
        }
        .buttonStyle(SecondaryButtonStyle())
      case .failed:
        HStack {
          Text("読み込めませんでした。")
            .font(AppTheme.Typography.body)
            .foregroundStyle(AppTheme.textSecondary)
          Spacer()
          Button("再読み込み") { Task { await load() } }
            .font(AppTheme.Typography.captionEmphasis)
        }
      }
    }
    .task { await load() }
  }

  private func load() async {
    state = .loading
    guard let data = await school.noticeAttachmentData(attachment, of: notice) else {
      state = .failed
      return
    }
    // QuickLook・共有はファイルの URL が必要なので、一時ファイルに書き出す
    let name = attachment.name
    let fileURL = await Task.detached { () -> URL? in
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
      return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }.value
    if let image = UIImage(data: data) {
      if let fileURL { QuickLookPresenter.prepare(fileURL: fileURL) }
      state = .image(image, fileURL)
    } else if let document = PDFDocument(data: data) {
      state = .pdf(document)
    } else if let fileURL {
      state = .file(fileURL)
    } else {
      state = .failed
    }
  }
}

private struct AttachmentPDFView: UIViewRepresentable {
  let document: PDFDocument
  func makeUIView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.document = document
    return view
  }
  func updateUIView(_ view: PDFView, context: Context) {
    view.document = document
  }
}
