import BackgroundTasks
import SwiftUI
@preconcurrency import UserNotifications

extension Notification.Name {
  static let org2OpenMobileSidebar = Notification.Name("org2.openMobileSidebar")
  static let org2NotificationDestinationPending = Notification.Name("org2.notificationDestinationPending")
  static let org2OpenRemoteThread = Notification.Name("org2.openRemoteThread")
  static let org2RemotePushTokenUpdated = Notification.Name("org2.remotePushTokenUpdated")
  static let org2RemotePushRegistrationFailed = Notification.Name("org2.remotePushRegistrationFailed")
}

final class Org2MobileAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  static let replyRefreshTaskIdentifier = "org.org2.mobile.thread-refresh"

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    BGTaskScheduler.shared.register(
      forTaskWithIdentifier: Self.replyRefreshTaskIdentifier,
      using: nil
    ) { task in
      guard let refreshTask = task as? BGAppRefreshTask else {
        task.setTaskCompleted(success: false)
        return
      }
      Self.scheduleReplyRefresh()
      let operation = Task { @MainActor in
        let store = MobileRemoteStore()
        let succeeded = await store.refreshReplyNotificationsInBackground()
        refreshTask.setTaskCompleted(success: succeeded)
      }
      refreshTask.expirationHandler = {
        operation.cancel()
      }
    }
    return true
  }

  func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    let environment: String
    #if DEBUG
    environment = "sandbox"
    #else
    environment = "production"
    #endif
    UserDefaults.standard.set(token, forKey: MobileRemoteNotification.deviceTokenKey)
    UserDefaults.standard.set(environment, forKey: MobileRemoteNotification.pushEnvironmentKey)
    NotificationCenter.default.post(
      name: .org2RemotePushTokenUpdated,
      object: nil,
      userInfo: ["deviceToken": token, "environment": environment]
    )
  }

  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NotificationCenter.default.post(
      name: .org2RemotePushRegistrationFailed,
      object: nil,
      userInfo: ["error": error.localizedDescription]
    )
  }

  func applicationDidEnterBackground(_ application: UIApplication) {
    Self.scheduleReplyRefresh()
  }

  static func scheduleReplyRefresh() {
    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: replyRefreshTaskIdentifier)
    let request = BGAppRefreshTaskRequest(identifier: replyRefreshTaskIdentifier)
    request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
    try? BGTaskScheduler.shared.submit(request)
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    guard notification.request.content.categoryIdentifier == MobileRemoteNotification.replyCategory else {
      completionHandler([])
      return
    }
    Self.recordDeliveredReply(notification.request.content.userInfo)
    completionHandler([.banner, .list])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping @Sendable () -> Void
  ) {
    // Dismissal is not a request to navigate.
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
      completionHandler()
      return
    }
    let content = response.notification.request.content
    guard let destination = MobileNotificationDestination.resolve(
      category: content.categoryIdentifier,
      identifier: response.notification.request.identifier,
      userInfo: content.userInfo
    ) else {
      completionHandler()
      return
    }
    if content.categoryIdentifier == MobileRemoteNotification.replyCategory {
      Self.recordDeliveredReply(content.userInfo)
    }
    DispatchQueue.main.async {
      MobileNotificationInbox(defaults: .standard).enqueue(destination)
      NotificationCenter.default.post(name: .org2NotificationDestinationPending, object: nil)
      completionHandler()
    }
  }

  private nonisolated static func recordDeliveredReply(_ userInfo: [AnyHashable: Any]) {
    guard let reply = MobileReplyNotificationLedger.Reply(userInfo: userInfo) else { return }
    MobileReplyNotificationLedger(defaults: .standard).record([reply])
  }
}

@main
struct Org2MobileApp: App {
  @UIApplicationDelegateAdaptor(Org2MobileAppDelegate.self) private var appDelegate
  @StateObject private var store = CorpusStore()
  @StateObject private var mobileRemote: MobileRemoteStore
  @StateObject private var audioApprovals: AudioApprovalController

  init() {
    // A Push to Talk notification may launch Celorga directly into the background, where a
    // SwiftUI view task is not guaranteed to run. Build and attach the channel manager as part
    // of app initialization so iOS can restore the joined channel before delivering the push.
    let mobileRemote = MobileRemoteStore()
    let audioApprovals = AudioApprovalController()
    audioApprovals.attach(remote: mobileRemote)
    _mobileRemote = StateObject(wrappedValue: mobileRemote)
    _audioApprovals = StateObject(wrappedValue: audioApprovals)
  }

  var body: some Scene {
    WindowGroup {
      StartupHostView()
        .environmentObject(store)
        .environmentObject(mobileRemote)
        .environmentObject(audioApprovals)
    }
  }
}

private struct StartupHostView: View {
  @EnvironmentObject private var store: CorpusStore
  @EnvironmentObject private var mobileRemote: MobileRemoteStore
  @Environment(\.scenePhase) private var scenePhase
  @State private var isReady = false
  @State private var hasStartedRestore = false

  var body: some View {
    Group {
      if isReady {
        ContentView()
      } else {
        StartupShellView()
      }
    }
    .onAppear {
      guard !hasStartedRestore else { return }
      hasStartedRestore = true

      DispatchQueue.main.async {
        store.startRestoringCorpus()
        mobileRemote.setAppActive(scenePhase == .active)
        isReady = true
      }
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active {
        store.clearNotificationBadge()
      }
      mobileRemote.setAppActive(phase == .active)
    }
  }
}

private struct StartupShellView: View {
  var body: some View {
    ZStack {
      Color(.systemGroupedBackground)
        .ignoresSafeArea()
      Text("Celorga")
        .font(.largeTitle.weight(.semibold))
        .foregroundStyle(.primary)
    }
  }
}
