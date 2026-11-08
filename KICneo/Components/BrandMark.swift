import SwiftUI

// アプリアイコンと同じ「KIC / neo」のロゴ。字形は BrandGlyphs（Montserrat をパスにしたもの）を使うので、
// フォントを同梱しなくても、ホームの見出し・ログイン・起動画面でアイコンと同じ形になる。

/// 「KIC」または「neo」の字形。渡された枠の高さに合わせて拡大する（幅は送り幅ぶん）。
struct BrandWordShape: Shape {
  enum Word { case kic, neo }
  let word: Word

  func path(in rect: CGRect) -> Path {
    var glyphs = Path()
    switch word {
    case .kic: BrandGlyphs.kic(&glyphs)
    case .neo: BrandGlyphs.neo(&glyphs)
    }
    let scale = rect.height / BrandGlyphs.height
    return glyphs.applying(
      CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
  }

  /// 文字サイズ `size` のときの枠の大きさ
  static func size(_ word: Word, fontSize size: CGFloat) -> CGSize {
    let advance = word == .kic ? BrandGlyphs.kicAdvance : BrandGlyphs.neoAdvance
    return CGSize(width: advance * size, height: BrandGlyphs.height * size)
  }
}

enum BrandColors {
  /// アイコンの背景（ライト：アプリの青 #1D50D9／ダーク：#141824）
  static let tile = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 0.078, green: 0.094, blue: 0.141, alpha: 1)
      : UIColor(red: 0.114, green: 0.314, blue: 0.851, alpha: 1)
  })
  /// アイコンの「neo」（ライト：#C9DBFF／ダーク：#5F9EFF）
  static let tileNeo = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 0.373, green: 0.620, blue: 1.0, alpha: 1)
      : UIColor(red: 0.788, green: 0.859, blue: 1.0, alpha: 1)
  })
}

/// 1行の「KICneo」。「KIC」は文字色、「neo」はアプリの青。
struct BrandWordmark: View {
  /// 文字サイズ（pt）
  var fontSize: CGFloat = 34
  var kicColor: Color = AppTheme.textPrimary
  var neoColor: Color = AppTheme.primaryAction

  var body: some View {
    HStack(alignment: .bottom, spacing: 0) {
      word(.kic, color: kicColor)
      word(.neo, color: neoColor)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("KICneo")
  }

  private func word(_ word: BrandWordShape.Word, color: Color) -> some View {
    let size = BrandWordShape.size(word, fontSize: fontSize)
    return BrandWordShape(word: word).fill(color).frame(width: size.width, height: size.height)
  }
}

/// アプリアイコンと同じ見た目のタイル（2行の「KIC / neo」）。
/// `revealed` が false の間は文字を隠しておき、true になると「KIC」→「neo」の順に浮かび上がる。
struct BrandIconTile: View {
  var side: CGFloat = 64
  var revealed = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let fontSize = side * BrandGlyphs.Icon.fontSize
    let left = side * BrandGlyphs.Icon.left
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
        .fill(BrandColors.tile)
        .frame(width: side, height: side)
      line(.kic, color: .white, fontSize: fontSize,
           top: side * BrandGlyphs.Icon.kicBaseline - BrandGlyphs.baseline * fontSize, left: left, delay: 0.1)
      line(.neo, color: BrandColors.tileNeo, fontSize: fontSize,
           top: side * BrandGlyphs.Icon.neoBaseline - BrandGlyphs.baseline * fontSize, left: left, delay: 0.28)
    }
    .frame(width: side, height: side)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("KICneo")
  }

  private func line(_ word: BrandWordShape.Word, color: Color, fontSize: CGFloat, top: CGFloat, left: CGFloat,
                    delay: Double) -> some View {
    let size = BrandWordShape.size(word, fontSize: fontSize)
    return BrandWordShape(word: word)
      .fill(color)
      .frame(width: size.width, height: size.height)
      .opacity(revealed ? 1 : 0)
      .offset(y: revealed || reduceMotion ? 0 : side * 0.06)
      .blur(radius: revealed || reduceMotion ? 0 : side * 0.04)
      .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.55).delay(delay), value: revealed)
      .offset(x: left, y: top)
  }
}

/// 読み込み中の細い線。短い帯が左から右へ流れ続ける。
struct BrandProgressLine: View {
  @State private var phase: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let width: CGFloat = 120
  private let bar: CGFloat = 40

