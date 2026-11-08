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

/// 起動時とログイン直後に出す全画面。アイコンのタイルが現れ、準備ができたら拡大しながら消えてホームが見える。
/// `entrance` が false のとき（ログイン直後）は、文字を最初から出しておく。
struct StartupLoadingView: View {
  var entrance = true
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      AppTheme.background.ignoresSafeArea()
      VStack(spacing: 28) {
        BrandIconTile(side: 112, revealed: shown || !entrance)
          .scaleEffect(shown || !entrance || reduceMotion ? 1 : 0.86)
          .opacity(shown || !entrance ? 1 : 0)
          .shadow(color: AppTheme.primaryAction.opacity(0.22), radius: 18, y: 10)
        VStack(spacing: 12) {
          BrandProgressLine()
          Text("学校のデータを読み込み中")
            .font(AppTheme.Typography.caption)
            .foregroundStyle(AppTheme.textSecondary)
        }
        .opacity(shown && entrance ? 1 : 0)
        .animation(.easeOut(duration: 0.3).delay(0.5), value: shown)
      }
    }
    .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.78), value: shown)
    .onAppear { shown = true }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("読み込み中")
  }
}

#Preview("ロゴ") {
  VStack(spacing: 32) {
    BrandWordmark()
    BrandIconTile(side: 96)
    StartupLoadingView().frame(height: 320)
  }
  .padding()
}
