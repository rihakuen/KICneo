import SwiftUI
import UniformTypeIdentifiers

/// 就職活動の追加フォーム。項目はどの順番で入力してもよい。
/// 「送信する」を押すと、学校ページと同じ順序（日付 → 企業 → 追加）でアプリが順に送信する。
/// 確認して送信するまで、学校には何も送られない。
struct HuntEntryView: View {
  @ObservedObject var school: SchoolViewModel
  @Environment(\.dismiss) private var dismiss
  @State private var date = Date()
  @State private var showFileImporter = false
  @State private var showConfirm = false
  @State private var fileError: String?
  @State private var companySearched = false

  private static let formatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy/MM/dd"
    return f
  }()

  private var values: HuntEntryValues {
    school.huntValues
  }

  private var form: HuntFormState {
    school.huntForm
  }

  private var hasCompany: Bool {
    values.useManualCompany
      ? !values.company.trimmingCharacters(in: .whitespaces).isEmpty
      : !values.companyChoice.isEmpty
  }

  private var canSubmit: Bool {
    !values.kind.isEmpty && hasCompany && !school.isHuntFormBusy
  }

  var body: some View {
    NavigationStack {
      Form {
        companySection
        Section("活動") {
          DatePicker("活動日", selection: $date, displayedComponents: .date)
            .onChange(of: date) { _, newValue in applyDate(newValue) }
          Picker("区分", selection: $school.huntValues.kind) {
            Text("未選択").tag("")
            ForEach(form.kinds.filter { !$0.value.isEmpty }) { Text($0.label).tag($0.value) }
          }
          Picker("職種", selection: $school.huntValues.job) {
            Text("未選択").tag("")
            ForEach(form.jobs.filter { !$0.value.isEmpty }) { Text($0.label).tag($0.value) }
          }
          TextField("勤務地", text: $school.huntValues.location)
        }
        do {
          Section("公欠申請（必要な場合）") {
            Picker("時限 開始", selection: $school.huntValues.periodFrom) {
              Text("未選択").tag("")
              ForEach(periodOptions) { Text($0.label).tag($0.value) }
            }
            Picker("時限 終了", selection: $school.huntValues.periodTo) {
              Text("未選択").tag("")
              ForEach(periodOptions) { Text($0.label).tag($0.value) }
            }
            Picker("オンライン / 訪問", selection: $school.huntValues.mode) {
              Text("未選択").tag("")
              ForEach(form.modes.filter { !$0.value.isEmpty }) { Text($0.label).tag($0.value) }
            }
            Button {
              showFileImporter = true
            } label: {
              Label(values.attachment?.filename ?? "添付資料を選ぶ（PDF・画像）", systemImage: "paperclip")
            }
            if values.attachment != nil {
              Button("添付を外す", role: .destructive) { school.huntValues.attachment = nil }
            }
          }
        }
        if let message = school.huntFormError ?? fileError {
          Section { Text(message).foregroundStyle(.red) }
        }
        Section {
          Button {
            showConfirm = true
          } label: {
            HStack {
              if school.isHuntFormBusy {
                ProgressView()
              }
              Text(school.isHuntFormBusy ? "処理中…" : "内容を確認する")
            }
            .frame(maxWidth: .infinity)
          }
          .disabled(!canSubmit)
        } footer: {
          Text("確認してから送信するまで、学校には何も送られません。")
        }
      }
      .navigationTitle("就職活動を追加")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } }
      }
      .task {
        await school.beginHuntEntry()
        school.huntValues.date = Self.formatter.string(from: date)
      }
      .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.pdf, .png, .jpeg]) { result in
        loadFile(result)
      }
      .alert("学校に送信しますか？", isPresented: $showConfirm) {
        Button("キャンセル", role: .cancel) {}
        Button("送信する") {
          Task {
            if await school.submitHuntEntry() {
              dismiss()
            }
          }
        }
      } message: {
        Text(summary)
      }
    }
  }

  private var companySection: some View {
    Section {
      Picker("企業", selection: $school.huntValues.useManualCompany) {
        Text("学校の登録企業から選ぶ").tag(false)
        Text("手入力").tag(true)
      }
      .pickerStyle(.segmented)
      if values.useManualCompany {
        TextField("企業名", text: $school.huntValues.company)
      } else {
        HStack {
          TextField("企業名で検索", text: $school.huntValues.companySearch)
            .submitLabel(.search)
            .onSubmit { search() }
          Button("検索") { search() }
            .disabled(values.companySearch.trimmingCharacters(in: .whitespaces).isEmpty || school.isHuntFormBusy)
        }
        if companySearched {
          if form.companyCount == 0 {
            Text("学校の登録企業に該当がありません。「手入力」に切り替えてください。")
              .font(.caption).foregroundStyle(.secondary)
          } else if form.companies.isEmpty {
            Text("候補が多すぎます（\(form.companyCount)件）。企業名をもう少し具体的に入力してください。")
              .font(.caption).foregroundStyle(.secondary)
          } else {
            Picker("候補", selection: $school.huntValues.companyChoice) {
              if form.companies.count > 1 {
                Text("選択してください").tag("")
              }
              ForEach(form.companies) { Text(Self.companyName($0.label)).tag($0.value) }
            }
          }
        }
      }
    } header: {
      Text("企業")
    } footer: {
      Text(values.useManualCompany
        ? "学校の登録企業にない場合のみ手入力してください。"
        : "企業名の一部で検索すると、学校に登録されている企業の候補が表示されます。")
    }
  }

  private func search() {
    companySearched = true
    Task { await school.searchCompany() }
  }

  /// 候補の表示名から先頭の企業コード（例: "0000247 "）を取り除く。
  private static func companyName(_ label: String) -> String {
    label.replacingOccurrences(of: #"^\d+\s+"#, with: "", options: .regularExpression)
  }

  private var companyDisplayName: String {
    if values.useManualCompany {
      return values.company + "（手入力）"
    }
    let label = form.companies.first { $0.value == values.companyChoice }?.label ?? values.companySearch
    return Self.companyName(label)
  }

  private var summary: String {
    func label(_ options: [HuntFormState.Option], _ value: String) -> String {
      options.first { $0.value == value }?.label ?? ""
    }
    var lines = [
      "活動日: \(values.date)",
      "区分: \(label(form.kinds, values.kind))",
      "企業名: \(companyDisplayName)"
    ]
    if !values.job.isEmpty {
      lines.append("職種: \(label(form.jobs, values.job))")
    }
    if !values.location.isEmpty {
      lines.append("勤務地: \(values.location)")
    }
    do {
      let from = label(periodOptions, values.periodFrom), to = label(periodOptions, values.periodTo)
      if !from.isEmpty || !to.isEmpty {
        lines.append("時限: \(from) ～ \(to)")
      }
      if !values.mode.isEmpty {
        lines.append("形式: \(label(form.modes, values.mode))")
      }
      if let file = values.attachment {
        lines.append("添付: \(file.filename)")
      }
    }
    return lines.joined(separator: "\n")
  }

  /// 時限の選択肢。学校は日付を入れた後に配るが、内容は固定（1〜5限・放課後）なので既定値を持っておく。
  private var periodOptions: [HuntFormState.Option] {
    let fromServer = form.periods.filter { !$0.value.isEmpty }
    if !fromServer.isEmpty {
      return fromServer
    }
    return (1 ... 5).map { .init(value: "\($0)", label: "\($0)") } + [.init(value: "99", label: "放課後")]
  }

  private func applyDate(_ newValue: Date) {
    school.huntValues.date = Self.formatter.string(from: newValue)
  }

  private func loadFile(_ result: Result<URL, Error>) {
    fileError = nil
    guard case .success(let url) = result else { return }
    let scoped = url.startAccessingSecurityScopedResource()
    defer {
      if scoped {
        url.stopAccessingSecurityScopedResource()
      }
    }
    guard let data = try? Data(contentsOf: url) else {
      fileError = "ファイルを読み込めませんでした。"
      return
    }
    let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    school.huntValues.attachment = .init(data: data, filename: url.lastPathComponent, mimeType: mime)
  }
}
