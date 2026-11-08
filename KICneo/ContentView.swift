import SwiftUI

struct ContentView: View {
  @StateObject private var viewModel = EventViewModel()
  @StateObject private var school = SchoolViewModel()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // アカウントが保存されていれば先にメイン画面を出し、裏で自動ログインする。無ければログイン画面を出す。
  // ログイン画面は起動の演出（スプラッシュ）が終わってから出す
  @State private var showLogin = false
  /// 保存済みのアカウントがある起動直後は、ログインと最初のデータ取得が終わるまで全画面ローディングを出す。
  /// ただし前回の内容が端末に保存されていれば、それをすぐ表示できるのでローディングは出さない。
  @State private var startupDone = !KeychainService.hasSavedAccount || AccountCache.hasCache(AccountCache.attendance)
  @State private var selectedTab = 0
  /// 起動時・ログイン直後に出す、アイコンのタイルの全画面（BrandSplashView）。
  /// 消えるときは、タイルの「KIC」「neo」が次の画面のロゴの位置（ホームの見出し・ログイン画面のタイル）へ移っていく
  private enum Splash { case launch, afterLogin }
  @State private var splash: Splash? = .launch
  @State private var splashPhase: BrandSplashView.Phase = .center
  /// 起動のタイルの入場（文字が出そろうまで）が終わったか。終わる前には消さない
  @State private var splashMinimumDone = false
  /// ホームの見出し・ログイン画面のタイルの位置（子の画面が書き込む。再描画を起こさない入れ物）
  @State private var brandAnchors = BrandAnchorStore()
  /// 起動画面のタイルがログイン画面のタイルに重なっている間、ログイン画面のタイルを隠す
  @State private var hidesLoginTile = false
  /// ログインできたあとの全画面（色が広がる → KICneo → 読み込み → ホームへ）。nil のときは出さない
  @State private var loginCover: BrandLoginCover.Phase?
  /// ホームを作り直すための番号。ログインのたびに変え、カレンダー・出席率を「今日・今月（月間）」から始める
  /// （アプリを終了して起動し直したときは、もともと今日・月間から始まる）
  @State private var homeResetID = 0

  var body: some View {
    ZStack {
      TabView(selection: $selectedTab) {
        NavigationStack {
          HomeScreen(
            records: school.days,
            rates: school.attendanceRates,
            loadedRatePeriods: school.loadedRatePeriods,
            loadingRatePeriods: school.loadingRatePeriods,
            failedRatePeriods: school.failedRatePeriods,
            errorMessage: school.errorMessage,
            loadedMonths: school.loadedMonths,
            loadingMonths: school.loadingMonths,
            timetable: school.timetable,
            isLoadingTimetable: school.isLoadingTimetable,
            timetableLoadFailed: school.timetableLoadFailed,
            onRefresh: {
              async let attendance: Void = school.refreshAttendance()
              async let timetable: Void = school.loadTimetable(force: true)
              async let notices: Void = school.loadNotices(force: true)
              _ = await (attendance, timetable, notices)
            },
            onMonthChange: { from, through in
              school.requestMonthlyRate(for: from)
              await school.loadAttendance(from: from, through: through)
            },
            noticesSection: AnyView(SchoolNoticesCard(school: school))
          )
          .id(homeResetID)
          .task { await school.loadTimetable() }
          .task(id: school.isLoggedIn) { await school.loadNotices() }
        }
        .tabItem { Label("ホーム", systemImage: "house") }.tag(0)
        NavigationStack {
          BrowseEventsView(
            viewModel: viewModel,
            school: school,
            onRefresh: { await school.loadSchoolEvents(force: true) }
          )
        }
        // 説明会タブを開いたとき、まだ一覧が無ければ取り直す（ログイン直後の取得に失敗していた場合など）
        .task(id: school.isLoggedIn) {
          if school.isLoggedIn, school.schoolEvents.isEmpty { await school.loadSchoolEvents() }
        }
        .tabItem { Label("説明会", systemImage: "building.2") }.tag(1)
        NavigationStack {
          LeaveApplicationScreen(school: school)
        }
        .tabItem { Label("公欠・就職活動", systemImage: "doc.text") }.tag(2)
        NavigationStack {
          SchoolServicesScreen(school: school) {
            withAnimation(AppTheme.Motion.transition(reduce: reduceMotion)) { showLogin = true }
          }
        }
        .tabItem { Label("個人情報", systemImage: "person.crop.circle") }.tag(3)
      }
      .tint(AppTheme.primaryAction)
      .onChange(of: selectedTab) { _, _ in AppHaptics.selection() }
      // 起動画面がまだ中央にある間は、ホームを少し縮めておき、文字が見出しへ飛ぶのと一緒に広げる
      .scaleEffect(!reduceMotion && ((splash != nil && splashPhase == .center)
                                      || (loginCover.map { $0 >= .covered && $0 < .finishing } ?? false)) ? 0.94 : 1)

      // ログイン画面（全画面の重ね）。ホームと同じ階層に置くと、ロゴの位置を起動画面の動きと共有できる
      if showLogin {
        SchoolLoginView(school: school) { finishLogin() }
          .transition(.opacity)
          .zIndex(5)
      }

      if let splash {
        BrandSplashView(phase: splashPhase, entrance: splash == .launch,
                        loginTile: brandAnchors.loginTile, header: brandAnchors.header) {
          splashMinimumDone = true
          finishLaunchSplash()
        }
        .allowsHitTesting(splashPhase == .center)
        .zIndex(10)
      }

      if let loginCover {
        BrandLoginCover(phase: loginCover, origin: brandAnchors.loginButton, header: brandAnchors.header)
          .allowsHitTesting(loginCover < .finishing)
          .zIndex(11)
      }

      if let message = viewModel.toastMessage {
        VStack {
          ActionFeedbackBanner(message: message, icon: viewModel.toastIcon)
            .padding(.horizontal, AppTheme.Space.page)
            .padding(.top, AppTheme.Space.sm)
            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
          Spacer()
        }
        .allowsHitTesting(false)
      }
      if viewModel.showCelebration {
        if reduceMotion {
          VStack(spacing: AppTheme.Space.lg) {
            Text("お疲れ様でした！").font(.title.bold())
            Button("閉じる") { viewModel.dismissCelebration() }.buttonStyle(PrimaryButtonStyle())
          }
          .padding(AppTheme.Space.section).walletCard().padding(AppTheme.Space.page)
        } else {
          CelebrationOverlayView { viewModel.dismissCelebration() }
            .transition(.opacity)
        }
      }
    }
    .animation(AppTheme.Motion.transition(reduce: reduceMotion), value: viewModel.toastMessage)
    .environment(\.brandAnchors, BrandAnchors(store: brandAnchors, hideHeader: splash != nil || loginCover != nil,
                                               hideLoginTile: hidesLoginTile))
    .onChange(of: startupDone) { _, _ in finishLaunchSplash() }
    .onChange(of: school.schoolEvents) { _, events in viewModel.schoolEvents = events }
    .task {
      if DemoData.isEnabled { // スクリーンショット用（起動引数 -demo）。学校には接続しない
        school.startDemo()
        showLogin = false
        startupDone = true
        return
      }
      await school.loadCachedData() // 保存済みの内容を先に表示（デコードは主スレッドの外）
      // 通信が遅くても操作できなくならないよう、一定時間でローディングを閉じる（データは裏で読み込み続ける）
      let safety = Task {
        try? await Task.sleep(for: .seconds(12))
        startupDone = true
      }
      await school.restoreSession()
      if school.isLoggedIn {
        showLogin = false
      }
      if school.credentialsRejected, splash == nil {
        showLogin = true
      }
      startupDone = true
      safety.cancel()
    }
  }

