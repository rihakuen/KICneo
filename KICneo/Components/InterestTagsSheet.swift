import SwiftUI

struct InterestTagsSheet: View {
  @ObservedObject var viewModel: EventViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      ZStack {
        AppBackgroundView()

        ScrollView {
          VStack(alignment: .leading, spacing: 20) {
            Text("関心タグを選ぶと、該当する説明会が上位に表示されます。")
              .font(.subheadline)
              .foregroundStyle(AppTheme.textSecondary)

            FlowLayout(spacing: AppTheme.Space.sm) {
              ForEach(viewModel.availableTags, id: \.self) { tag in
                TagChipView(
                  title: tag,
                  isSelected: viewModel.isInterestTagSelected(tag),
                  style: .special
                ) {
                  viewModel.toggleInterestTag(tag)
                }
              }
            }
          }
          .padding(20)
        }
      }
      .navigationTitle("関心タグ")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("完了") { dismiss() }
            .foregroundStyle(AppTheme.primaryAction)
        }
      }
    }
  }
}

/// タグを折り返し表示する簡易レイアウト
struct FlowLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let result = arrange(proposal: proposal, subviews: subviews)
    return result.size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = arrange(proposal: proposal, subviews: subviews)
    for (index, frame) in result.frames.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size)
      )
    }
  }

  private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
    let maxWidth = proposal.width ?? .infinity
    var frames: [CGRect] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0

    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil))
      if x + size.width > maxWidth, x > 0 {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
      rowHeight = max(rowHeight, size.height)
      x += size.width + spacing
    }

    return (CGSize(width: maxWidth, height: y + rowHeight), frames)
  }
}