  var body: some View {
    Capsule()
      .fill(AppTheme.border.opacity(0.6))
      .frame(width: width, height: 3)
      .overlay(alignment: .leading) {
        Capsule()
          .fill(AppTheme.primaryAction)
          .frame(width: bar, height: 3)
          .offset(x: reduceMotion ? (width - bar) / 2 : -bar + phase * (width + bar))
      }
      .clipShape(Capsule())
      .onAppear {
        guard !reduceMotion else { return }
        withAnimation(.timingCurve(0.45, 0, 0.25, 1, duration: 1.2).repeatForever(autoreverses: false)) { phase = 1 }
      }
      .accessibilityHidden(true)
  }
}

// MARK: 画面から画面へロゴをつなぐ

/// ホームの見出し・ログイン画面のタイルの位置（画面全体の座標）を、起動画面の動きに渡すための入れ物。
/// スクロールのたびに位置が変わるので、画面の再描画を起こさないよう @Observable ではない参照型にしている。
nonisolated final class BrandAnchorStore: @unchecked Sendable {
  var header: (kic: CGRect, neo: CGRect)?
  var loginTile: CGRect?
  /// ログインボタン（ログイン後に色が広がる起点）
  var loginButton: CGRect?
}

/// 子の画面から位置を知らせる窓口と、起動画面が重なっている間に元の文字を隠す指示
nonisolated struct BrandAnchors: Sendable {
  var store: BrandAnchorStore?
  var hideHeader = false
  var hideLoginTile = false
}

extension EnvironmentValues {
  @Entry var brandAnchors = BrandAnchors()
}

/// 起動時とログイン直後に出す全画面。アイコンのタイルから、次の画面のロゴの位置へ「KIC」「neo」が移っていく。
/// - center：画面の中央にタイル。起動時は「KIC」→「neo」の順に浮かび、下に読み込み中の線。
/// - loginTile：タイルごとログイン画面のタイルの位置・大きさへ移り、背景は消える（下のログイン画面が見える）。
/// - header：タイルの面は消え、「KIC」「neo」がホームの見出しの位置へ飛び、見出しの色に変わる。
struct BrandSplashView: View {
  enum Phase { case center, loginTile, header }

  var phase: Phase
  /// 起動時の入場（文字が順に浮かぶ）をするか。ログイン直後は最初から文字を出しておく
  var entrance = true
  var loginTile: CGRect?
  var header: (kic: CGRect, neo: CGRect)?
  /// 入場が終わったとき（表示されてから数えるので、起動が遅くても文字が出る前に次へ進まない）
  var onEntranceFinished: () -> Void = {}

  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var revealed: Bool { shown || !entrance }

  var body: some View {
    GeometryReader { proxy in
      let origin = proxy.frame(in: .global).origin
      let size = proxy.size
      let center = CGRect(x: size.width / 2 - 56, y: size.height / 2 - 86, width: 112, height: 112)
      let tile = tileRect(center: center, origin: origin)
      let letters = letterRects(tile: tile, origin: origin)
      // 見出しの位置がわからないとき（ホーム以外のタブなど）は、その場で消す
      let vanishes = phase == .header && header == nil
      ZStack(alignment: .topLeading) {
        AppTheme.background
          .opacity(phase == .center ? 1 : 0)

        VStack(spacing: 12) {
          BrandProgressLine()
          Text("学校のデータを読み込み中")
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .opacity(phase == .center && entrance && shown ? 1 : 0)
        .animation(.easeOut(duration: 0.3).delay(0.5), value: shown)
        .position(x: size.width / 2, y: center.maxY + 48)

        RoundedRectangle(cornerRadius: tile.width * 0.2237, style: .continuous)
          .fill(BrandColors.tile)
          .shadow(color: AppTheme.primaryAction.opacity(phase == .center ? 0.22 : 0), radius: 18, y: 10)
          .frame(width: tile.width, height: tile.height)
          .scaleEffect(revealed || reduceMotion ? 1 : 0.86)
          .opacity(phase == .header ? 0 : (revealed ? 1 : 0))
          .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.78), value: shown)
          .position(x: tile.midX, y: tile.midY)

        word(.kic, rect: letters.kic, color: phase == .header ? AppTheme.textPrimary : .white, delay: 0.1)
        word(.neo, rect: letters.neo, color: phase == .header ? AppTheme.primaryAction : BrandColors.tileNeo, delay: 0.28)
      }
      .opacity(vanishes ? 0 : 1)
    }
    .ignoresSafeArea()
    .onAppear { shown = true }
    .task {
      try? await Task.sleep(for: .milliseconds(entrance && !reduceMotion ? 1100 : 250))
      onEntranceFinished()
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("読み込み中")
  }