  /// ロゴが次の画面へ移る動き
  private var splashExit: Animation {
    reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.6)
  }

  private var splashExitDuration: Duration { .milliseconds(reduceMotion ? 220 : 650) }

  private func withoutAnimation(_ body: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, body)
  }

  /// 起動画面を閉じる。入場が終わり、最初の表示の準備ができてから。
  /// - ログインが必要：ログイン画面を下に出し、タイルをログイン画面のタイルの位置へ移す（背景は消えて下が見える）
  /// - ログイン済み：タイルの「KIC」「neo」をホームの見出しの位置へ飛ばし、ホームを広げる
  private func finishLaunchSplash() {
    guard splash == .launch, splashPhase == .center, splashMinimumDone, startupDone else { return }
    let needsLogin = !school.isLoggedIn && (!KeychainService.hasSavedAccount || school.credentialsRejected)
    if needsLogin {
      withoutAnimation {
        showLogin = true
        hidesLoginTile = true
      }
      Task {
        // ログイン画面が並んでタイルの位置がわかるまで、少し待つ
        try? await Task.sleep(for: .milliseconds(60))
        withAnimation(splashExit) { splashPhase = .loginTile }
        try? await Task.sleep(for: splashExitDuration)
        withoutAnimation {
          splash = nil
          splashPhase = .center
          hidesLoginTile = false
        }
      }
    } else {
      withAnimation(splashExit) { splashPhase = .header }
      Task {
        try? await Task.sleep(for: splashExitDuration)
        withoutAnimation {
          splash = nil
          splashPhase = .center
        }
      }
    }
  }

  /// ログインできたとき：ログインボタンから色を広げて画面を覆い、その下でログイン画面を閉じてホームのタブへ切り替える。
  /// 「KICneo」を左から出して読み込みの画面を（押してから）最低 5 秒見せ、最後に色を見出しへ吸い込ませてホームに入る。
  private func finishLogin() {
    let started = ContinuousClock.now
    withoutAnimation { loginCover = .start }
    Task {
      try? await Task.sleep(for: .milliseconds(20))
      AppHaptics.light()
      withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .easeInOut(duration: 0.6)) { loginCover = .covered }
      try? await Task.sleep(for: .milliseconds(reduceMotion ? 220 : 620))
      // 色の下で、ログイン画面を閉じてホームへ
      withoutAnimation {
        showLogin = false
        selectedTab = 0
        homeResetID += 1
      }
      withAnimation(.smooth(duration: 0.5)) { loginCover = .title }
      try? await Task.sleep(for: .milliseconds(reduceMotion ? 200 : 750))
      withAnimation(.smooth(duration: 0.4)) { loginCover = .loading }
      // 押してから最低 5 秒は、この画面を見せる（その間にホームの見出しの位置も決まる）
      try? await Task.sleep(until: started + .seconds(5), clock: .continuous)
      AppHaptics.success()
      withAnimation(reduceMotion ? .easeOut(duration: 0.25) : .smooth(duration: 0.75)) { loginCover = .finishing }
      try? await Task.sleep(for: .milliseconds(reduceMotion ? 280 : 800))
      withoutAnimation { loginCover = nil }
    }
  }
}

#Preview { ContentView() }
