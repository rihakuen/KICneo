import SwiftUI
import UIKit

// MARK: - Design Tokens（ライト / ダーク対応）
// 背景・文字・区切り線は iOS のシステム色を使う。ライト/ダーク、コントラストを上げる設定、
// iOS 26 のナビゲーションバー・タブバーの見た目に自動で合う。状態色とブランド色だけ独自に持つ。

enum AppTheme {
  // 同じ役割の部品には同じ寸法を使う。カード / 操作部品 / 小ラベルの3段階。
  enum Space {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let page: CGFloat = 20
    static let section: CGFloat = 24
    /// カードの内側の余白（角丸のふちから文字まで）。すべてのカードで同じ値を使う
    static let card: CGFloat = 16
    /// カードとカードの間隔
    static let cardGap: CGFloat = 16
    /// カードの中の、まとまりとまとまりの間隔（見出しの行・中身・区切り線など）
    static let cardStack: CGFloat = 12
  }

  /// 文字の大きさと太さ。どの画面でも、同じ役割の文字は同じ書式にする（主文字・副文字・説明）。
  /// 色は、主文字が textPrimary、label・caption は textSecondary。
  enum Typography {
    /// カードの見出し。そのカードでいちばん大きな文字（「8/30〜9/5」「2026年11月」、説明会の企業名など）
    static let cardTitle = Font.title3.weight(.semibold)
    /// 数のまとめ（「87 コマ」「15 科目」など）
    static let stat = Font.title2.bold()
    /// 行の主文字（科目名・企業名・選んだ日の日付など）
    static let headline = Font.headline
    /// 本文・一覧の行の文字
    static let body = Font.subheadline
    /// 本文の強調（時限、ボタンの文字など）
    static let bodyEmphasis = Font.subheadline.weight(.semibold)
    /// カード上部の小見出し（「年間出席率」「9月の内訳」「申込締切」など）。textSecondary で使う
    static let label = Font.footnote.weight(.semibold)
    /// 補足の説明（期間・単位・凡例・状態）。textSecondary で使う
    static let caption = Font.caption
    /// 補足の強調・タグ（「出席」「欠席」、曜日など）
    static let captionEmphasis = Font.caption.weight(.semibold)
  }

  enum Motion {
    static func feedback(reduce: Bool) -> Animation {
      reduce ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.88)
    }

    static func transition(reduce: Bool) -> Animation {
      reduce ? .easeOut(duration: 0.12) : .spring(response: 0.38, dampingFraction: 0.9)
    }

    /// 文字の切り替え（数字のロール・ぼかし置換・太さの補間）に使う動き。
    /// 動きを減らす設定では nil（アニメーションなしで即時に切り替える）。
    static func text(reduce: Bool) -> Animation? {
      reduce ? nil : .snappy(duration: 0.3)
    }
  }

  static let accent = Color("AccentColor")

  /// カード（大）> バナー（中）> ボタン・入力欄（小）> タグ（チップ）の4段階。
  enum Radius {
    static let large: CGFloat = 20
    static let medium: CGFloat = 16
    static let small: CGFloat = 14
    static let chip: CGFloat = 8
  }

  static let background = Color(uiColor: .systemGroupedBackground)

  static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)

  static let elevatedBackground = Color(uiColor: .tertiarySystemGroupedBackground)

  static let border = Color(uiColor: .separator)

  static let textPrimary = Color(uiColor: .label)

  static let textSecondary = Color(uiColor: .secondaryLabel)

  static let textTertiary = Color(uiColor: .tertiaryLabel)

  static let primaryAction = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 0.37, green: 0.62, blue: 1.0, alpha: 1)
      : UIColor(red: 0.11, green: 0.31, blue: 0.85, alpha: 1)
  })

  static let success = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 0.30, green: 0.84, blue: 0.58, alpha: 1)
      : UIColor(red: 0.05, green: 0.60, blue: 0.40, alpha: 1)
  })

  static let warning = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 0.98, green: 0.75, blue: 0.25, alpha: 1)
      : UIColor(red: 0.78, green: 0.48, blue: 0.05, alpha: 1)
  })

  /// 休み（授業のない平日）。出席・欠課・就職の色（緑・黄・青）と重ならない、やわらかいローズ。
  static let holiday = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 1.0, green: 0.50, blue: 0.58, alpha: 1)
      : UIColor(red: 0.80, green: 0.20, blue: 0.33, alpha: 1)
  })

  static let formatTag = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 0.37, green: 0.62, blue: 1.0, alpha: 1)
      : UIColor(red: 0.11, green: 0.31, blue: 0.85, alpha: 1)
  })

  static let specialTag = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 0.30, green: 0.84, blue: 0.58, alpha: 1)
      : UIColor(red: 0.05, green: 0.60, blue: 0.40, alpha: 1)
  })

  static let formatTagBackground = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 0.37, green: 0.62, blue: 1.0, alpha: 0.14)
      : UIColor(red: 0.11, green: 0.31, blue: 0.85, alpha: 0.08)
  })

  static let specialTagBackground = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 0.30, green: 0.84, blue: 0.58, alpha: 0.14)
      : UIColor(red: 0.05, green: 0.60, blue: 0.40, alpha: 0.08)
  })

  static let highlightAccent = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 0.98, green: 0.75, blue: 0.25, alpha: 1)
      : UIColor(red: 0.78, green: 0.48, blue: 0.05, alpha: 1)
  })

  static let toastBackground = Color(uiColor: .secondarySystemGroupedBackground)

  static let heroGradient = LinearGradient(
    colors: [
      Color(red: 0.45, green: 0.28, blue: 0.92),
      Color(red: 0.92, green: 0.45, blue: 0.55),
      Color(red: 0.98, green: 0.72, blue: 0.35)
    ],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
  )

  static let celebrationBackground = Color(uiColor: UIColor { trait in
    trait.userInterfaceStyle == .dark
      ? UIColor(red: 0.08, green: 0.10, blue: 0.22, alpha: 1)
      : UIColor(red: 0.10, green: 0.14, blue: 0.32, alpha: 1)
  })

  static var cardShadow: Color {
    Color.black.opacity(0.08)
  }
}