  private func tileRect(center: CGRect, origin: CGPoint) -> CGRect {
    switch phase {
    case .center:
      return center
    case .loginTile:
      return loginTile.map { $0.offsetBy(dx: -origin.x, dy: -origin.y) } ?? center
    case .header:
      // タイルの面は「KIC」の位置へ小さくなりながら消える
      guard let kic = header?.kic.offsetBy(dx: -origin.x, dy: -origin.y) else { return center }
      return CGRect(x: kic.minX, y: kic.midY - kic.height, width: kic.height * 2, height: kic.height * 2)
    }
  }

  /// 「KIC」「neo」の枠。タイルの中ではアイコンと同じ配置、見出しへ移るときは見出しの文字の位置
  private func letterRects(tile: CGRect, origin: CGPoint) -> (kic: CGRect, neo: CGRect) {
    if phase == .header, let header {
      return (header.kic.offsetBy(dx: -origin.x, dy: -origin.y), header.neo.offsetBy(dx: -origin.x, dy: -origin.y))
    }
    let side = tile.width
    let fontSize = side * BrandGlyphs.Icon.fontSize
    let left = tile.minX + side * BrandGlyphs.Icon.left
    func rect(_ word: BrandWordShape.Word, baseline: CGFloat) -> CGRect {
      let size = BrandWordShape.size(word, fontSize: fontSize)
      return CGRect(x: left, y: tile.minY + side * baseline - BrandGlyphs.baseline * fontSize, width: size.width, height: size.height)
    }
    return (rect(.kic, baseline: BrandGlyphs.Icon.kicBaseline), rect(.neo, baseline: BrandGlyphs.Icon.neoBaseline))
  }

  private func word(_ word: BrandWordShape.Word, rect: CGRect, color: Color, delay: Double) -> some View {
    BrandWordShape(word: word)
      .fill(color)
      .frame(width: rect.width, height: rect.height)
      .opacity(revealed ? 1 : 0)
      .offset(y: revealed || reduceMotion ? 0 : 7)
      .blur(radius: revealed || reduceMotion ? 0 : 4)
      .animation(reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.55).delay(delay), value: shown)
      .position(x: rect.midX, y: rect.midY)
  }
}

// MARK: ログイン後の画面

/// ログインできたあとの全画面。
/// 1. covered：ログインボタンの位置からアイコンの色が円で広がり、画面全体（時計の帯・下端まで）を覆う
/// 2. title：左から「KIC」→「neo」が大きく滑り込む
/// 3. loading：字の下の線が伸び、光が流れ、いま確認している内容の文字が入れ替わる（最低 5 秒はこの画面）
/// 4. finishing：色が円で縮みながらホームの見出しへ吸い込まれ、「KIC」「neo」も見出しの位置・色へ移る
struct BrandLoginCover: View {
  enum Phase: Int, Comparable {
    case start, covered, title, loading, finishing
    static func < (a: Phase, b: Phase) -> Bool { a.rawValue < b.rawValue }
  }

  var phase: Phase
  /// 色が広がり始める位置（ログインボタン。画面全体の座標）
  var origin: CGRect?
  /// ホームの見出しの「KIC」「neo」の位置（画面全体の座標）
  var header: (kic: CGRect, neo: CGRect)?

  @State private var stepIndex = 0
  @State private var progress: CGFloat = 0
  @State private var shimmer: CGFloat = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let steps = ["ログインしました", "出欠を確認しています", "時間割を確認しています",
                              "お知らせを確認しています", "まもなく完了します"]

