import SwiftUI

/// ページ先頭の見出し。小さな英字ラベル（eyebrow）＋大きなタイトル＋説明の3段。
/// タイトルや説明の数字が変わると `.numericText()` で入れ替わる。
struct PageHeader: View {
  let eyebrow: String
  let title: String
  var subtitle: String? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(eyebrow)
        .font(.caption.weight(.semibold))
        .tracking(1.5)
        .textCase(.uppercase)
        .foregroundStyle(AppTheme.textSecondary)
      Text(title)
        .font(.largeTitle.bold())
        .contentTransition(.numericText())
        .accessibilityAddTraits(.isHeader)
      if let subtitle {
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(AppTheme.textSecondary)
          .contentTransition(.numericText())
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .textTransition(on: [title, subtitle ?? ""])
  }
}

#Preview("ページ見出し") {
  PageHeader(eyebrow: "Attendance", title: "10月の出席", subtitle: "2026年10月 · 10/27 まで記録済み")
    .padding(AppTheme.Space.page)
    .background(AppTheme.background)
}

/// ホーム最上部の「KICneo」。アプリアイコンと同じ字形（Montserrat をパスにした BrandGlyphs）で、
/// 「KIC」は文字色、「neo」はアプリの青の単色。画面に出るたびに「KIC」→「neo」の順で浮かび上がる。
/// 動きを減らす設定では、入場はフェードだけにする。
struct KICneoHeader: View {
  @State private var shown = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  /// 文字サイズ（largeTitle 相当）。文字サイズの設定に追従する。
  @ScaledMetric(relativeTo: .largeTitle) private var fontSize: CGFloat = 34

  var body: some View {
    HStack(alignment: .bottom, spacing: 0) {
      word(.kic, color: AppTheme.textPrimary)
        .modifier(Entrance(shown: shown, delay: 0, reduceMotion: reduceMotion))
      word(.neo, color: AppTheme.primaryAction)
        .modifier(Entrance(shown: shown, delay: 0.12, reduceMotion: reduceMotion))
    }
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("KICneo")
    .accessibilityAddTraits(.isHeader)
    .onAppear { shown = true }
    // 次に画面へ戻ってきたとき、もう一度動くように戻しておく
    .onDisappear { shown = false }
  }

  private func word(_ word: BrandWordShape.Word, color: Color) -> some View {
    let size = BrandWordShape.size(word, fontSize: fontSize)
    return BrandWordShape(word: word).fill(color).frame(width: size.width, height: size.height)
  }

  private struct Entrance: ViewModifier {
    let shown: Bool
    let delay: Double
    let reduceMotion: Bool

    func body(content: Content) -> some View {
      content
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : 12)
        .blur(radius: shown || reduceMotion ? 0 : 6)
        .animation(
          shown ? (reduceMotion ? Animation.easeOut(duration: 0.2) : Animation.smooth(duration: 0.6).delay(delay)) : nil,
          value: shown)
    }
  }
}

/// 「neo」の字形。太さのそろった線・真円・弧だけでできた、幾何学的な小文字（フォントは使わない）。
/// 高さ 1 の座標で作り、渡された枠に合わせて拡大する。塗りつぶしの形（線の輪郭）を返すので、mask にそのまま使える。
struct NeoWordmark: Shape {
  /// 線の太さ（高さに対する割合）
  static let weight: CGFloat = 0.24
  /// 文字と文字のすきま（線の太さに対する割合）
  static let gap: CGFloat = 0.42

  /// 幅 ÷ 高さ
  static var aspectRatio: CGFloat {
    let w = weight, r = (1 - w) / 2
    let nWidth = 0.86 * (1 - w) + w
    let circle = 2 * r + w
    return nWidth + circle * 2 + gap * w * 2
  }

