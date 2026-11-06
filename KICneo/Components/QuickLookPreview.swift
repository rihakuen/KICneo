import QuickLook
import SwiftUI

/// 添付ファイルを iOS 標準の QuickLook（ファイル App やメールの添付と同じプレビュー）で開く。
/// 画像・PDF のピンチ拡大、ダブルタップ、下へスワイプで閉じる、共有ボタンまで標準の動き。
/// サムネイルの画像ビューを渡すので、その位置から広がり、閉じると元の位置に戻る。
@MainActor
enum QuickLookPresenter {
  /// 表示中・準備済みのセッション（データソース/デリゲートは QLPreviewController が弱参照しか持たないため、ここで保持する）
  private static var session: Session?
  private static var prepared: (url: URL, controller: QLPreviewController)?

  /// 先に預覽畫面を作って、ファイルの読み込みを始めておく。
  /// QuickLook は別プロセスで描画するため、開く瞬間に作ると、画像が出るまで黒い画面が一瞬見える。
  /// 詳細画面で画像を表示した時点で呼んでおけば、タップしたときにはもう読み込みが進んでいる。
  static func prepare(fileURL: URL) {
    if let prepared, prepared.url == fileURL {
      return
    }
    let session = Session(url: fileURL)
    let controller = QLPreviewController()
    controller.dataSource = session
    controller.delegate = session
    controller.loadViewIfNeeded() // ここで view を読み込み、別プロセスの描画を立ち上げる
    controller.reloadData()
    Self.session = session
    prepared = (fileURL, controller)
  }

  static func discardPrepared() {
    prepared = nil
    if session?.isPresented != true {
      session = nil
    }
  }

  static func present(fileURL: URL, from sourceView: UIView) {
    guard let top = topViewController() else { return }
    if prepared?.url != fileURL {
      prepare(fileURL: fileURL)
    }
    guard let controller = prepared?.controller, let session else { return }
    session.sourceView = sourceView
    session.isPresented = true
    prepared = nil // 1つの QLPreviewController は同時に1回しか表示できない。閉じたあとは作り直す
    top.present(controller, animated: true)
  }

  private static func topViewController() -> UIViewController? {
    // 通常は前面で有効なシーンのキーウィンドウ。取れない環境（プレビューなど）でも、あるウィンドウを使う
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }

  private final class Session: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
    let url: URL
    weak var sourceView: UIView?
    var isPresented = false

    init(url: URL) {
      self.url = url
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
      1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
      url as NSURL
    }

    /// ズーム遷移の起点（閉じるときの戻り先）になる画像ビュー
    func previewController(_ controller: QLPreviewController, transitionViewFor item: QLPreviewItem) -> UIView? {
      sourceView
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
      Task { @MainActor in
        QuickLookPresenter.session = nil
        // 閉じたあと、同じ画像をもう一度開くときのために作り直しておく
        QuickLookPresenter.prepare(fileURL: self.url)
      }
    }
  }
}

/// タップすると QuickLook で開くサムネイル。実体は UIImageView なので、QuickLook がその位置から広げられる。
struct QuickLookThumbnail: UIViewRepresentable {
  let image: UIImage
  let cornerRadius: CGFloat
  let onTap: (UIView) -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onTap)
  }

  func makeUIView(context: Context) -> UIImageView {
    let view = UIImageView(image: image)
    view.contentMode = .scaleAspectFill
    view.clipsToBounds = true
    view.layer.cornerRadius = cornerRadius
    view.layer.cornerCurve = .continuous
    view.isUserInteractionEnabled = true
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    view.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
    return view
  }

  /// 提案された幅いっぱいに、画像の縦横比のまま表示する（画像のピクセル数がそのまま大きさにならないように）。
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIImageView, context: Context) -> CGSize? {
    let width = proposal.width ?? image.size.width
    return CGSize(width: width, height: width * image.size.height / max(image.size.width, 1))
  }

  func updateUIView(_ view: UIImageView, context: Context) {
    view.image = image
    context.coordinator.onTap = onTap
  }

  final class Coordinator: NSObject {
    var onTap: (UIView) -> Void
    init(_ onTap: @escaping (UIView) -> Void) {
      self.onTap = onTap
    }

    @objc func tapped(_ gesture: UITapGestureRecognizer) {
      if let view = gesture.view {
        onTap(view)
      }
    }
  }
}