  var body: some View {
    GeometryReader { proxy in
      let frame = proxy.frame(in: .global)
      let size = proxy.size
      let local: (CGRect) -> CGRect = { $0.offsetBy(dx: -frame.minX, dy: -frame.minY) }
      let start = origin.map { CGPoint(x: local($0).midX, y: local($0).midY) } ?? CGPoint(x: size.width / 2, y: size.height * 0.7)
      let headerRects = header.map { (kic: local($0.kic), neo: local($0.neo)) }
      let headerCenter = headerRects.map { CGPoint(x: ($0.kic.minX + $0.neo.maxX) / 2, y: $0.kic.midY) }
      let fullRadius = hypot(max(start.x, size.width - start.x), max(start.y, size.height - start.y)) + 40
      let radius: CGFloat = phase == .start ? 0 : (phase == .finishing ? 0 : fullRadius)
      let center = phase == .finishing ? (headerCenter ?? start) : start
      // 大きな字の位置：画面の左側、少し上
      let fontSize: CGFloat = min(56, size.width * 0.14)
      let kicSize = BrandWordShape.size(.kic, fontSize: fontSize)
      let neoSize = BrandWordShape.size(.neo, fontSize: fontSize)
      let titleTop = size.height * 0.40 - kicSize.height
      let kicRect = phase == .finishing ? (headerRects?.kic ?? CGRect(x: 28, y: titleTop, width: kicSize.width, height: kicSize.height))
        : CGRect(x: 28, y: titleTop, width: kicSize.width, height: kicSize.height)
      let neoRect = phase == .finishing ? (headerRects?.neo ?? CGRect(x: 28 + kicSize.width, y: titleTop, width: neoSize.width, height: neoSize.height))
        : CGRect(x: 28 + kicSize.width, y: titleTop, width: neoSize.width, height: neoSize.height)
      let shown = phase >= .title

      ZStack(alignment: .topLeading) {
        // アイコンの色の面（円で広がる・縮む）
        BrandColors.tile
          .mask {
            Circle()
              .frame(width: radius * 2, height: radius * 2)
              .position(center)
          }

        word(.kic, rect: kicRect, color: phase == .finishing ? AppTheme.textPrimary : .white, shown: shown, delay: 0)
        word(.neo, rect: neoRect, color: phase == .finishing ? AppTheme.primaryAction : BrandColors.tileNeo, shown: shown, delay: 0.12)

        // 読み込み中：伸びる線と流れる光、確認中の内容
        VStack(alignment: .leading, spacing: 14) {
          ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.22))
            Capsule().fill(.white)
              .frame(width: (size.width - 56) * progress)
            Capsule()
              .fill(.white.opacity(0.9))
              .frame(width: 36)
              .blur(radius: 4)
              .offset(x: -36 + (size.width - 56 + 36) * shimmer)
              .opacity(reduceMotion ? 0 : 0.55)
          }
          .frame(width: size.width - 56, height: 3)
          .clipShape(Capsule())

          Text(Self.steps[stepIndex])
            .font(AppTheme.Typography.bodyEmphasis)
            .foregroundStyle(.white.opacity(0.85))
            .contentTransition(.opacity)
            .id(stepIndex)
            .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
        }
        .frame(width: size.width - 56, alignment: .leading)
        .offset(x: 28, y: titleTop + kicSize.height + 28)
        .opacity(phase == .loading ? 1 : 0)
        .offset(y: phase == .loading || reduceMotion ? 0 : 10)
        .animation(.easeOut(duration: 0.35), value: phase == .loading)
      }
    }
    .ignoresSafeArea()
    .task(id: phase == .loading) {
      guard phase == .loading else { return }
      withAnimation(.timingCurve(0.3, 0, 0.2, 1, duration: 3.6)) { progress = 1 }
      if !reduceMotion {
        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: false)) { shimmer = 1 }
      }
      for index in 1..<Self.steps.count {
        try? await Task.sleep(for: .milliseconds(820))
        withAnimation(.smooth(duration: 0.35)) { stepIndex = index }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(phase == .loading ? Self.steps[stepIndex] : "ログインしました")
  }

  private func word(_ word: BrandWordShape.Word, rect: CGRect, color: Color, shown: Bool, delay: Double) -> some View {
    BrandWordShape(word: word)
      .fill(color)
      .frame(width: rect.width, height: rect.height)
      .opacity(shown ? 1 : 0)
      .offset(x: shown || reduceMotion ? 0 : -70)
      .blur(radius: shown || reduceMotion ? 0 : 8)
      .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.82).delay(delay), value: shown)
      .position(x: rect.midX, y: rect.midY)
  }
}

#Preview("ロゴ") {
  VStack(spacing: 32) {
    BrandWordmark()
    BrandIconTile(side: 96)
    BrandSplashView(phase: .center).frame(height: 320)
  }
  .padding()
}
