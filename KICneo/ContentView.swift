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
  /// 起動時・ログイン直後に出す、アイコンのタイルの全画面。消えるときに拡大しながらフェードしてホームが見える
  private enum Splash { case launch, afterLogin }
  @State private var splash: Splash? = .launch
  /// 起動のタイルの入場（文字が出そろうまで）が終わったか。終わる前には消さない
  @State private var splashMinimumDone = false

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
          SchoolServicesScreen(school: school) { showLogin = true }
        }
        .tabItem { Label("個人情報", systemImage: "person.crop.circle") }.tag(3)
      }
      .tint(AppTheme.primaryAction)
      .onChange(of: selectedTab) { _, _ in AppHaptics.selection() }
      .scaleEffect(splash == nil || reduceMotion ? 1 : 0.94)

      if let splash {
        StartupLoadingView(entrance: splash == .launch) {
          splashMinimumDone = true
          finishLaunchSplash()
        }
          // 消えるとき：タイルごと拡大しながらフェードして、下のホームが広がって見える
          .transition(.asymmetric(insertion: .identity,
                                  removal: reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.6))))
          .zIndex(10)
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
    .fullScreenCover(isPresented: $showLogin) {
      SchoolLoginView(school: school) { finishLogin() }
        .interactiveDismissDisabled()
    }
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

  /// スプラッシュを消すときの動き（タイルが拡大して抜けていく）
  private var splashExit: Animation {
    reduceMotion ? .easeOut(duration: 0.2) : .smooth(duration: 0.55)
  }

  /// 起動のスプラッシュを閉じる。最低限の時間が過ぎ、最初の表示の準備ができてから。
  /// ログインが必要なら、ログイン画面をアニメーションなしで重ね（同じ背景なので切れ目が見えない）、その下でスプラッシュを外す。
  private func finishLaunchSplash() {
    guard splash == .launch, splashMinimumDone, startupDone else { return }
    let needsLogin = !school.isLoggedIn && (!KeychainService.hasSavedAccount || school.credentialsRejected)
    if needsLogin {
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        showLogin = true
        splash = nil
      }
    } else {
      withAnimation(splashExit) { splash = nil }
    }
  }

  /// ログインできたとき：ログイン画面をアニメーションなしで閉じ、下に出しておいたタイルの画面を
  /// 少し見せてから拡大して消す（起動時と同じ動きでホームに入る）。
  private func finishLogin() {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      splash = .afterLogin
      showLogin = false
    }
    Task {
      try? await Task.sleep(for: .milliseconds(reduceMotion ? 150 : 450))
      withAnimation(splashExit) { splash = nil }
    }
  }
}

#Preview { ContentView() }