  func path(in rect: CGRect) -> Path {
    let h = rect.height
    let w = Self.weight * h
    let r = (h - w) / 2                 // e・o の円の半径（線の中心）
    let gap = Self.gap * w
    var lines = Path()

    // n：左の縦線 → 上の半円 → 右の縦線（下端は平ら）
    let nInner = 0.86 * (h - w)         // n の2本の縦線の中心どうしの間隔
    let nLeft = w / 2
    let nRight = nLeft + nInner
    let archRadius = nInner / 2
    let archCenterY = w / 2 + archRadius
    lines.move(to: CGPoint(x: nLeft, y: h))
    lines.addLine(to: CGPoint(x: nLeft, y: archCenterY))
    for step in 0...36 {
      let angle = Double.pi + Double.pi * Double(step) / 36   // 左（180°）から上を通って右（360°）へ
      lines.addLine(to: CGPoint(x: nLeft + archRadius + archRadius * CGFloat(cos(angle)),
                                y: archCenterY + archRadius * CGFloat(sin(angle))))
    }
    lines.addLine(to: CGPoint(x: nRight, y: h))

    // e：横線 → 右端から上を回って左、下を通って右下で止まる円弧
    let eCenter = CGPoint(x: nRight + w / 2 + gap + w / 2 + r, y: h / 2)
    var e = Path()
    e.move(to: CGPoint(x: eCenter.x - r, y: eCenter.y))
    e.addLine(to: CGPoint(x: eCenter.x + r, y: eCenter.y))
    let start = 0.0, end = -2 * Double.pi + Double.pi * 0.28    // 右（0°）から反時計回りに、右下（約50°）の手前まで
    for step in 0...72 {
      let angle = start + (end - start) * Double(step) / 72
      let point = CGPoint(x: eCenter.x + r * CGFloat(cos(angle)), y: eCenter.y + r * CGFloat(sin(angle)))
      if step == 0 { e.move(to: point) } else { e.addLine(to: point) }
    }

    // o：真円
    let oCenter = CGPoint(x: eCenter.x + r + w / 2 + gap + w / 2 + r, y: h / 2)
    var o = Path()
    o.addEllipse(in: CGRect(x: oCenter.x - r, y: oCenter.y - r, width: 2 * r, height: 2 * r))

    let style = StrokeStyle(lineWidth: w, lineCap: .butt, lineJoin: .round)
    var shape = Path()
    shape.addPath(lines.strokedPath(style))
    shape.addPath(e.strokedPath(style))
    shape.addPath(o.strokedPath(style))
    // 渡された枠の左上にそろえる（幅は aspectRatio で決まる）
    return shape.applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
  }
}

/// ゆっくり流れる青のグラデーション（3×3 の MeshGradient の点を少しずつ動かす）＋細かい粒子。
/// 濃い青から淡い青灰色へ。ライトモードでも字が背景に溶けないよう、いちばん淡い色でも少し青みを残す。
struct FluidFill: View {
  var animated = true

  private static let deep = Color(red: 0.17, green: 0.33, blue: 0.86)
  private static let mid = Color(red: 0.38, green: 0.55, blue: 0.93)
  private static let pale = Color(red: 0.66, green: 0.74, blue: 0.93)

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: !animated)) { context in
      let t = animated ? context.date.timeIntervalSinceReferenceDate : 0
      MeshGradient(
        width: 3, height: 3,
        points: [
          [0, 0], [Float(0.5 + 0.2 * sin(t * 0.7)), 0], [1, 0],
          [0, Float(0.5 + 0.25 * cos(t * 0.6))],
          [Float(0.5 + 0.3 * sin(t * 0.9)), Float(0.5 + 0.3 * cos(t * 0.8))],
          [1, Float(0.5 + 0.25 * sin(t * 0.5))],
          [0, 1], [Float(0.5 + 0.2 * cos(t * 0.65)), 1], [1, 1]
        ],
        colors: [
          Self.deep, Self.mid, Self.pale,
          Self.mid, Self.pale, Self.deep,
          Self.pale, Self.deep, Self.mid
        ],
        smoothsColors: true)
    }
    .overlay { Grain().blendMode(.overlay).opacity(0.35) }
  }

  /// 固定の乱数で打つ細かい点（毎回同じ模様なので、ちらつかない）
  private struct Grain: View {
    var body: some View {
      Canvas { context, size in
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> CGFloat {
          seed = seed &* 6364136223846793005 &+ 1442695040888963407
          return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1)
        }
        let count = Int(size.width * size.height / 6)
        for _ in 0..<count {
          let rect = CGRect(x: next() * size.width, y: next() * size.height, width: 1, height: 1)
          context.fill(Path(rect), with: .color(next() > 0.5 ? .white : .black))
        }
      }
      .allowsHitTesting(false)
    }
  }
}

#Preview("KICneo 見出し") {
  VStack(spacing: 24) {
    KICneoHeader()
    KICneoHeader().environment(\.dynamicTypeSize, .accessibility2)
  }
  .padding(AppTheme.Space.page)
  .background(AppTheme.background)
}

#Preview("KICneo 見出し · ダーク") {
  KICneoHeader()
    .padding(AppTheme.Space.page)
    .background(AppTheme.background)
    .preferredColorScheme(.dark)
}
