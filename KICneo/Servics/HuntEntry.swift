import Foundation
import SwiftSoup

/// 就職活動入力の「追加」フォームで使う値。空の項目は学校側の既定値のままにする。
nonisolated struct HuntEntryValues: Sendable {
  struct Attachment: Sendable {
    let data: Data
    let filename: String
    let mimeType: String
  }

  var year = ""
  var date = "" // yyyy/MM/dd
  var kind = ""
  var periodFrom = ""
  var periodTo = ""
  var mode = ""
  var useManualCompany = false
  var companySearch = "" // 企業名（学校の登録企業を絞り込む検索文字）
  var companyChoice = "" // 企業選択（絞り込み後に選んだ候補の値）
  var company = "" // 企業名手入力（登録企業にない場合）
  var job = ""
  var location = ""
  var attachment: Attachment?
}

/// 学校ページが自動 postback（`AutoPostBack`）で反応する項目。
nonisolated enum HuntField {
  case date, companySearch, companyChoice, company

  var controlName: String {
    switch self {
    case .date: return "活動日"
    case .companySearch: return "企業名"
    case .companyChoice: return "企業選択"
    case .company: return "企業名手入力"
    }
  }
}

/// 学校ページの新增列の現在の状態（選択肢と、有効/無効）。
nonisolated struct HuntFormState: Sendable {
  struct Option: Sendable, Hashable, Identifiable {
    let value: String
    let label: String
    var id: String {
      value
    }
  }

  var year = ""
  var kinds: [Option] = []
  var periods: [Option] = []
  var modes: [Option] = []
  var jobs: [Option] = []
  /// 企業名で絞り込んだ後の候補（空欄を除く）。絞り込み前は件数が多いので空にしておく。
  var companies: [Option] = []
  var companyCount = 0
  var selectedCompany = ""
  var periodsEnabled = false
  var attachmentEnabled = false
  var message = ""
}

extension SchoolClient {
  static let huntPrefix = "ctl00$msp_asp_cph1$lv_就職活動一覧$ctrl0$"

  /// ブラウザと同じようにフォームの値を集める。disabled、submit/button/image/file/reset、チェックされていない checkbox/radio は除く。
  @concurrent
  static func collectFormState(_ html: String) async throws -> [String: String] {
    let doc = try SwiftSoup.parse(html)
    var state: [String: String] = [:]
    for el in try doc.select("input, select, textarea") {
      let name = try el.attr("name")
      if name.isEmpty || el.hasAttr("disabled") {
        continue
      }
      switch el.tagName() {
      case "select":
        let option = try el.select("option[selected]").first() ?? el.select("option").first()
        if let option {
          let value = try option.attr("value")
          state[name] = value.isEmpty && !option.hasAttr("value") ? try option.text() : value
        }
      case "textarea":
        state[name] = try el.text()
      default:
        let type = try el.attr("type").lowercased()
        if ["submit", "button", "image", "file", "reset"].contains(type) {
          continue
        }
        if type == "checkbox" || type == "radio" {
          if el.hasAttr("checked") {
            state[name] = try el.attr("value").isEmpty ? "on" : el.attr("value")
          }
        } else {
          state[name] = try el.attr("value")
        }
      }
    }
    return state
  }

  @concurrent
  static func parseHuntForm(_ html: String) async throws -> HuntFormState {
    let doc = try SwiftSoup.parse(html)
    func element(_ field: String) throws -> Element? {
      let name = huntPrefix + field
      return try doc.select("input, select").array().first { (try? $0.attr("name")) == name }
    }
    func options(_ field: String) throws -> [HuntFormState.Option] {
      guard let select = try element(field) else { return [] }
      return try select.select("option").array().map {
        try HuntFormState.Option(value: $0.attr("value"), label: $0.text())
      }
    }
    guard try element("追加") != nil else { throw SchoolError.parseFailed }
    var state = HuntFormState()
    state.year = try element("活動年度")?.attr("value") ?? ""
    state.kinds = try options("区分CD")
    state.periods = try options("時限FROM")
    state.modes = try options("オンライン区分")
    state.jobs = try options("職種CD")
    let companyOptions = try options("企業選択").filter { !$0.value.isEmpty }
    state.companyCount = companyOptions.count
    if companyOptions.count <= 200 {
      state.companies = companyOptions
    }
    state.selectedCompany = try element("企業選択")?.select("option[selected]").first()?.attr("value") ?? ""
    state.periodsEnabled = try element("時限FROM").map { !$0.hasAttr("disabled") } ?? false
    state.attachmentEnabled = try element("fileup添付").map { !$0.hasAttr("disabled") } ?? false
    state.message = try doc.select("[id$=lbl_Error]").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return state
  }

  /// 入力した値をフォームの値に上書きする。今有効な（state にある）項目だけを上書きする。
  nonisolated static func applyHuntValues(_ values: HuntEntryValues, to state: inout [String: String]) {
    // 登録企業から選ぶモードでは手入力欄を空に、手入力モードでは検索文字と候補選択を空にして送る
    // （学校側は絞り込み結果が1件だと自動で選択するため、混ぜると意図しない企業が登録される）
    let map: [(String, String)] = [
      ("活動年度", values.year), ("活動日", values.date), ("区分CD", values.kind),
      ("時限FROM", values.periodFrom), ("時限TO", values.periodTo),
      ("オンライン区分", values.mode),
      ("企業名", values.useManualCompany ? "" : values.companySearch),
      ("企業選択", values.useManualCompany ? "" : values.companyChoice),
      ("企業名手入力", values.useManualCompany ? values.company : ""),
      ("職種CD", values.job), ("txt勤務地手入力", values.location)
    ]
    for (field, value) in map {
      let name = huntPrefix + field
      if state[name] != nil, !(value.isEmpty && ["活動年度"].contains(field)) {
        state[name] = value
      }
    }
  }

  nonisolated static func multipartBody(fields: [String: String], file: (name: String, attachment: HuntEntryValues.Attachment?), boundary: String) -> Data {
    var body = Data()
    func add(_ s: String) {
      body.append(Data(s.utf8))
    }
    for (name, value) in fields {
      add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
    }
    if let attachment = file.attachment {
      add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(attachment.filename)\"\r\nContent-Type: \(attachment.mimeType)\r\n\r\n")
      body.append(attachment.data)
      add("\r\n")
    } else {
      // ブラウザは未選択のファイル欄も空のパートとして送る
      add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\"\r\nContent-Type: application/octet-stream\r\n\r\n\r\n")
    }
    add("--\(boundary)--\r\n")
    return body
  }
}
