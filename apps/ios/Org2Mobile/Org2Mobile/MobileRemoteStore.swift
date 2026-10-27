@preconcurrency import Foundation
import Security
import UIKit
@preconcurrency import UserNotifications

@MainActor
final class MobileRemoteStore: ObservableObject {
  @Published private(set) var savedHosts: [MobileRemoteSavedHost] = []
  @Published private(set) var activeHostID: UUID?
  @Published private(set) var activeRequestCount = 0
  private var activeEndpoint = ""
  private static let savedHostsKey = "Org2Mobile.remote.hosts.v1"
  private static let activeHostKey = "Org2Mobile.remote.activeHost.v1"

  var canChangeHost: Bool { !isPairing }

  @Published private(set) var isPaired = false
  @Published private(set) var isConnected = false
  @Published private(set) var connectionError: String?
  @Published private(set) var serverName = "Celorga on Mac"
  @Published private(set) var status: MobileRemoteServerStatus?
  @Published private(set) var threads: [MobileRemoteThreadSummary] = []
  @Published private(set) var projects: [MobileRemoteProjectSummary] = []
  @Published private(set) var threadDetail: MobileRemoteThreadDetail?
  @Published private(set) var threadConfiguration: MobileRemoteThreadConfiguration?
  @Published private(set) var threadConnectionError: String?
  @Published private(set) var configurationError: String?
  @Published private(set) var isRefreshing = false
  @Published private(set) var isPairing = false
  @Published private(set) var isRefreshingConfiguration = false
  @Published private(set) var isUpdatingConfiguration = false
  @Published private(set) var mutatingThreadIDs: Set<UUID> = []
  @Published private(set) var loadingThreadID: UUID?
  @Published private(set) var externalThreads: [MobileExternalThreadSummary] = []
  @Published private(set) var externalThreadDetail: MobileExternalThreadDetail?
  @Published private(set) var isRefreshingExternalThreads = false
  @Published private(set) var isLoadingExternalThread = false
  @Published private(set) var workspaceAgenda: [AgendaEntry] = []
  @Published private(set) var workspaceApprovals: [ApprovalEntry] = []
  @Published private(set) var workspaceSnoozedApprovals: [ApprovalEntry] = []
  @Published private(set) var approvalHistory: [MobileRemoteApprovalHistoryItem] = []
  @Published private(set) var workspaceWorkflows: [MobileRemoteWorkflowItem] = []
  @Published private(set) var workspaceUpdatedAt: Date?
  @Published private(set) var workspaceConnectionError: String?
  @Published private(set) var isRefreshingWorkspace = false
  @Published private(set) var mutatingWorkspaceItemIDs: Set<String> = []
  @Published private(set) var threadNotificationsEnabled: Bool
  @Published private(set) var threadNotificationsUnavailable = false
  @Published private(set) var realTimeNotificationsActive = false
  @Published private(set) var pushNotificationStatusText = "Waiting for Apple Push Notifications"
  @Published var endpointDraft = ""
  @Published var codeDraft = ""
  @Published var errorMessage: String?

  private static let endpointKey = "Org2Mobile.remote.endpoint.v1"
  private static let serverNameKey = "Org2Mobile.remote.serverName.v1"
  private static let deviceIDKey = "Org2Mobile.remote.deviceID.v1"
  private static let threadNotificationsEnabledKey = "Org2Mobile.remote.threadNotificationsEnabled.v1"
  private static let tokenService = "org.org2.mobile.remote"
  private static let tokenAccount = "mac-access-token"

