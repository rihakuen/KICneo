import SwiftUI

struct ContentView: View {
  @StateObject private var viewModel = EventViewModel()
  @StateObject private var school = SchoolViewModel()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // アカウントが保存されていれば先にメイン画面を出し、裏で自動ログインする。無ければログイン画面を出す。
  @State private var showLogin = !KeychainService.hasSavedAccount
  /// 保存済みのアカウントがある起動直後は、ログインと最初のデータ取得が終わるまで全画面ローディングを出す。
  /// ただし前回の内容が端末に保存されていれば、それをすぐ表示できるのでローディングは出さない。
  @State private var startupDone = !KeychainService.hasSavedAccount || AccountCache.hasCache(AccountCache.attendance)
  @State private var showInterestSheet = false
  @State private var showGraduationSettings = false
  @State private var showEndJobHuntingConfirm = false
  @State private var selectedTab = 0

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
              _ = await (attendance, timetable)
            },
            onMonthChange: { from, through in
              school.requestMonthlyRate(for: from)
              await school.loadAttendance(from: from, through: through)
            }
          )
          .task { await school.loadTimetable() }
        }
        .tabItem { Label("ホーム", systemImage: "house") }.tag(0)
        NavigationStack {
          BrowseEventsView(
            viewModel: viewModel,
            school: school,
            showInterestSheet: $showInterestSheet,
            onRefresh: { await school.loadSchoolEvents(force: true) },
            showGraduationSettings: $showGraduationSettings,
            showEndJobHuntingConfirm: $showEndJobHuntingConfirm
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

      if !startupDone {
        StartupLoadingView()
          .transition(.opacity)
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
    .animation(.easeOut(duration: 0.25), value: startupDone)
    .fullScreenCover(isPresented: $showLogin) {
      SchoolLoginView(school: school) { showLogin = false }
        .interactiveDismissDisabled()
    }
    .onChange(of: school.schoolEvents) { _, events in viewModel.schoolEvents = events }
    .sheet(isPresented: $showInterestSheet) { InterestTagsSheet(viewModel: viewModel) }
    .sheet(isPresented: $showGraduationSettings) { GraduationSettingsSheet(viewModel: viewModel) }
    .alert("就活を終了しますか？", isPresented: $showEndJobHuntingConfirm) {
      Button("キャンセル", role: .cancel) {}
      Button("終了する") { viewModel.completeJobHunting() }
    } message: { Text("端末内の設定を更新し、お祝いを表示します。学校への通知は行いません。") }
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
      if school.credentialsRejected {
        showLogin = true
      }
      startupDone = true
      safety.cancel()
    }
  }
}

/// 起動直後（ログインの確認と最初のデータ取得の間）に出す全画面ローディング。操作は受け付けない。
struct StartupLoadingView: View {
  var body: some View {
    ZStack {
      AppBackgroundView()
      VStack(spacing: AppTheme.Space.lg) {
        Image(systemName: "graduationcap.fill")
          .font(.system(size: 44, weight: .medium))
          .foregroundStyle(AppTheme.primaryAction)
        ProgressView()
          .controlSize(.large)
        Text("読み込み中…")
          .font(.subheadline)
          .foregroundStyle(AppTheme.textSecondary)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("読み込み中")
  }
}

#Preview { ContentView() }
