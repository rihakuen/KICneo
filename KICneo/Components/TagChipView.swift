import SwiftUI

struct TagChipView: View {
  let title: String
  var isSelected: Bool = false
  var style: ChipStyle = .neutral
  var action: (() -> Void)? = nil

  enum ChipStyle {
    case neutral, format, special, status
  }

  var body: some View {
    if let action {
      Button {
        AppHaptics.selection()
        action()
      } label: { chipLabel.frame(minHeight: 44) }
        .buttonStyle(CardPressStyle())
    } else {
      chipLabel
    }
  }

  private var chipLabel: some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .foregroundStyle(foregroundColor)
      .modernChip(background: backgroundColor, isSelected: isSelected)
  }

  private var foregroundColor: Color {
    switch style {
    case .neutral:
      return isSelected ? AppTheme.primaryAction : AppTheme.textSecondary
    case .format:
      return AppTheme.formatTag
    case .special:
      return AppTheme.specialTag
    case .status:
      return AppTheme.highlightAccent
    }
  }

  private var backgroundColor: Color {
    switch style {
    case .neutral:
      return AppTheme.elevatedBackground
    case .format:
      return AppTheme.formatTagBackground
    case .special:
      return AppTheme.specialTagBackground
    case .status:
      return AppTheme.highlightAccent.opacity(0.12)
    }
  }
}
