import SwiftUI

struct DashboardHeaderView: View {
  @ObservedObject var viewModel: EventViewModel
  @Environment(\.dynamicTypeSize) private var typeSize
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let layout = typeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
    layout {
      Text("\(viewModel.totalEventCount)件").font(.title2.weight(.bold)).monospacedDigit()
        .contentTransition(.numericText(value: Double(viewModel.totalEventCount)))
      Spacer(minLength: 0)
      Text("\(viewModel.graduationCountdownLabel) \(viewModel.graduationCountdownText)")
        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
        .contentTransition(.numericText(countsDown: true))
    }
    .animation(AppTheme.Motion.text(reduce: reduceMotion), value: viewModel.totalEventCount)
    .animation(AppTheme.Motion.text(reduce: reduceMotion), value: viewModel.graduationCountdownText)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 8)
  }
}

struct GraduationSettingsSheet: View {
  @ObservedObject var viewModel: EventViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var selectedDate = Date()
  @State private var labelText = ""

  var body: some View {
    NavigationStack {
      ZStack {
        AppBackgroundView()

        Form {
          Section {
            TextField("表示ラベル", text: $labelText)
            DatePicker("期限日", selection: $selectedDate, displayedComponents: .date)
          } header: {
            Text("カウントダウン設定")
          } footer: {
            Text("例: 「卒業まで」「就活終了まで」など自由に設定できます。")
          }

          Section {
            HStack {
              Text("残り日数")
              Spacer()
              Text(previewCountdown)
                .foregroundStyle(AppTheme.primaryAction)
                .fontWeight(.semibold)
            }
          }
        }
        .scrollContentBackground(.hidden)
      }
      .navigationTitle("期限設定")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("キャンセル") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("保存") {
            viewModel.graduationDate = selectedDate
            viewModel.updateGraduationLabel(labelText)
            dismiss()
          }
          .fontWeight(.semibold)
        }
      }
      .onAppear {
        selectedDate = viewModel.graduationDate
        labelText = viewModel.graduationCountdownLabel
      }
    }
    .presentationDetents([.medium, .large])
  }

  private var previewCountdown: String {
    let start = Calendar.current.startOfDay(for: Date())
    let end = Calendar.current.startOfDay(for: selectedDate)
    let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
    if days > 0 {
      return "\(days) 日"
    }
    if days == 0 {
      return "今日"
    }
    return "\(abs(days)) 日超過"
  }
}