  private let defaults: UserDefaults
  private var accessToken: String?
  private var pushRegistrationFingerprint: String?
  private var isSyncingPushRegistration = false
  private var notificationObservers: [NSObjectProtocol] = []
  private var pollingTask: Task<Void, Never>?
  private var foregroundReplyPollingTask: Task<Void, Never>?
  private var appIsActive = false
  private var connectionGeneration = 0
  private var workspaceRefreshTask: Task<Void, Never>?
  private var workspaceRefreshID: UUID?
  private var pollingThreadID: UUID?
  private var pollingLeaseID: UUID?
  private var configurationRequestID: UUID?
  private var threadDetailCache: [UUID: MobileRemoteThreadDetail] = [:]
  /// Chats opened optimistically while the host is still creating them.
  /// Thread requests for these IDs wait for creation before hitting the host.
  private var pendingThreadCreations: [UUID: Task<Bool, Never>] = [:]
  private var threadDetailCacheOrder: [UUID] = []
  private static let threadDetailCacheLimit = 6
  private var externalThreadLoadRequestID: UUID?
  private var externalThreadDetailCache: [String: MobileExternalThreadDetail] = [:]
  private var externalThreadDetailCacheOrder: [String] = []
  private static let externalThreadDetailCacheLimit = 6

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    threadNotificationsEnabled = defaults.object(forKey: Self.threadNotificationsEnabledKey) as? Bool ?? true
    endpointDraft = defaults.string(forKey: Self.endpointKey) ?? ""
    let storedServerName = defaults.string(forKey: Self.serverNameKey)
    serverName = storedServerName == "Org2 on Mac" || storedServerName == "OpenOrg on Mac"
      ? "Celorga on Mac"
      : storedServerName ?? "Celorga on Mac"
    accessToken = Self.loadToken()
    savedHosts = defaults.data(forKey: Self.savedHostsKey).flatMap {
      try? JSONDecoder().decode([MobileRemoteSavedHost].self, from: $0)
    } ?? []
    activeHostID = defaults.string(forKey: Self.activeHostKey).flatMap(UUID.init(uuidString:))
    if let host = savedHosts.first(where: { $0.id == activeHostID }) {
      activeEndpoint = host.endpoint
      endpointDraft = host.endpoint
      serverName = host.name
      accessToken = Self.loadToken(account: host.id.uuidString)
    } else if !endpointDraft.isEmpty, let token = accessToken {
      let id = UUID()
      if (try? Self.saveToken(token, account: id.uuidString)) != nil {
        let host = MobileRemoteSavedHost(id: id, name: serverName, endpoint: endpointDraft)
        savedHosts.append(host)
        activeHostID = id
        activeEndpoint = host.endpoint
        defaults.set(try? JSONEncoder().encode(savedHosts), forKey: Self.savedHostsKey)
        defaults.set(id.uuidString, forKey: Self.activeHostKey)
        Self.deleteToken()
      }
    }
    isPaired = !activeEndpoint.isEmpty && accessToken != nil
    notificationObservers = [
      NotificationCenter.default.addObserver(
        forName: .org2RemotePushTokenUpdated,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.pushNotificationStatusText = "Connecting real-time notifications"
          await self?.syncPushRegistrationIfNeeded(force: true)
        }
      },
      NotificationCenter.default.addObserver(
        forName: .org2RemotePushRegistrationFailed,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        let detail = notification.userInfo?["error"] as? String
        Task { @MainActor [weak self] in
          self?.realTimeNotificationsActive = false
          self?.pushNotificationStatusText = detail.map { "Push registration failed: \($0)" }
            ?? "Push registration failed"
        }
      }
    ]
  }

  deinit {
    pollingTask?.cancel()
    foregroundReplyPollingTask?.cancel()
    notificationObservers.forEach(NotificationCenter.default.removeObserver)
  }

  func applyPairingPayload(_ payload: String) -> Bool {
    guard let components = URLComponents(string: payload),
          components.scheme == "org2-remote",
          components.host == "pair",
          let endpoint = components.queryItems?.first(where: { $0.name == "endpoint" })?.value,
          let code = components.queryItems?.first(where: { $0.name == "code" })?.value
    else {
      errorMessage = "That QR code is not a Celorga pairing code."
      return false
    }
    endpointDraft = endpoint
    codeDraft = code
    if let name = components.queryItems?.first(where: { $0.name == "name" })?.value {
      if !isPaired { serverName = name }
    }
    return true
  }

  func pair() async {
    guard canChangeHost else {
      errorMessage = "Finish pairing before changing hosts."
      return
    }
    isPairing = true
    activeRequestCount += 1
    defer { isPairing = false; activeRequestCount -= 1 }
    do {
      let client = try MobileRemoteClient(endpoint: endpointDraft, accessToken: nil)
      let response: MobileRemotePairResponse = try await client.post(
        "/v1/pair",
        payload: MobileRemotePairRequest(
          code: codeDraft.trimmingCharacters(in: .whitespacesAndNewlines),
          deviceName: UIDevice.current.name
        ),
        as: MobileRemotePairResponse.self
      )
      guard response.protocolVersion == MobileRemoteWire.version else {
        throw MobileRemoteClientError.incompatibleProtocol
      }
      let endpoint = client.endpoint.absoluteString
      let host = MobileRemoteSavedHost(id: response.deviceID, name: response.serverName, endpoint: endpoint)
      try Self.saveToken(response.accessToken, account: host.id.uuidString)
      disconnect(forgetHost: false, checksRequests: false, unregisterPush: false)
      savedHosts.removeAll { existing in
        if existing.endpoint == endpoint { Self.deleteToken(account: existing.id.uuidString); return true }
        return false
      }
      savedHosts.append(host)
      activeHostID = host.id
      activeEndpoint = endpoint
      endpointDraft = endpoint
      persistHosts()
      accessToken = response.accessToken
      serverName = response.serverName
      codeDraft = ""
      defaults.set(endpointDraft, forKey: Self.endpointKey)
      defaults.set(serverName, forKey: Self.serverNameKey)
      defaults.set(response.deviceID.uuidString, forKey: Self.deviceIDKey)
      isPaired = true
      isPairing = false
      await prepareThreadNotifications()
      await refresh()
      await syncPushRegistrationIfNeeded(force: true)
      setAppActive(appIsActive)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func selectHost(_ host: MobileRemoteSavedHost) {
    guard canChangeHost, host.id != activeHostID else { return }
    guard let token = Self.loadToken(account: host.id.uuidString) else {
      errorMessage = "Pair with this host again to restore its credential."
      return
    }
    disconnect(forgetHost: false, checksRequests: false, unregisterPush: false)
    activeHostID = host.id
    activeEndpoint = host.endpoint
    endpointDraft = host.endpoint
    serverName = host.name
    accessToken = token
    isPaired = true
    persistHosts()
    defaults.set(host.endpoint, forKey: Self.endpointKey)
    defaults.set(host.name, forKey: Self.serverNameKey)
    setAppActive(appIsActive)
    Task { await refresh(); await refreshWorkspace(reportsErrors: false) }
  }

  private func persistHosts() {
    defaults.set(try? JSONEncoder().encode(savedHosts), forKey: Self.savedHostsKey)
    defaults.set(activeHostID?.uuidString, forKey: Self.activeHostKey)
  }

  private func invalidateConnectionRequests() {
    workspaceRefreshTask?.cancel()
    workspaceRefreshTask = nil
    workspaceRefreshID = nil
    connectionGeneration &+= 1
    isRefreshing = false
    isRefreshingWorkspace = false
    isSyncingPushRegistration = false
    isRefreshingConfiguration = false
    isUpdatingConfiguration = false
    isRefreshingExternalThreads = false
    isLoadingExternalThread = false
  }

  private func isCurrentConnection(_ generation: Int) -> Bool {
    connectionGeneration == generation
  }

  func disconnect(
    forgetHost: Bool = true,
    checksRequests: Bool = true,
    unregisterPush: Bool = true
  ) {
    guard !checksRequests || canChangeHost else {
      errorMessage = "Finish pairing before disconnecting."
      return
    }
    invalidateConnectionRequests()
    if unregisterPush, isPaired, let accessToken,
       let client = try? MobileRemoteClient(endpoint: activeEndpoint, accessToken: accessToken) {
      activeRequestCount += 1
      Task {
        defer { activeRequestCount -= 1 }
        _ = try? await client.post(
          "/v1/push-registration",
          payload: MobileRemotePushRegistrationRequest(
            deviceToken: nil,
            environment: nil,
            enabled: false
          ),
          as: MobileRemotePushRegistrationResponse.self
        )
      }
    }
    pollingTask?.cancel()
    pollingTask = nil
    pollingThreadID = nil
    pollingLeaseID = nil
    foregroundReplyPollingTask?.cancel()
    foregroundReplyPollingTask = nil
    if forgetHost, let activeHostID {
      Self.deleteToken(account: activeHostID.uuidString)
      savedHosts.removeAll { $0.id == activeHostID }
    }
    activeHostID = nil
    activeEndpoint = ""
    persistHosts()
    accessToken = nil
    isPaired = false
    isConnected = false
    connectionError = nil
    realTimeNotificationsActive = false
    pushNotificationStatusText = "Pair with a host for real-time notifications"
    pushRegistrationFingerprint = nil
    status = nil
    threads = []
    projects = []
    threadDetail = nil
    loadingThreadID = nil
    threadDetailCache.removeAll()
    threadDetailCacheOrder.removeAll()
    threadConfiguration = nil
    externalThreads = []
    externalThreadDetail = nil
    externalThreadLoadRequestID = nil
    externalThreadDetailCache.removeAll()
    externalThreadDetailCacheOrder.removeAll()
    workspaceAgenda = []
    workspaceApprovals = []
    workspaceSnoozedApprovals = []
    approvalHistory = []
    workspaceWorkflows = []
    workspaceUpdatedAt = nil
    workspaceConnectionError = nil
    isRefreshingWorkspace = false
    mutatingWorkspaceItemIDs = []
    threadConnectionError = nil
    configurationError = nil
    defaults.removeObject(forKey: Self.endpointKey)
    defaults.removeObject(forKey: Self.serverNameKey)
    defaults.removeObject(forKey: Self.deviceIDKey)
    replyNotificationLedger.reset()
    defaults.removeObject(forKey: MobileRemoteNotification.pendingReplyThreadIDKey)
  }

  func refresh(reportsErrors: Bool = true) async {
    let generation = connectionGeneration
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    guard isPaired, !isRefreshing else { return }
    isRefreshing = true
    defer {
      if isCurrentConnection(generation) {
        isRefreshing = false
      }
    }
    do {
      let client = try pairedClient()
      async let statusRequest = client.get("/v1/status", as: MobileRemoteServerStatus.self)
      async let threadsRequest = client.get("/v1/threads", timeout: 30, as: MobileRemoteThreadList.self)
      let (nextStatus, nextThreads) = try await (statusRequest, threadsRequest)
      guard nextStatus.protocolVersion == MobileRemoteWire.version else {
        throw MobileRemoteClientError.incompatibleProtocol
      }
      guard isCurrentConnection(generation) else { return }
      status = nextStatus
      isConnected = true
      connectionError = nil
      serverName = nextStatus.serverName
      await syncPushRegistrationIfNeeded(force: false, connectionGeneration: generation)
      await reconcileReplyNotifications(with: nextThreads.threads, connectionGeneration: generation)
      guard isCurrentConnection(generation) else { return }
      let hostThreadIDs = Set(nextThreads.threads.map(\.id))
      let pendingThreads = threads.filter {
        pendingThreadCreations[$0.id] != nil && !hostThreadIDs.contains($0.id)
      }
      threads = pendingThreads + nextThreads.threads
      projects = nextThreads.projects ?? []
      pruneThreadDetailCache(
        keeping: Set(nextThreads.threads.map(\.id)).union(pendingThreadCreations.keys)
      )
      defaults.set(serverName, forKey: Self.serverNameKey)
    } catch {
      guard isCurrentConnection(generation) else { return }
      isConnected = false
      connectionError = error.localizedDescription
      if reportsErrors {
        errorMessage = error.localizedDescription
      }
    }
  }

  /// Ordinary callers share the current read. A push supersedes an older request: its
  /// snapshot may predate the approval, and its timeout must not consume the PTT audio window.
  func refreshWorkspace(reportsErrors: Bool = true, requiresNewSnapshot: Bool = false) async {
    let generation = connectionGeneration
    if requiresNewSnapshot {
      workspaceRefreshTask?.cancel()
      workspaceRefreshTask = nil
      workspaceRefreshID = nil
    } else if let inFlight = workspaceRefreshTask {
      await inFlight.value
      return
    }
    guard isPaired, !Task.isCancelled else { return }
    let requestID = UUID()
    workspaceRefreshID = requestID
    let task = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.workspaceRefreshID == requestID {
          self.workspaceRefreshTask = nil
          self.workspaceRefreshID = nil
        }
      }
      await self.loadWorkspace(reportsErrors: reportsErrors, generation: generation, requestID: requestID)
    }
    workspaceRefreshTask = task
    await task.value
  }

  private func loadWorkspace(reportsErrors: Bool, generation: Int, requestID: UUID) async {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    isRefreshingWorkspace = true
    defer {
      if isCurrentConnection(generation), workspaceRefreshID == requestID { isRefreshingWorkspace = false }
    }
    do {
      let snapshot = try await pairedClient().get(
        "/v1/workspace",
        timeout: 60,
        as: MobileRemoteWorkspaceSnapshot.self
      )
      guard !Task.isCancelled, isCurrentConnection(generation), workspaceRefreshID == requestID else { return }
      apply(snapshot)
      workspaceConnectionError = nil
      isConnected = true
    } catch {
      guard !Task.isCancelled, isCurrentConnection(generation), workspaceRefreshID == requestID else { return }
      workspaceConnectionError = error.localizedDescription
      if reportsErrors, workspaceUpdatedAt == nil {
        errorMessage = "Could not load canonical workspace data from the host. \(error.localizedDescription)"
      }
    }
  }

  func setAgendaStatus(_ status: OrgTodoStatus, for entry: AgendaEntry) async {
    let canonicalStatus: String
    switch status {
    case .done:
      canonicalStatus = "done"
    case .canceled, .cancelled:
      canonicalStatus = "canceled"
    case .inProgress, .prog, .started, .doing:
      canonicalStatus = "in_progress"
    default:
      canonicalStatus = "todo"
    }
    await mutateWorkspaceItem(entry.id) {
      try await self.pairedClient().post(
        self.workspacePath(collection: "agenda", id: entry.id, action: "status"),
        payload: MobileRemoteAgendaStatusRequest(status: canonicalStatus),
        timeout: 60,
        as: MobileRemoteWorkspaceSnapshot.self
      )
    }
  }

  func decideApproval(
    _ approval: ApprovalEntry,
    decision: String,
    note: String? = nil,
    endStatus: OrgTodoStatus? = nil
  ) async {
    let canonicalEndStatus: String?
    switch endStatus {
    case .done?: canonicalEndStatus = "done"
    case .canceled?, .cancelled?: canonicalEndStatus = "canceled"
    default: canonicalEndStatus = nil
    }
    await mutateWorkspaceItem(approval.id) {
      try await self.pairedClient().post(
        self.workspacePath(collection: "approvals", id: approval.id, action: "decision"),
        payload: MobileRemoteApprovalDecisionRequest(
          decision: decision,
          note: note,
          endStatus: canonicalEndStatus
        ),
        timeout: 90,
        as: MobileRemoteWorkspaceSnapshot.self
      )
    }
  }

  /// Snoozes (`until` set) or wakes (`until == nil`) an approval on the paired Mac. It stays
  /// pending and returns to the queue on its own when the snooze ends.
  func snoozeApproval(_ approval: ApprovalEntry, until: Date?) async {
    await mutateWorkspaceItem(approval.id) {
      try await self.pairedClient().post(
        self.workspacePath(collection: "approvals", id: approval.id, action: "snooze"),
        payload: MobileRemoteApprovalSnoozeRequest(
          until: until,
          runID: approval.runID,
          approvalID: approval.approvalID,
          fingerprint: approval.fingerprint
        ),
        timeout: 60,
        as: MobileRemoteWorkspaceSnapshot.self
      )
    }
  }

  /// Exact-identity decision used by audio approvals. Unlike `decideApproval`, it does not swallow
  /// errors: the caller needs to know whether the host applied the decision.
  func decideApprovalExactly(
    _ approval: ApprovalEntry,
    decision: String,
    note: String?,
    receipt: String
  ) async throws -> MobileRemoteWorkspaceSnapshot {
    guard let runID = approval.runID, let approvalID = approval.approvalID, let fingerprint = approval.fingerprint else {
      throw AudioApprovalError.approvalIdentityMissing
    }
    let snapshot = try await pairedClient().post(
      workspacePath(collection: "approvals", id: approval.id, action: "decision"),
      payload: MobileRemoteApprovalDecisionRequest(
        decision: decision,
        note: note,
        endStatus: nil,
        runID: runID,
        approvalID: approvalID,
        fingerprint: fingerprint,
        receipt: receipt
      ),
      timeout: 90,
      as: MobileRemoteWorkspaceSnapshot.self
    )
    apply(snapshot)
    isConnected = true
    return snapshot
  }

  func reportAudioApprovalDelivery(_ event: MobileRemoteAudioApprovalDeliveryRecord) async throws {
    let _: [String: Bool] = try await pairedClient().post(
      "/v1/audio-approvals/delivery", payload: event, timeout: 8, as: [String: Bool].self)
  }

  func audioApprovalDeliveryDiagnostics() async throws -> [MobileRemoteAudioApprovalDeliveryRecord] {
    try await pairedClient().get("/v1/audio-approvals/diagnostics", as: [MobileRemoteAudioApprovalDeliveryRecord].self)
  }

  /// Registers the framework-issued ephemeral Push to Talk token with the paired Mac.
  /// The token deliberately remains in memory only on iOS and is valid only while joined.
  func setAudioApprovalPushRegistration(
    token: Data?,
    enabled: Bool,
    quietUntil: Date?
  ) async throws -> MobileRemotePushToTalkRegistrationResponse {
    let environment: String
    #if DEBUG
    environment = "sandbox"
    #else
    environment = "production"
    #endif
    let tokenHex = token?.map { String(format: "%02x", $0) }.joined()
    do {
      return try await pairedClient().post(
        "/v1/push-to-talk-registration",
        payload: MobileRemotePushToTalkRegistrationRequest(
          pushToken: enabled ? tokenHex : nil,
          environment: enabled ? environment : nil,
          enabled: enabled,
          quietUntil: enabled ? quietUntil : nil
        ),
        as: MobileRemotePushToTalkRegistrationResponse.self
      )
    } catch MobileRemoteClientError.server(let message) where message == Self.legacyUnknownRouteError {
      // Hosts built before audio approvals route unknown paths to the thread
      // lookup and answer "Thread not found." Name the real problem instead.
      throw MobileRemoteClientError.server(Self.audioApprovalsUnsupportedMessage(hostName: serverName))
    }
  }

  /// What a Celorga host built before audio approvals answers for an unknown route.
  static let legacyUnknownRouteError = "Thread not found."

  static func audioApprovalsUnsupportedMessage(hostName: String) -> String {
    "\(hostName) runs a Celorga build without audio approvals. Update Celorga on that Mac, or switch to a host that has them under Mac Connection."
  }

  /// "Later" for one exact prompt. The Mac moves on to the next pending approval.
  func snoozeAudioApproval(_ target: AudioApprovalTarget, until: Date) async throws -> Date {
    try await pairedClient().post(
      "/v1/audio-approvals/snooze",
      payload: MobileRemoteAudioApprovalSnoozeRequest(
        runID: target.runID,
        approvalID: target.approvalID,
        fingerprint: target.fingerprint,
        until: until
      ),
      as: MobileRemoteAudioApprovalSnoozeResponse.self
    ).snoozedUntil
  }

  var isPairedForAudioApprovals: Bool {
    accessToken != nil && !isPairing
  }

  func setWorkflowState(_ state: String, for workflow: MobileRemoteWorkflowItem) async {
    await mutateWorkspaceItem(workflow.id) {
      try await self.pairedClient().post(
        self.workspacePath(collection: "workflows", id: workflow.id, action: "state"),
        payload: MobileRemoteWorkflowStateRequest(state: state),
        timeout: 60,
        as: MobileRemoteWorkspaceSnapshot.self
      )
    }
  }

  func runWorkflow(_ workflow: MobileRemoteWorkflowItem, inputs: [String: String]) async -> UUID? {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    guard !mutatingWorkspaceItemIDs.contains(workflow.id) else { return nil }
    mutatingWorkspaceItemIDs.insert(workflow.id)
    defer { mutatingWorkspaceItemIDs.remove(workflow.id) }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        workspacePath(collection: "workflows", id: workflow.id, action: "run"),
        payload: MobileRemoteWorkflowRunRequest(inputs: inputs),
        timeout: 60,
        as: MobileRemoteMutationResponse.self
      )
      await refresh()
      return response.threadID
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func mutateWorkspaceItem(
    _ id: String,
    operation: () async throws -> MobileRemoteWorkspaceSnapshot
  ) async {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    guard !mutatingWorkspaceItemIDs.contains(id) else { return }
    mutatingWorkspaceItemIDs.insert(id)
    defer { mutatingWorkspaceItemIDs.remove(id) }
    do {
      apply(try await operation())
      workspaceConnectionError = nil
      isConnected = true
    } catch {
      errorMessage = error.localizedDescription
      await refreshWorkspace(reportsErrors: false)
    }
  }

  private func apply(_ snapshot: MobileRemoteWorkspaceSnapshot) {
    workspaceAgenda = snapshot.agenda.map(\.localEntry)
    workspaceApprovals = snapshot.approvals.map(\.localEntry)
    workspaceSnoozedApprovals = (snapshot.snoozedApprovals ?? []).map(\.localEntry)
    approvalHistory = snapshot.approvalHistory ?? []
    workspaceWorkflows = snapshot.workflows
    workspaceUpdatedAt = snapshot.updatedAt
  }

  private func workspacePath(collection: String, id: String, action: String) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/?#%")
    let encodedID = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    return "/v1/workspace/\(collection)/\(encodedID)/\(action)"
  }

  func setAppActive(_ isActive: Bool) {
    appIsActive = isActive
    foregroundReplyPollingTask?.cancel()
    foregroundReplyPollingTask = nil
    if isActive, isPaired, let pollingThreadID {
      Task { [weak self] in
        await self?.refreshThreadConfiguration(pollingThreadID)
      }
    }
    guard isActive, isPaired else { return }
    foregroundReplyPollingTask = Task { [weak self] in
      guard let self else { return }
      if self.threadNotificationsEnabled {
        await self.prepareThreadNotifications()
      }
      while !Task.isCancelled {
        await self.refresh(reportsErrors: false)
        try? await Task.sleep(for: .seconds(4))
      }
    }
  }

  func setThreadNotificationsEnabled(_ enabled: Bool) {
    guard threadNotificationsEnabled != enabled else { return }
    threadNotificationsEnabled = enabled
    defaults.set(enabled, forKey: Self.threadNotificationsEnabledKey)
    if !enabled {
      realTimeNotificationsActive = false
      pushNotificationStatusText = "Reply notifications are off"
      pushRegistrationFingerprint = nil
      Task { await syncPushRegistrationIfNeeded(force: true, enabled: false) }
    }
    if enabled, appIsActive {
      // Establish a fresh baseline before alerting so enabling the option does
      // not replay replies that arrived while notifications were disabled.
      replyNotificationLedger.reset()
      pushNotificationStatusText = "Connecting real-time notifications"
      setAppActive(true)
    } else {
      threadNotificationsUnavailable = false
      if appIsActive {
        // Thread-list freshness is independent of whether the user wants
        // notification banners.
        setAppActive(true)
      }
    }
  }

  func refreshReplyNotificationsInBackground() async -> Bool {
    guard isPaired, threadNotificationsEnabled else { return true }
    await refresh(reportsErrors: false)
    return isConnected
  }

  private func prepareThreadNotifications() async {
    #if DEBUG
    if CelorgaNames.environment("ORG2_DEBUG_SUPPRESS_NOTIFICATIONS") == "1" {
      return
    }
    #endif
    guard threadNotificationsEnabled else { return }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if settings.authorizationStatus == .notDetermined {
      _ = try? await center.requestAuthorization(options: [.alert])
    }
    let refreshedSettings = await center.notificationSettings()
    threadNotificationsUnavailable = !Self.notificationAuthorizationAllowsAlerts(
      refreshedSettings.authorizationStatus
    )
    if !threadNotificationsUnavailable {
      UIApplication.shared.registerForRemoteNotifications()
      await syncPushRegistrationIfNeeded(force: false)
    } else {
      realTimeNotificationsActive = false
      pushNotificationStatusText = "Notifications are disabled in iOS Settings"
    }
  }

  private func syncPushRegistrationIfNeeded(
    force: Bool,
    enabled requestedEnabled: Bool? = nil,
    connectionGeneration expectedGeneration: Int? = nil
  ) async {
    let generation = expectedGeneration ?? connectionGeneration
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    guard isPaired, !isSyncingPushRegistration else { return }
    guard isCurrentConnection(generation) else { return }
    let enabled = requestedEnabled ?? threadNotificationsEnabled
    let token = enabled
      ? defaults.string(forKey: MobileRemoteNotification.deviceTokenKey)
      : nil
    let environment = enabled
      ? defaults.string(forKey: MobileRemoteNotification.pushEnvironmentKey)
      : nil
    if enabled, token == nil {
      realTimeNotificationsActive = false
      pushNotificationStatusText = "Waiting for Apple Push Notifications"
      return
    }
    if enabled, status?.pushNotificationsSupported == false {
      realTimeNotificationsActive = false
      pushNotificationStatusText = "Update Celorga on the Mac to enable real-time notifications"
      return
    }
    let fingerprint = "\(enabled):\(environment ?? "none"):\(token ?? "none")"
    guard force || fingerprint != pushRegistrationFingerprint else { return }
    isSyncingPushRegistration = true
    defer {
      if isCurrentConnection(generation) {
        isSyncingPushRegistration = false
      }
    }
    do {
      let response: MobileRemotePushRegistrationResponse = try await pairedClient().post(
        "/v1/push-registration",
        payload: MobileRemotePushRegistrationRequest(
          deviceToken: token,
          environment: environment,
          enabled: enabled
        ),
        as: MobileRemotePushRegistrationResponse.self
      )
      guard isCurrentConnection(generation) else { return }
      pushRegistrationFingerprint = fingerprint
      realTimeNotificationsActive = response.enabled && response.providerConfigured
      if !enabled {
        pushNotificationStatusText = "Reply notifications are off"
      } else if response.providerConfigured {
        pushNotificationStatusText = "Real-time notifications are active"
      } else {
        pushNotificationStatusText = "Finish push setup in Celorga on the Mac"
      }
    } catch {
      guard isCurrentConnection(generation) else { return }
      realTimeNotificationsActive = false
      if status?.pushNotificationsSupported == true {
        pushNotificationStatusText = "Could not sync push notifications: \(error.localizedDescription)"
      } else {
        pushNotificationStatusText = "Update Celorga on the Mac to enable real-time notifications"
      }
    }
  }

  private var replyNotificationLedger: MobileReplyNotificationLedger {
    MobileReplyNotificationLedger(defaults: defaults)
  }

  /// Replies already on screen in an open thread never need an alert.
  private func recordReplyNotificationBaseline(for detail: MobileRemoteThreadDetail) {
    let threadID = detail.thread.id
    var replies = detail.messages
      .filter { $0.role == "assistant" }
      .suffix(MobileReplyNotificationLedger.recentRepliesPerThread)
      .map { MobileReplyNotificationLedger.Reply(threadID: threadID, messageID: $0.id) }
    if let latest = detail.thread.latestAssistantMessageID {
      replies.append(MobileReplyNotificationLedger.Reply(threadID: threadID, messageID: latest))
    }
    replyNotificationLedger.record(replies)
  }

  private func reconcileReplyNotifications(
    with nextThreads: [MobileRemoteThreadSummary],
    connectionGeneration expectedGeneration: Int? = nil
  ) async {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    if let expectedGeneration, !isCurrentConnection(expectedGeneration) { return }
    // A summary without a latest reply (an evicted transcript on the Mac) is
    // skipped, never forgotten, so its old reply cannot alert again later.
    let latestReplies = nextThreads.compactMap { thread in
      thread.latestAssistantMessageID.map {
        MobileReplyNotificationLedger.Reply(threadID: thread.id, messageID: $0)
      }
    }
    let unseen = Set(replyNotificationLedger.reconcile(latestReplies: latestReplies))
    guard !unseen.isEmpty, threadNotificationsEnabled else { return }
    // The Mac already pushes every new reply through APNs. A push that iOS
    // shows while the app is suspended never reaches this process, so a
    // polled copy would duplicate it.
    guard !realTimeNotificationsActive else { return }

    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if let expectedGeneration, !isCurrentConnection(expectedGeneration) { return }
    guard Self.notificationAuthorizationAllowsAlerts(settings.authorizationStatus) else {
      threadNotificationsUnavailable = true
      return
    }
    threadNotificationsUnavailable = false
    let alreadyShown = Set(await center.deliveredNotifications().compactMap { notification in
      MobileReplyNotificationLedger.Reply(userInfo: notification.request.content.userInfo)
    })
    if let expectedGeneration, !isCurrentConnection(expectedGeneration) { return }
    let candidates = nextThreads.filter { thread in
      guard pollingThreadID != thread.id,
            let messageID = thread.latestAssistantMessageID
      else { return false }
      let reply = MobileReplyNotificationLedger.Reply(threadID: thread.id, messageID: messageID)
      return unseen.contains(reply) && !alreadyShown.contains(reply)
    }
    // A 4-second poll rarely sees more than one new reply. A larger batch
    // means the baseline was lost, so announce only the newest few rather
    // than flooding the phone with old replies; the rest stay recorded.
    let announced = candidates
      .sorted { $0.updatedAt > $1.updatedAt }
      .prefix(MobileReplyNotificationLedger.maximumPolledAlertsPerRefresh)
    for thread in announced {
      await scheduleReplyNotification(for: thread)
    }
  }

  private func scheduleReplyNotification(for thread: MobileRemoteThreadSummary) async {
    guard let messageID = thread.latestAssistantMessageID else { return }
    let content = UNMutableNotificationContent()
    content.title = thread.title
    let runtimeTitle: String
    switch thread.runtime {
    case "codex": runtimeTitle = "Codex"
    case "claude": runtimeTitle = "Claude Code"
    default: runtimeTitle = "OpenClaw"
    }
    let preview = thread.latestAssistantPreview?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let preview, !preview.isEmpty {
      content.body = preview
    } else {
      content.body = runtimeTitle + " replied."
    }
    content.categoryIdentifier = MobileRemoteNotification.replyCategory
    content.threadIdentifier = thread.id.uuidString
    content.userInfo = [
      "threadID": thread.id.uuidString,
      "messageID": messageID.uuidString
    ]
    // Show a normal banner without adding sound or a badge. `.passive` often
    // deposits the reply directly in Notification Center with no visible cue.
    content.interruptionLevel = .active
    let request = UNNotificationRequest(
      identifier: "org2.thread.reply.\(thread.id.uuidString).\(messageID.uuidString)",
      content: content,
      trigger: nil
    )
    try? await UNUserNotificationCenter.current().add(request)
  }

  func sendTestReplyNotification() async {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    await prepareThreadNotifications()
    guard !threadNotificationsUnavailable else { return }
    await syncPushRegistrationIfNeeded(force: true)
    guard realTimeNotificationsActive else { return }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/push-test",
        payload: MobileRemotePushRegistrationRequest(
          deviceToken: nil,
          environment: nil,
          enabled: true
        ),
        as: MobileRemoteMutationResponse.self
      )
      if !response.accepted {
        pushNotificationStatusText = "The Mac did not accept the test push"
      }
    } catch {
      pushNotificationStatusText = "Test push failed: \(error.localizedDescription)"
    }
  }

  nonisolated private static func notificationAuthorizationAllowsAlerts(
    _ status: UNAuthorizationStatus
  ) -> Bool {
    status == .authorized || status == .provisional || status == .ephemeral
  }

  func createThread(
    destination: MobileRemoteAIDestination,
    project: MobileRemoteProjectSummary? = nil
  ) async -> UUID? {
    guard isConnected else {
      errorMessage = connectionError.map {
        "Reconnect to the Mac before creating a chat. \($0)"
      } ?? "Reconnect to the Mac before creating a chat."
      return nil
    }
    guard status?.supportsClientThreadIDs == true else {
      return await createThreadAwaitingHost(destination: destination, project: project)
    }
    // Open the new chat immediately. The host accepts this client-chosen ID,
    // so navigation never waits on a Tailscale round trip; thread requests
    // for the ID wait on the pending creation instead.
    let threadID = UUID()
    let summary = MobileRemoteThreadSummary(
      id: threadID,
      title: "New Chat",
      runtime: destination.runtime,
      destinationID: destination.id,
      destinationName: destination.name,
      isSharedRoom: false,
      model: nil,
      updatedAt: Date(),
      isSettled: false,
      isPinned: false,
      isRunning: false,
      unreadMessageCount: 0,
      preview: nil,
      latestAssistantMessageID: nil,
      latestAssistantPreview: nil
    )
    cacheThreadDetail(MobileRemoteThreadDetail(
      thread: summary,
      messages: [],
      activeDestinationName: destination.name,
      streamingReply: "",
      reasoning: "",
      activities: [],
      connectionState: "connected",
      connectionDetail: nil
    ))
    apply(summary)
    let request = MobileRemoteCreateThreadRequest(
      runtime: destination.runtime,
      destinationID: destination.id,
      projectID: project?.id,
      threadID: threadID
    )
    pendingThreadCreations[threadID] = Task { [weak self] in
      guard let self else { return false }
      return await self.finishOptimisticThreadCreation(threadID, request: request)
    }
    return threadID
  }

  private func finishOptimisticThreadCreation(
    _ threadID: UUID,
    request: MobileRemoteCreateThreadRequest
  ) async -> Bool {
    activeRequestCount += 1
    defer {
      activeRequestCount -= 1
      pendingThreadCreations[threadID] = nil
    }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads",
        payload: request,
        as: MobileRemoteMutationResponse.self
      )
      guard response.threadID == threadID else {
        throw MobileRemoteClientError.malformedResponse
      }
      Task { [weak self] in
        await self?.refresh(reportsErrors: false)
      }
      return true
    } catch {
      errorMessage = "The chat could not be created: \(error.localizedDescription)"
      threads.removeAll { $0.id == threadID }
      threadDetailCache.removeValue(forKey: threadID)
      threadDetailCacheOrder.removeAll { $0 == threadID }
      if pollingThreadID == threadID {
        threadConnectionError = error.localizedDescription
      }
      return false
    }
  }

  /// Returns false when the thread was optimistically opened but the host
  /// rejected its creation, so callers skip requests that would 404.
  private func awaitPendingCreation(of threadID: UUID) async -> Bool {
    guard let pending = pendingThreadCreations[threadID] else { return true }
    return await pending.value
  }

  private func createThreadAwaitingHost(
    destination: MobileRemoteAIDestination,
    project: MobileRemoteProjectSummary?
  ) async -> UUID? {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads",
        payload: MobileRemoteCreateThreadRequest(
          runtime: destination.runtime,
          destinationID: destination.id,
          projectID: project?.id
        ),
        as: MobileRemoteMutationResponse.self
      )
      guard let threadID = response.threadID else {
        throw MobileRemoteClientError.malformedResponse
      }
      Task { [weak self] in
        await self?.refresh(reportsErrors: false)
      }
      return threadID
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func setProjectMembership(
    _ isMember: Bool,
    project: MobileRemoteProjectSummary,
    threadID: UUID
  ) async {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    guard !mutatingThreadIDs.contains(threadID) else { return }
    mutatingThreadIDs.insert(threadID)
    defer { mutatingThreadIDs.remove(threadID) }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/project",
        payload: MobileRemoteUpdateThreadProjectRequest(
          projectID: project.id,
          isMember: isMember
        ),
        as: MobileRemoteMutationResponse.self
      )
      guard response.accepted else {
        throw MobileRemoteClientError.server("The host did not update the project.")
      }
      await refresh(reportsErrors: false)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func refreshExternalThreads() async {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    guard !isRefreshingExternalThreads else { return }
    isRefreshingExternalThreads = true
    defer { isRefreshingExternalThreads = false }
    do {
      let response = try await pairedClient().get(
        "/v1/external-threads",
        timeout: 45,
        as: MobileExternalThreadList.self
      )
      externalThreads = response.threads
      let summariesByID = Dictionary(uniqueKeysWithValues: response.threads.map { ($0.id, $0) })
      externalThreadDetailCache = externalThreadDetailCache.filter { id, detail in
        summariesByID[id]?.updatedAt == detail.thread.updatedAt
      }
      externalThreadDetailCacheOrder.removeAll { externalThreadDetailCache[$0] == nil }
      isConnected = true
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func loadExternalThread(_ thread: MobileExternalThreadSummary) async {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    let requestID = UUID()
    externalThreadLoadRequestID = requestID
    if let cached = externalThreadDetailCache[thread.id] {
      externalThreadDetail = cached
      touchExternalThreadDetailCache(thread.id)
      isLoadingExternalThread = false
      return
    }
    isLoadingExternalThread = true
    externalThreadDetail = nil
    defer {
      if externalThreadLoadRequestID == requestID {
        externalThreadLoadRequestID = nil
        isLoadingExternalThread = false
      }
    }
    do {
      let detail = try await pairedClient().get(
        externalThreadPath(thread),
        timeout: 60,
        as: MobileExternalThreadDetail.self
      )
      guard externalThreadLoadRequestID == requestID else { return }
      externalThreadDetail = detail
      externalThreadDetailCache[thread.id] = detail
      touchExternalThreadDetailCache(thread.id)
      while externalThreadDetailCacheOrder.count > Self.externalThreadDetailCacheLimit {
        externalThreadDetailCache.removeValue(forKey: externalThreadDetailCacheOrder.removeFirst())
      }
    } catch {
      if externalThreadLoadRequestID == requestID {
        errorMessage = error.localizedDescription
      }
    }
  }

  func clearExternalThreadDetail() {
    externalThreadLoadRequestID = nil
    isLoadingExternalThread = false
    externalThreadDetail = nil
  }

  private func touchExternalThreadDetailCache(_ id: String) {
    externalThreadDetailCacheOrder.removeAll { $0 == id }
    externalThreadDetailCacheOrder.append(id)
  }

  func continueExternalThread(_ thread: MobileExternalThreadSummary) async -> UUID? {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        externalThreadPath(thread) + "/continue",
        payload: EmptyPayload(),
        timeout: 30,
        as: MobileRemoteMutationResponse.self
      )
      await refresh()
      return response.threadID
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func forkThread(_ threadID: UUID) async -> UUID? {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    guard !mutatingThreadIDs.contains(threadID) else { return nil }
    mutatingThreadIDs.insert(threadID)
    defer { mutatingThreadIDs.remove(threadID) }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/fork",
        payload: EmptyPayload(),
        as: MobileRemoteMutationResponse.self
      )
      await refresh()
      return response.threadID
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  private func externalThreadPath(_ thread: MobileExternalThreadSummary) -> String {
    var allowed = CharacterSet.urlPathAllowed
    allowed.remove(charactersIn: "/")
    let externalID = thread.externalID.addingPercentEncoding(withAllowedCharacters: allowed)
      ?? thread.externalID
    return "/v1/external-threads/\(thread.harness.rawValue)/\(externalID)"
  }

  @discardableResult
  func beginPolling(threadID: UUID) -> UUID {
    pollingTask?.cancel()
    let leaseID = UUID()
    if pollingThreadID != threadID {
      threadDetail = threadDetailCache[threadID]
      threadConfiguration = nil
      threadConnectionError = nil
      configurationError = nil
    }
    pollingThreadID = threadID
    pollingLeaseID = leaseID
    loadingThreadID = threadDetail?.thread.id == threadID ? nil : threadID
    Task { [weak self] in
      await self?.refreshThreadConfiguration(threadID, pollingLeaseID: leaseID)
    }
    pollingTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        await self.refreshThread(threadID, pollingLeaseID: leaseID)
        guard self.pollingLeaseID == leaseID else { return }
        let isActivelyChanging = self.threadDetail?.thread.id == threadID
          && (self.threadDetail?.thread.isRunning == true
            || self.threadDetail?.streamingReply.isEmpty == false)
        try? await Task.sleep(for: .seconds(isActivelyChanging ? 1 : 4))
      }
    }
    return leaseID
  }

  func endPolling(threadID: UUID, leaseID: UUID) {
    guard pollingThreadID == threadID, pollingLeaseID == leaseID else { return }
    pollingTask?.cancel()
    pollingTask = nil
    pollingThreadID = nil
    pollingLeaseID = nil
    if loadingThreadID == threadID {
      loadingThreadID = nil
    }
    if threadDetail?.thread.id == threadID {
      threadDetail = nil
    }
    if threadConfiguration?.threadID == threadID {
      threadConfiguration = nil
    }
  }

  func send(
    _ rawMessage: String,
    attachments: [MobileRemoteAttachment],
    threadID: UUID,
    delivery: String? = nil
  ) async -> UUID? {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !message.isEmpty || !attachments.isEmpty else { return nil }
    guard await awaitPendingCreation(of: threadID) else { return nil }
    do {
      let response: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/messages",
        payload: MobileRemoteSendMessageRequest(
          content: message,
          attachments: attachments,
          delivery: delivery
        ),
        // A busy host can take a while to accept a send; giving up early
        // reported failures for messages the host then delivered anyway.
        timeout: attachments.isEmpty ? 45 : 90,
        as: MobileRemoteMutationResponse.self
      )
      let destinationThreadID = response.threadID ?? threadID
      if destinationThreadID == threadID {
        await refreshThread(threadID)
      } else {
        await refresh()
      }
      return destinationThreadID
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func filePreview(path: String, line: Int?) async throws -> MobileRemoteFilePreview {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    return try await pairedClient().post(
      "/v1/files/preview",
      payload: MobileRemoteFilePreviewRequest(path: path, line: line),
      timeout: 60,
      as: MobileRemoteFilePreview.self
    )
  }

  /// The files this thread edited or linked, derived on the host exactly as
  /// the Mac's Outputs chip derives them. Nil when the host predates outputs.
  func threadOutputs(threadID: UUID) async throws -> MobileRemoteThreadOutputs? {
    guard status?.supportsThreadOutputs == true else { return nil }
    return try await pairedClient().get(
      "/v1/threads/\(threadID.uuidString)/outputs",
      timeout: 30,
      as: MobileRemoteThreadOutputs.self
    )
  }

  func imageData(path: String) async throws -> Data {
    try await pairedClient().post(
      "/v1/files/image",
      payload: MobileRemoteImageRequest(path: path),
      timeout: 60,
      as: MobileRemoteImage.self
    ).data
  }

  func setModel(_ model: String?, threadID: UUID) async {
    await updateThreadConfiguration(
      MobileRemoteUpdateThreadConfigurationRequest(model: model),
      threadID: threadID
    )
  }

  func setReasoningEffort(_ effort: String?, threadID: UUID) async {
    await updateThreadConfiguration(
      MobileRemoteUpdateThreadConfigurationRequest(reasoningEffort: effort),
      threadID: threadID
    )
  }

  private func updateThreadConfiguration(
    _ request: MobileRemoteUpdateThreadConfigurationRequest,
    threadID: UUID
  ) async {
    guard await awaitPendingCreation(of: threadID) else { return }
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    guard !isUpdatingConfiguration else { return }
    isUpdatingConfiguration = true
    defer { isUpdatingConfiguration = false }
    do {
      let configuration: MobileRemoteThreadConfiguration = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/configuration",
        payload: request,
        as: MobileRemoteThreadConfiguration.self
      )
      guard pollingThreadID == threadID else { return }
      threadConfiguration = configuration
      configurationError = nil
      await refreshThread(threadID)
    } catch {
      configurationError = error.localizedDescription
      errorMessage = error.localizedDescription
    }
  }

  func setPinned(_ isPinned: Bool, threadID: UUID) async {
    await updateThreadState(
      MobileRemoteUpdateThreadStateRequest(isPinned: isPinned, isSettled: nil),
      threadID: threadID
    )
  }

  func setSettled(_ isSettled: Bool, threadID: UUID) async {
    await updateThreadState(
      MobileRemoteUpdateThreadStateRequest(isPinned: nil, isSettled: isSettled),
      threadID: threadID
    )
  }

  func stop(threadID: UUID) async {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    do {
      let _: MobileRemoteMutationResponse = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/stop",
        payload: EmptyPayload(),
        as: MobileRemoteMutationResponse.self
      )
      await refreshThread(threadID)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func refreshThread(_ threadID: UUID, pollingLeaseID expectedLeaseID: UUID? = nil) async {
    guard await awaitPendingCreation(of: threadID) else { return }
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    do {
      let detail = try await pairedClient().get(
        "/v1/threads/\(threadID.uuidString)",
        as: MobileRemoteThreadDetail.self
      )
      guard pollingThreadID == threadID,
            expectedLeaseID == nil || pollingLeaseID == expectedLeaseID
      else { return }
      recordReplyNotificationBaseline(for: detail)
      cacheThreadDetail(detail)
      if threadDetail != detail {
        threadDetail = detail
      }
      loadingThreadID = nil
      isConnected = true
      threadConnectionError = nil
      if let index = threads.firstIndex(where: { $0.id == threadID }) {
        threads[index] = detail.thread
      }
    } catch {
      if !Task.isCancelled,
         pollingThreadID == threadID,
         expectedLeaseID == nil || pollingLeaseID == expectedLeaseID {
        loadingThreadID = nil
        isConnected = false
        threadConnectionError = error.localizedDescription
      }
    }
  }

  private func refreshThreadConfiguration(
    _ threadID: UUID,
    pollingLeaseID expectedLeaseID: UUID? = nil
  ) async {
    guard await awaitPendingCreation(of: threadID) else { return }
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    let requestID = UUID()
    configurationRequestID = requestID
    isRefreshingConfiguration = true
    defer {
      if configurationRequestID == requestID {
        isRefreshingConfiguration = false
      }
    }
    do {
      let configuration = try await pairedClient().get(
        "/v1/threads/\(threadID.uuidString)/configuration",
        as: MobileRemoteThreadConfiguration.self
      )
      guard pollingThreadID == threadID,
            expectedLeaseID == nil || pollingLeaseID == expectedLeaseID
      else { return }
      threadConfiguration = configuration
      configurationError = nil
    } catch {
      guard !Task.isCancelled,
            pollingThreadID == threadID,
            expectedLeaseID == nil || pollingLeaseID == expectedLeaseID
      else { return }
      configurationError = error.localizedDescription
    }
  }

  private func updateThreadState(
    _ request: MobileRemoteUpdateThreadStateRequest,
    threadID: UUID
  ) async {
    activeRequestCount += 1
    defer { activeRequestCount -= 1 }
    guard !mutatingThreadIDs.contains(threadID) else { return }
    mutatingThreadIDs.insert(threadID)
    defer { mutatingThreadIDs.remove(threadID) }
    do {
      let summary: MobileRemoteThreadSummary = try await pairedClient().post(
        "/v1/threads/\(threadID.uuidString)/state",
        payload: request,
        as: MobileRemoteThreadSummary.self
      )
      apply(summary)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func apply(_ summary: MobileRemoteThreadSummary) {
    if let index = threads.firstIndex(where: { $0.id == summary.id }) {
      threads[index] = summary
    } else {
      threads.append(summary)
    }
    threads.sort {
      if $0.isSettled != $1.isSettled { return !$0.isSettled }
      if $0.isPinned != $1.isPinned { return $0.isPinned }
      return $0.updatedAt > $1.updatedAt
    }
    if let detail = threadDetailCache[summary.id] {
      let updatedDetail = MobileRemoteThreadDetail(
        thread: summary,
        messages: detail.messages,
        activeDestinationName: detail.activeDestinationName,
        streamingReply: detail.streamingReply,
        reasoning: detail.reasoning,
        activities: detail.activities,
        connectionState: detail.connectionState,
        connectionDetail: detail.connectionDetail
      )
      cacheThreadDetail(updatedDetail)
      if threadDetail?.thread.id == summary.id {
        threadDetail = updatedDetail
      }
    }
  }

  private func cacheThreadDetail(_ detail: MobileRemoteThreadDetail) {
    let id = detail.thread.id
    threadDetailCache[id] = detail
    threadDetailCacheOrder.removeAll { $0 == id }
    threadDetailCacheOrder.append(id)
    while threadDetailCacheOrder.count > Self.threadDetailCacheLimit {
      let evictedID = threadDetailCacheOrder.removeFirst()
      threadDetailCache.removeValue(forKey: evictedID)
    }
  }

  private func pruneThreadDetailCache(keeping threadIDs: Set<UUID>) {
    threadDetailCache = threadDetailCache.filter { threadIDs.contains($0.key) }
    threadDetailCacheOrder.removeAll { !threadIDs.contains($0) }
  }

  private func pairedClient() throws -> MobileRemoteClient {
    guard !isPairing, let accessToken else { throw MobileRemoteClientError.server("Pair this phone with the host again.") }
    return try MobileRemoteClient(endpoint: activeEndpoint, accessToken: accessToken)
  }

  var pairedEndpoint: String {
    activeEndpoint
  }

  private static func saveToken(_ token: String, account: String = tokenAccount) throws {
    let data = Data(token.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: tokenService,
      kSecAttrAccount as String: account
    ]
    let attributes: [String: Any] = [
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var addition = query
      attributes.forEach { addition[$0.key] = $0.value }
      let added = SecItemAdd(addition as CFDictionary, nil)
      guard added == errSecSuccess else { throw MobileRemoteKeychainError.status(added) }
    } else if status != errSecSuccess {
      throw MobileRemoteKeychainError.status(status)
    }
  }

  private static func loadToken(account: String = tokenAccount) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: tokenService,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  private static func deleteToken(account: String = tokenAccount) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: tokenService,
      kSecAttrAccount as String: account
    ]
    SecItemDelete(query as CFDictionary)
  }
}

private struct EmptyPayload: Encodable {}

private enum MobileRemoteKeychainError: LocalizedError {
  case status(OSStatus)

  var errorDescription: String? {
    switch self {
    case .status(let status):
      "Could not store the pairing credential in Keychain (\(status))."
    }
  }
}
