import SwiftUI

struct EmptyStateView: View {
  let icon: String
  let title: String
  let message: String

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 40, weight: .light))
        .foregroundStyle(AppTheme.textTertiary)
      Text(title)
        .font(.headline.weight(.semibold))
        .foregroundStyle(AppTheme.textPrimary)
      Text(message)
        .font(.subheadline)
        .foregroundStyle(AppTheme.textSecondary)
        .multilineTextAlignment(.center)
    }
    .padding(28)
    .frame(maxWidth: .infinity)
    .modernCard()
  }
}
