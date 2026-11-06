import SwiftUI

struct ActionFeedbackBanner: View {
  let message: String
  let icon: String

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: icon)
        .font(.body.weight(.semibold))
        .foregroundStyle(AppTheme.success)
      Text(message)
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(AppTheme.textPrimary)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
    .background(AppTheme.toastBackground)
    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.medium, style: .continuous))
    .shadow(color: AppTheme.cardShadow, radius: 16, y: 6)
  }
}