struct AppBackgroundView: View {
  var body: some View {
    AppTheme.background
      .ignoresSafeArea()
  }
}

struct WalletCardModifier: ViewModifier {
  var cornerRadius: CGFloat = AppTheme.Radius.large
  var highlighted: Bool = false

  @Environment(\.colorScheme) private var colorScheme

  func body(content: Content) -> some View {
    content
      .background(AppTheme.cardBackground)
      .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .strokeBorder(highlighted ? AppTheme.highlightAccent.opacity(0.5) : AppTheme.border, lineWidth: highlighted ? 1.5 : 0.5)
      }
      .shadow(color: AppTheme.cardShadow, radius: colorScheme == .dark ? 8 : 14, y: colorScheme == .dark ? 3 : 6)
  }
}

struct WalletChipModifier: ViewModifier {
  var background: Color
  var isSelected: Bool = false

  func body(content: Content) -> some View {
    content
      .background(isSelected ? AppTheme.primaryAction.opacity(0.14) : background)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.chip, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AppTheme.Radius.chip, style: .continuous)
          .strokeBorder(isSelected ? AppTheme.primaryAction : AppTheme.border.opacity(0.6), lineWidth: isSelected ? 1.5 : 0.5)
      }
  }
}

extension View {
  func walletCard(cornerRadius: CGFloat = AppTheme.Radius.large, highlighted: Bool = false) -> some View {
    modifier(WalletCardModifier(cornerRadius: cornerRadius, highlighted: highlighted))
  }

  func walletChip(background: Color, isSelected: Bool = false) -> some View {
    modifier(WalletChipModifier(background: background, isSelected: isSelected))
  }

  func modernCard(highlighted: Bool = false) -> some View {
    walletCard(highlighted: highlighted)
  }

  func modernChip(background: Color, isSelected: Bool = false) -> some View {
    walletChip(background: background, isSelected: isSelected)
  }

  func glassCard(cornerRadius: CGFloat = AppTheme.Radius.large, highlighted: Bool = false) -> some View {
    walletCard(cornerRadius: cornerRadius, highlighted: highlighted)
  }

  func glassCapsule() -> some View {
    walletChip(background: AppTheme.elevatedBackground)
  }
}

struct PrimaryButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var tint: Color = AppTheme.primaryAction

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .frame(minHeight: 20)
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(tint.opacity(configuration.isPressed ? 0.82 : 1))
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(AppTheme.Motion.feedback(reduce: reduceMotion), value: configuration.isPressed)
  }
}

struct SecondaryButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(AppTheme.textPrimary)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 14)
      .background(AppTheme.elevatedBackground.opacity(configuration.isPressed ? 0.7 : 1))
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous)
          .strokeBorder(AppTheme.border, lineWidth: 0.5)
      }
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(AppTheme.Motion.feedback(reduce: reduceMotion), value: configuration.isPressed)
  }
}

struct PillButtonStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(AppTheme.textPrimary)
      .padding(.horizontal, 18)
      .padding(.vertical, 10)
      .background(AppTheme.elevatedBackground)
      .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.small, style: .continuous))
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
      .animation(AppTheme.Motion.feedback(reduce: reduceMotion), value: configuration.isPressed)
  }
}

/// アニメーションを切った transaction（月送りなど）の中で値が変わっても、この部分の文字だけは
/// `.numericText()` などの切り替えアニメーションを付ける。動きを減らす設定では付けない。
struct TextTransitionModifier<Value: Equatable>: ViewModifier {
  let value: Value
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  func body(content: Content) -> some View {
    content.transaction(value: value) { transaction in
      transaction.disablesAnimations = false
      transaction.animation = AppTheme.Motion.text(reduce: reduceMotion)
    }
  }
}

extension View {
  func textTransition<Value: Equatable>(on value: Value) -> some View {
    modifier(TextTransitionModifier(value: value))
  }
}

typealias PrimaryGlassButtonStyle = PrimaryButtonStyle
typealias SecondaryGlassButtonStyle = SecondaryButtonStyle

/// 触覚は操作の境界で一度だけ発火。ユーザー設定をすべての入口で尊重する。
@MainActor
enum AppHaptics {
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: "ui_haptics_enabled") as? Bool ?? true
  }

  static func selection() {
    guard isEnabled else { return }
    UISelectionFeedbackGenerator().selectionChanged()
  }

  static func success() {
    guard isEnabled else { return }
    UINotificationFeedbackGenerator().notificationOccurred(.success)
  }

  static func light() {
    guard isEnabled else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
  }
}

struct CardPressStyle: ButtonStyle {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      // 余白や Spacer の部分もタップできるようにする（文字の上だけが反応しないように）
      .contentShape(Rectangle())
      .opacity(configuration.isPressed ? 0.82 : 1)
      .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
      .animation(AppTheme.Motion.feedback(reduce: reduceMotion), value: configuration.isPressed)
  }
}
