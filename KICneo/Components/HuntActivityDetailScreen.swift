import PDFKit
import SwiftUI

/// 就職活動の1件の詳細。学校の一覧にある項目をすべて並べ、添付（公欠申請の画像・PDF）を表示する。
struct HuntActivityDetailScreen: View {
  /// 開いた時点の内容。一覧が更新されたら最新の内容に切り替える（添付のリンクが後から入ることがあるため）。
  let opened: HuntActivity
  @ObservedObject var school: SchoolViewModel

  private var activity: HuntActivity {
    school.huntActivities.first { $0.key == opened.key } ?? opened
  }

  private enum AttachmentState {
    case loading
    case image(UIImage)
    case pdf(PDFDocument)
    case failed
  }

  @State private var attachment: AttachmentState = .loading
  /// QuickLook に渡す添付ファイル（一時ファイル）
  @State private var previewFileURL: URL?

  var body: some View {
    ZStack {
      AppBackgroundView()
      ScrollView {
        VStack(alignment: .leading, spacing: AppTheme.Space.cardGap) {
          summaryCard
          if activity.attachmentURL != nil {
            attachmentCard
          }
        }
        .padding(AppTheme.Space.page)
      }
    }
    .foregroundStyle(AppTheme.textPrimary)
    .navigationTitle("活動の詳細")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: activity.attachmentHref) { await loadAttachment() }
    .onDisappear { QuickLookPresenter.discardPrepared() }
  }

  // MARK: 項目

  private var summaryCard: some View {
    let rows: [(String, String)] = [
      ("活動日", activity.date), ("活動年度", activity.year), ("区分", activity.kind),
      ("承認状況", activity.approval), ("時限", activity.periods), ("形式", activity.mode),
      ("企業", activity.company), ("職種", activity.jobType), ("勤務地", activity.location),
      ("結果", activity.result), ("結果日", activity.resultDate)
    ].filter { !$0.1.isEmpty }
    return VStack(alignment: .leading, spacing: 14) {
      ForEach(rows, id: \.0) { row in
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text(row.0)
            .font(AppTheme.Typography.captionEmphasis)
            .foregroundStyle(AppTheme.textTertiary)
            .frame(width: 64, alignment: .leading)
          Text(row.1).font(AppTheme.Typography.body)
          Spacer(minLength: 0)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(AppTheme.Space.card).walletCard()
  }

  // MARK: 添付

  private var attachmentCard: some View {
    VStack(alignment: .leading, spacing: AppTheme.Space.md) {
      Label(activity.attachment.isEmpty ? "添付ファイル" : activity.attachment, systemImage: "paperclip")
        .font(AppTheme.Typography.bodyEmphasis)
      switch attachment {
      case .loading:
        ProgressView("読み込み中…")
          .frame(maxWidth: .infinity, minHeight: 120)
      case .image(let image):
        QuickLookThumbnail(image: image, cornerRadius: AppTheme.Radius.small) { sourceView in
          if let url = previewFileURL {
            QuickLookPresenter.present(fileURL: url, from: sourceView)
          }
        }
        .aspectRatio(image.size, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("添付画像を拡大して表示")
        .accessibilityAddTraits(.isButton)
      case .pdf(let document):
        PDFPreview(document: document)
          .frame(height: 420)
          .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
      case .failed:
        VStack(alignment: .leading, spacing: AppTheme.Space.md) {
          Text("添付ファイルを読み込めませんでした。")
            .font(AppTheme.Typography.body).foregroundStyle(AppTheme.textSecondary)
          Button("再読み込み") {
            attachment = .loading
            Task { await loadAttachment() }
          }
          .buttonStyle(SecondaryButtonStyle())
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(AppTheme.Space.card).walletCard()
  }

  private func loadAttachment() async {
    attachment = .loading
    guard let data = await school.attachmentData(for: activity) else {
      attachment = .failed
      return
    }
    // QuickLook はファイルの URL が必要なので、一時ファイルに書き出す
    let name = activity.attachmentURL?.lastPathComponent ?? "attachment"
    previewFileURL = await Task.detached { () -> URL? in
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
      return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }.value
    if let image = UIImage(data: data) {
      if let url = previewFileURL {
        QuickLookPresenter.prepare(fileURL: url)
      } // タップで黒い画面が出ないよう先に準備
      attachment = .image(image)
    } else if let document = PDFDocument(data: data) {
      attachment = .pdf(document)
    } else {
      attachment = .failed
    }
  }
}

private struct PDFPreview: UIViewRepresentable {
  let document: PDFDocument
  func makeUIView(context: Context) -> PDFView {
    let view = PDFView()
    view.autoScales = true
    view.document = document
    return view
  }

  func updateUIView(_ view: PDFView, context: Context) {}
}
