import Combine
import CryptoKit
import Darwin
import Foundation
import Security

public struct MobileRemotePairedDevice: Codable, Identifiable, Hashable {
  public let id: UUID
  public let name: String
  public let pairedAt: Date
  public let pushRegisteredAt: Date?

  public init(id: UUID, name: String, pairedAt: Date, pushRegisteredAt: Date? = nil) {
    self.id = id
    self.name = name
    self.pairedAt = pairedAt
    self.pushRegisteredAt = pushRegisteredAt
  }
}

@MainActor
public final class MobileRemoteCoordinator: ObservableObject {
  @Published public private(set) var isEnabled: Bool
  @Published public private(set) var bindHost: String
  @Published public private(set) var isListening = false
  @Published public private(set) var statusText = "Off"
  @Published public private(set) var pairingCode: String?
  @Published public private(set) var pairingExpiresAt: Date?
  @Published public private(set) var pairedDevices: [MobileRemotePairedDevice]
  @Published public private(set) var pushTeamID: String
  @Published public private(set) var pushKeyID: String
  @Published public private(set) var pushProviderConfigured: Bool
  @Published public private(set) var pushStatusText: String

  private static let enabledKey = "Org2Workspace.mobileRemote.enabled.v1"
  private static let bindHostKey = "Org2Workspace.mobileRemote.bindHost.v1"
  private static let pairingLifetime: TimeInterval = 10 * 60

  private let configuredServerName: String?
  private let hostRef: String?
  private let port: UInt16
  private let defaults: UserDefaults
  private let credentialVault: MobileRemoteCredentialVault
  private let pushCredentialStore: MobileRemotePushCredentialStore
  private let pushSender: MobileRemotePushSender
  private let backgroundWork = MobileRemoteBackgroundWork()
  private let syncedTranscriptRequestGate = MobileRemoteRequestRefreshGate(reuseInterval: 1.5)
  private weak var store: WorkspaceStore?
  private var server: MobileRemoteHTTPServer?
  private var failedPairingAttempts = 0
  private var serverGeneration = 0
  private var restartTask: Task<Void, Never>?
  /// Prompt keys pushed to each device, with when. A device gets one push per prompt, and a
  /// delivered prompt left unanswered no longer blocks the next one.
  private var deliveredPushToTalkPrompts: [UUID: [String: Date]] = [:]
  private var pushToTalkPollTask: Task<Void, Never>?
  /// Test seam for `AudioApprovalPromptPolicy.answerWindow`.
  var pushToTalkAnswerWindow = AudioApprovalPromptPolicy.answerWindow
  /// "Later" for one exact prompt, keyed by `AudioApprovalPromptTarget.key`.
  private var snoozedAudioApprovalPrompts: [String: Date] = [:]
  private var pushToTalkWakeTask: Task<Void, Never>?
  /// Test seam: replaces APNs delivery so the full host flow can run without Apple's servers.
  var pushToTalkDeliveryForTesting: ((MobileRemotePushToTalkEnvelope, MobileRemoteStoredPushToTalkRegistration) async throws -> Void)?

  public init(
    defaults: UserDefaults = .standard,
    credentialNamespace: String? = nil,
    credentialFile: URL? = nil,
    pushCredentialFile: URL? = nil,
    serverName: String? = nil,
    hostRef: String? = nil,
    port: UInt16 = MobileRemoteProtocol.defaultPort
  ) {
    self.configuredServerName = serverName
    self.hostRef = hostRef
    self.port = port
    self.defaults = defaults
    pushCredentialStore = MobileRemotePushCredentialStore(
      defaults: defaults,
      credentialNamespace: credentialNamespace,
      privateKeyFile: pushCredentialFile
    )
    pushSender = MobileRemotePushSender()
    credentialVault = MobileRemoteCredentialVault(credentialNamespace: credentialNamespace, credentialFile: credentialFile)
    isEnabled = defaults.bool(forKey: Self.enabledKey)
    let savedHost = defaults.string(forKey: Self.bindHostKey) ?? ""
    bindHost = savedHost.isEmpty ? (Self.tailscaleIPv4Addresses().first ?? "") : savedHost
    pairedDevices = credentialVault.devices
    pushTeamID = pushCredentialStore.teamID
    pushKeyID = pushCredentialStore.keyID
    pushProviderConfigured = pushCredentialStore.isConfigured
    pushStatusText = pushCredentialStore.isConfigured
      ? "Ready for real-time iPhone alerts"
      : "Import an APNs authentication key to enable real-time alerts"
  }

  public var endpoint: String? {
    guard Self.isTailscaleIPv4(bindHost) else { return nil }
    return "http://\(bindHost):\(port)"
  }

  public var pairingPayload: String? {
    guard let endpoint, let pairingCode else { return nil }
    var components = URLComponents()
    components.scheme = "org2-remote"
    components.host = "pair"
    components.queryItems = [
      URLQueryItem(name: "endpoint", value: endpoint),
      URLQueryItem(name: "code", value: pairingCode),
      URLQueryItem(name: "name", value: serverName)
    ]
    return components.string
  }

  public var pairingExpirationText: String? {
    guard let pairingExpiresAt else { return nil }
    return pairingExpiresAt.formatted(date: .omitted, time: .shortened)
  }

  public func attach(to store: WorkspaceStore) {
    self.store = store
    store.aiChatIncomingMessageHandler = { [weak self] thread, messages in
      self?.enqueuePushNotifications(for: thread, messages: messages)
    }
    store.approvalQueueChangeHandler = { [weak self] approvals in
      self?.enqueuePushToTalkApproval(from: approvals)
    }
    requestPushToTalkEvaluation()
  }

  public func setPushTeamID(_ value: String) {
    pushCredentialStore.setTeamID(value)
    refreshPushProviderState()
  }

  public func setPushKeyID(_ value: String) {
    pushCredentialStore.setKeyID(value)
    refreshPushProviderState()
  }

  @discardableResult
  public func importPushPrivateKey(_ data: Data) -> Bool {
    do {
      try pushCredentialStore.importPrivateKey(data)
      refreshPushProviderState()
      pushStatusText = "APNs key saved securely in Keychain"
      return true
    } catch {
      pushStatusText = error.localizedDescription
      return false
    }
  }

  public func clearPushPrivateKey() {
    do {
      try pushCredentialStore.clearPrivateKey()
      refreshPushProviderState()
      pushStatusText = "APNs key removed"
    } catch {
      pushStatusText = error.localizedDescription
    }
  }

  public func startIfConfigured() {
    guard isEnabled, server == nil else { return }
    start()
  }

  public func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.enabledKey)
    if enabled {
      start()
    } else {
      stop()
    }
  }

  public func setBindHost(_ host: String) {
    let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
    guard bindHost != normalized else { return }
    bindHost = normalized
    defaults.set(normalized, forKey: Self.bindHostKey)
    if isEnabled {
      start()
    }
  }

  public func useDetectedTailscaleAddress() {
    guard let address = Self.tailscaleIPv4Addresses().first else { return }
    setBindHost(address)
  }

  public func generatePairingCode() {
    guard isEnabled, isListening, endpoint != nil else {
      statusText = "Turn on Mobile Remote with this Mac’s current Tailscale address first."
      return
    }
    var random: UInt32 = 0
    let result = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &random)
    guard result == errSecSuccess else {
      statusText = "Could not create a secure pairing code."
      return
    }
    pairingCode = String(format: "%06u", random % 1_000_000)
    pairingExpiresAt = Date().addingTimeInterval(Self.pairingLifetime)
    failedPairingAttempts = 0
  }

  /// Test seam: pairing normally requires a live Tailscale listener.
  func setPairingCodeForTesting(_ code: String) {
    pairingCode = code
    pairingExpiresAt = Date().addingTimeInterval(Self.pairingLifetime)
    failedPairingAttempts = 0
  }

  public func revoke(_ device: MobileRemotePairedDevice) {
    do {
      try credentialVault.revoke(device.id)
      pairedDevices = credentialVault.devices
      statusText = "Revoked \(device.name)"
    } catch {
      statusText = "Could not revoke \(device.name): \(error.localizedDescription)"
    }
  }

  public func revokeAllDevices() {
    do {
      try credentialVault.revokeAll()
      pairedDevices = []
      statusText = "Revoked all mobile devices"
    } catch {
      statusText = "Could not revoke mobile devices: \(error.localizedDescription)"
    }
  }

  private func start() {
    restartTask?.cancel()
    restartTask = nil
    guard store != nil else {
      statusText = "Waiting for the workspace"
      return
    }
    guard let selectedBindHost = resolvedBindHostForStart() else {
      stopServer()
      statusText = "Turn on Tailscale or choose this Mac’s current Tailscale IPv4 address"
      scheduleRestartIfNeeded()
      return
    }

    serverGeneration &+= 1
    let generation = serverGeneration
    server?.stop()
    server = nil
    isListening = false
    let server = MobileRemoteHTTPServer(
      handler: { [weak self] request in
        guard let self else {
          return .error("The Celorga workspace is unavailable.", statusCode: 503)
        }
        return await self.handle(request)
      },
      stateHandler: { [weak self] state in
        Task { @MainActor in
          guard self?.serverGeneration == generation else { return }
          self?.statusText = state
          self?.isListening = state.hasPrefix("Listening on ")
          if state.hasPrefix("Failed: ") {
            self?.server = nil
            self?.scheduleRestartIfNeeded()
          }
        }
      }
    )
    do {
      try server.start(host: selectedBindHost, port: port)
      self.server = server
    } catch {
      self.server = nil
      statusText = error.localizedDescription
    }
  }

  private func stop() {
    stopServer()
    pairingCode = nil
    pairingExpiresAt = nil
    failedPairingAttempts = 0
    statusText = "Off"
  }

  private func stopServer() {
    restartTask?.cancel()
    restartTask = nil
    serverGeneration &+= 1
    server?.stop()
    server = nil
    isListening = false
  }

  private func scheduleRestartIfNeeded() {
    guard isEnabled, restartTask == nil else { return }
    restartTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(5))
      await MainActor.run {
        guard let self, self.isEnabled, self.server == nil else { return }
        self.restartTask = nil
        self.start()
      }
    }
  }

  private func resolvedBindHostForStart() -> String? {
    let normalized = bindHost.trimmingCharacters(in: .whitespacesAndNewlines)
    guard Self.isTailscaleIPv4(normalized) else { return nil }
    let detectedAddresses = Self.tailscaleIPv4Addresses()
    guard !detectedAddresses.isEmpty else { return nil }
    if detectedAddresses.contains(normalized) {
      return normalized
    }
    guard let detected = detectedAddresses.first else { return nil }
    bindHost = detected
    defaults.set(detected, forKey: Self.bindHostKey)
    return detected
  }

  func handle(_ request: MobileRemoteHTTPRequest) async -> MobileRemoteHTTPResponse {
    let response = await handleRequest(request)
    guard request.method == "GET" else { return response }
    return await backgroundWork.conditionalResponse(
      response,
      ifNoneMatch: request.headers["if-none-match"]
    )
  }

  /// Phone requests reconcile synced chat storage at the request boundary.
  /// Concurrent requests share one reconciliation, and back-to-back polls
  /// reuse a reconciliation that finished moments ago; the corpus watcher
  /// still applies new commits between requests.
  private func refreshSyncedAIChatTranscriptForRequest(store: WorkspaceStore) async {
    await syncedTranscriptRequestGate.run {
      _ = await store.refreshSyncedAIChatTranscript()
    }
  }

  /// External-source credentials and syncs on a headless host. A paired Mac
  /// signs in (it can show a browser and Keychain prompts) and hands the
  /// credential here, so this host can run the source's scheduled syncs.
  /// Responses never echo credential values.
  func handleSourceRequest(
    _ request: MobileRemoteHTTPRequest,
    path: String,
    store: WorkspaceStore
  ) async -> MobileRemoteHTTPResponse? {
    if request.method == "GET", path == "/v1/sources/credentials" {
      return .json(MobileRemoteSourceCredentialList(profileIDs: store.storedSourceCredentialProfileIDs()))
    }
    let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard components.count == 4, components[0] == "v1", components[1] == "sources",
          let profileID = components[2].removingPercentEncoding,
          SourceCredentialsFileStore.isValidProfileID(profileID)
    else { return nil }
    switch (request.method, components[3]) {
    case ("PUT", "credential"):
      guard let payload = try? request.decode(MobileRemoteSourceCredentialRequest.self),
            !payload.credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            payload.credential.utf8.count <= 64 * 1024
      else {
        return .error("The source credential could not be read.", statusCode: 400)
      }
      do {
        try store.storeSourceCredentialFromPairedClient(payload.credential, profileID: profileID)
        return .json(MobileRemoteSourceCredentialResponse(profileID: profileID, stored: true))
      } catch {
        return .error(error.localizedDescription, statusCode: 500)
      }
    case ("DELETE", "credential"):
      do {
        try store.deleteSourceCredentialFromPairedClient(profileID: profileID)
        return .json(MobileRemoteSourceCredentialResponse(profileID: profileID, stored: false))
      } catch {
        return .error(error.localizedDescription, statusCode: 500)
      }
    case ("POST", "sync"):
      let result = await store.runSourceSyncForPairedClient(profileID: profileID)
      return .json(result)
    default:
      return nil
    }
  }

  private func handleRequest(_ request: MobileRemoteHTTPRequest) async -> MobileRemoteHTTPResponse {
    let path = request.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.path
    if request.method == "POST", path == "/v1/pair" {
      return handlePair(request)
    }

    guard let token = request.bearerToken, credentialVault.contains(token: token) else {
      return .error("Pair this device with this host again.", statusCode: 401)
    }
    guard let store else {
      return .error("The Celorga workspace is unavailable.", statusCode: 503)
    }

    if request.method == "GET", path == "/v1/status" {
      let threads = store.aiChatThreads
      return .json(MobileRemoteServerStatus(
        serverName: serverName,
        hostRef: hostRef ?? store.aiChatHostIdentity.ref,
        hostKind: hostRef == nil ? "desktop" : "server",
        corpusName: store.corpusRoot?.lastPathComponent,
        threadCount: threads.count,
        runningThreadCount: threads.filter {
          store.isAIChatThreadRunningOnCurrentHost($0.id)
            || store.aiChatRemoteLiveTurn(for: $0.id) != nil
        }.count,
        aiChatDestinations: store.enabledAIChatDestinations.map {
          MobileRemoteAIDestination(
            id: $0.id,
            name: $0.name,
            mention: $0.mention,
            runtime: $0.runtime.rawValue
          )
        },
        pushNotificationsSupported: true,
        pushNotificationsConfigured: pushProviderConfigured
      ))
    }

    if request.method == "POST", path == "/v1/push-registration" {
      guard let payload = try? request.decode(MobileRemotePushRegistrationRequest.self) else {
        return .error("The push registration could not be read.", statusCode: 400)
      }
      do {
        let enabled = try credentialVault.setPushRegistration(payload, forAccessToken: token)
        pairedDevices = credentialVault.devices
        return .json(MobileRemotePushRegistrationResponse(
          enabled: enabled,
          providerConfigured: pushProviderConfigured
        ))
      } catch {
        return .error(error.localizedDescription, statusCode: 400)
      }
    }

    if request.method == "POST", path == "/v1/push-to-talk-registration" {
      guard let payload = try? request.decode(MobileRemotePushToTalkRegistrationRequest.self) else {
        return .error("The Push to Talk registration could not be read.", statusCode: 400)
      }
      do {
        let enabled = try credentialVault.setPushToTalkRegistration(payload, forAccessToken: token)
        pairedDevices = credentialVault.devices
        if let deviceID = credentialVault.deviceID(forAccessToken: token) {
          // A new token, or leaving quiet, should receive the current prompt again.
          deliveredPushToTalkPrompts[deviceID] = nil
        }
        requestPushToTalkEvaluation()
        return .json(MobileRemotePushToTalkRegistrationResponse(
          enabled: enabled,
          providerConfigured: pushProviderConfigured
        ))
      } catch {
        return .error(error.localizedDescription, statusCode: 400)
      }
    }

    if request.method == "POST", path == "/v1/audio-approvals/snooze" {
      guard let payload = try? request.decode(MobileRemoteAudioApprovalSnoozeRequest.self) else {
        return .error("The snooze request could not be read.", statusCode: 400)
      }
      let now = Date()
      // Bounded: at least a minute, at most a day. A snooze is never a decision.
      let until = min(max(payload.until, now.addingTimeInterval(60)), now.addingTimeInterval(24 * 60 * 60))
      let target = AudioApprovalPromptTarget(
        runID: payload.runID,
        approvalID: payload.approvalID,
        fingerprint: payload.fingerprint
      )
      snoozedAudioApprovalPrompts[target.key] = until
      requestPushToTalkEvaluation()
      return .json(MobileRemoteAudioApprovalSnoozeResponse(snoozedUntil: until))
    }

    if request.method == "POST", path == "/v1/push-test" {
      guard pushProviderConfigured else {
        return .error("Finish push notification setup in the Mac app.", statusCode: 503)
      }
      guard let registration = credentialVault.pushRegistration(forAccessToken: token) else {
        return .error("This iPhone has not registered for push notifications.", statusCode: 409)
      }
      let threadID = store.aiChatThreads.first?.id ?? UUID()
      do {
        try await deliverPush(
          MobileRemotePushEnvelope(
            messageID: UUID(),
            threadID: threadID,
            title: "Celorga reply notifications",
            body: "Real-time notifications are working on this iPhone."
          ),
          to: registration.registration
        )
        return .json(MobileRemoteMutationResponse(accepted: true, threadID: threadID), statusCode: 202)
      } catch {
        pushStatusText = error.localizedDescription
        return .error(error.localizedDescription, statusCode: 502)
      }
    }

    if request.method == "POST", path == "/v1/device/revoke" {
      // A client that forgets this host removes its own credential too.
      guard let device = credentialVault.device(forAccessToken: token) else {
        return .error("Pair this device with this host again.", statusCode: 401)
      }
      revoke(device)
      return .json(MobileRemoteMutationResponse(accepted: true))
    }

    if path == "/v1/sources/credentials" || path.hasPrefix("/v1/sources/") {
      if let response = await handleSourceRequest(request, path: path, store: store) {
        return response
      }
    }

    if request.method == "GET", path == "/v1/threads" {
      // A headless host may receive newer immutable chat commits from another
      // Mac between filesystem callbacks. Reconcile at the request boundary so
      // iOS never receives an avoidably stale thread list.
      await refreshSyncedAIChatTranscriptForRequest(store: store)
      let threads = store.aiChatThreads
      return await backgroundWork.threadListResponse(
        threads: threads,
        context: threadProjectionContext(for: threads, store: store),
        projects: mobileRemoteProjects(from: store.projectNotes)
      )
    }

    if request.method == "POST", path == "/v1/threads" {
      guard let payload = try? request.decode(MobileRemoteCreateThreadRequest.self) else {
        return .error("Choose a configured AI destination.", statusCode: 400)
      }
      let resolvedDestinationID: String
      if let requestedDestinationID = payload.destinationID {
        guard store.enabledAIChatDestinations.contains(where: { $0.id == requestedDestinationID }) else {
          return .error("That AI destination is unavailable on this host.", statusCode: 400)
        }
        resolvedDestinationID = requestedDestinationID
      } else {
        guard let runtime = AIChatRuntime(rawValue: payload.runtime) else {
          return .error("Choose a configured Codex, Claude Code, or OpenClaw runtime.", statusCode: 400)
        }
        resolvedDestinationID = store.enabledAIChatDestinations.first(where: { $0.runtime == runtime })?.id
          ?? AIChatDestinationConfiguration.defaultID(for: runtime)
      }
      // Client-chosen IDs make creation idempotent: a retried request for a
      // thread that already exists returns it instead of creating another.
      if let requestedID = payload.threadID,
         store.aiChatThreads.contains(where: { $0.id == requestedID }) {
        return .json(MobileRemoteMutationResponse(accepted: true, threadID: requestedID), statusCode: 201)
      }
      let id: UUID
      if let projectID = payload.projectID {
        guard let projectThreadID = await store.createAIChatRemoteThread(
          destinationID: resolvedDestinationID,
          projectID: projectID,
          id: payload.threadID ?? UUID()
        ) else {
          return .error(
            store.projectStatus.isEmpty
              ? "That chat could not be added to the project."
              : store.projectStatus,
            statusCode: 409
          )
        }
        id = projectThreadID
      } else {
        id = store.createAIChatRemoteThread(
          destinationID: resolvedDestinationID,
          id: payload.threadID ?? UUID()
        )
      }
      return .json(MobileRemoteMutationResponse(accepted: true, threadID: id), statusCode: 201)
    }

    if request.method == "GET", path == "/v1/workspace" {
      return await backgroundWork.jsonResponse(await store.mobileRemoteWorkspaceSnapshot())
    }

    let workspaceComponents = path.split(separator: "/").map(String.init)
    if workspaceComponents.count >= 5,
       workspaceComponents[0] == "v1",
       workspaceComponents[1] == "workspace",
       let itemID = workspaceComponents[3].removingPercentEncoding {
      // Whatever the outcome, the next snapshot request re-reads canonical state.
      defer { store.invalidateMobileRemoteWorkspaceSnapshot() }
      do {
        if request.method == "POST",
           workspaceComponents[2] == "agenda",
           workspaceComponents[4] == "status",
           let payload = try? request.decode(MobileRemoteAgendaStatusRequest.self) {
          return .json(try await store.setMobileRemoteAgendaStatus(
            itemID: itemID,
            status: payload.status
          ))
        }
        if request.method == "POST",
           workspaceComponents[2] == "approvals",
           workspaceComponents[4] == "decision",
           let payload = try? request.decode(MobileRemoteApprovalDecisionRequest.self) {
          // Applied or refused, the next prompt is chosen from fresh canonical state.
          defer { requestPushToTalkEvaluation() }
          return .json(try await store.decideMobileRemoteApproval(
            itemID: itemID,
            decision: payload.decision,
            note: payload.note,
            endStatus: payload.endStatus,
            expectedRunID: payload.runID,
            expectedApprovalID: payload.approvalID,
            expectedFingerprint: payload.fingerprint,
            receipt: payload.receipt
          ))
        }
        if request.method == "POST",
           workspaceComponents[2] == "workflows",
           workspaceComponents[4] == "state",
           let payload = try? request.decode(MobileRemoteWorkflowStateRequest.self) {
          return .json(try await store.setMobileRemoteWorkflowState(
            workflowID: itemID,
            state: payload.state
          ))
        }
        if request.method == "POST",
           workspaceComponents[2] == "workflows",
           workspaceComponents[4] == "run",
           let payload = try? request.decode(MobileRemoteWorkflowRunRequest.self) {
          let threadID = try await store.runMobileRemoteWorkflow(
            workflowID: itemID,
            inputs: payload.inputs
          )
          return .json(
            MobileRemoteMutationResponse(accepted: true, threadID: threadID),
            statusCode: 202
          )
        }
      } catch {
        return .error(error.localizedDescription, statusCode: 409)
      }
      return .error("Workspace action not found.", statusCode: 404)
    }

    if request.method == "POST", path == "/v1/files/preview" {
      guard let payload = try? request.decode(MobileRemoteFilePreviewRequest.self) else {
        return .error("The cited file reference could not be read.", statusCode: 400)
      }
      do {
        let preview = try await store.mobileRemoteFilePreview(path: payload.path, line: payload.line)
        return await backgroundWork.jsonResponse(preview)
      } catch {
        return .error(error.localizedDescription, statusCode: 404)
      }
    }

    if request.method == "POST", path == "/v1/files/image" {
      guard let payload = try? request.decode(MobileRemoteImageRequest.self) else {
        return .error("The image reference could not be read.", statusCode: 400)
      }
      do {
        let image = try await store.mobileRemoteImage(path: payload.path)
        return await backgroundWork.jsonResponse(image)
      } catch {
        return .error(error.localizedDescription, statusCode: 404)
      }
    }

    if request.method == "GET", path == "/v1/external-threads" {
      do {
        let threads = try await store.externalThreadSummaries()
        return await backgroundWork.jsonResponse(ExternalThreadList(threads: threads))
      } catch {
        return .error(error.localizedDescription, statusCode: 503)
      }
    }

    let externalComponents = path.split(separator: "/").map(String.init)
    if externalComponents.count >= 4,
       externalComponents[0] == "v1",
       externalComponents[1] == "external-threads",
       let harness = ExternalThreadHarness(rawValue: externalComponents[2]),
       let externalID = externalComponents[3].removingPercentEncoding {
      do {
        let detail = try await store.externalThreadDetail(
          harness: harness,
          externalID: externalID
        )
        if request.method == "GET", externalComponents.count == 4 {
          return await backgroundWork.jsonResponse(detail)
        }
        if request.method == "POST",
           externalComponents.count == 5,
           externalComponents[4] == "continue" {
          let threadID = try await store.continueExternalThreadInOrg2(
            detail,
            selectsThread: false
          )
          return .json(
            MobileRemoteMutationResponse(accepted: true, threadID: threadID),
            statusCode: 201
          )
        }
      } catch {
        return .error(error.localizedDescription, statusCode: 503)
      }
      return .error("External thread action not found.", statusCode: 404)
    }

    let components = path.split(separator: "/").map(String.init)
    if components.count >= 3,
       components[0] == "v1",
       components[1] == "threads" {
      await refreshSyncedAIChatTranscriptForRequest(store: store)
    }
    if components.count >= 4,
       components[0] == "v1",
       components[1] == "threads",
       components[3] == "share",
       let threadID = UUID(uuidString: components[2]) {
      return await handleThreadShare(request, threadID: threadID, components: components, store: store)
    }
    guard components.count >= 2, components[0] == "v1", components[1] == "threads" else {
      // Not a thread route. Saying "Thread not found." here hid unsupported requests.
      return .error("This Celorga host does not support \(request.method) \(path). Update Celorga on this Mac.", statusCode: 404)
    }
    guard components.count >= 3,
          let threadID = UUID(uuidString: components[2]),
          let thread = store.aiChatThreads.first(where: { $0.id == threadID })
    else {
      return .error("Thread not found.", statusCode: 404)
    }

    if request.method == "GET", components.count == 3 {
      guard let hydratedThread = await store.hydratedAIChatThreadForDetail(threadID) else {
        return .error("This conversation could not be loaded.", statusCode: 503)
      }
      return await backgroundWork.threadDetailResponse(
        thread: hydratedThread,
        context: threadDetailProjectionContext(for: hydratedThread, store: store)
      )
    }
    if request.method == "GET", components.count == 4, components[3] == "outputs" {
      return await handleThreadOutputs(threadID: threadID, store: store)
    }
    if request.method == "GET", components.count == 4, components[3] == "configuration" {
      do {
        let configuration = try await store.aiChatRemoteConfiguration(for: threadID)
        let current = store.aiChatThreads.first(where: { $0.id == threadID }) ?? thread
        return .json(threadConfiguration(configuration, thread: current))
      } catch {
        return .error(error.localizedDescription, statusCode: 503)
      }
    }
    if request.method == "POST", components.count == 4, components[3] == "configuration" {
      guard let payload = try? request.decode(MobileRemoteUpdateThreadConfigurationRequest.self) else {
        return .error("Choose a valid chat configuration.", statusCode: 400)
      }
      do {
        switch payload.setting {
        case "model":
          _ = try await store.setAIChatRemoteModel(payload.value, threadID: threadID)
        case "reasoning":
          try await store.setAIChatRemoteReasoningEffort(payload.value, threadID: threadID)
        default:
          return .error("Choose either model or reasoning to update.", statusCode: 400)
        }
        let configuration = try await store.aiChatRemoteConfiguration(for: threadID)
        let current = store.aiChatThreads.first(where: { $0.id == threadID }) ?? thread
        return .json(threadConfiguration(configuration, thread: current))
      } catch {
        return .error(error.localizedDescription, statusCode: 409)
      }
    }
    if request.method == "POST", components.count == 4, components[3] == "state" {
      guard let payload = try? request.decode(MobileRemoteUpdateThreadStateRequest.self),
            payload.isPinned != nil || payload.isSettled != nil
      else {
        return .error("Choose a pin or settlement state to update.", statusCode: 400)
      }
      guard store.updateAIChatRemoteThreadState(
        threadID: threadID,
        isPinned: payload.isPinned,
        isSettled: payload.isSettled
      ), let updated = store.aiChatThreads.first(where: { $0.id == threadID }) else {
        return .error("Thread not found.", statusCode: 404)
      }
      let context = threadProjectionContext(for: [updated], store: store)
      return await backgroundWork.jsonResponse(
        MobileRemoteThreadProjection.summary(thread: updated, context: context)
      )
    }
    if request.method == "POST", components.count == 4, components[3] == "project" {
      guard let payload = try? request.decode(MobileRemoteUpdateThreadProjectRequest.self) else {
        return .error("Choose a project membership to update.", statusCode: 400)
      }
      guard await store.setProjectMembership(
        payload.isMember,
        projectID: payload.projectID,
        threadID: threadID
      ) else {
        return .error(
          store.projectStatus.isEmpty
            ? "That project membership could not be updated."
            : store.projectStatus,
          statusCode: 409
        )
      }
      return .json(
        MobileRemoteMutationResponse(accepted: true, threadID: threadID),
        statusCode: 200
      )
    }
    if request.method == "POST", components.count == 4, components[3] == "fork" {
      guard let forkedThreadID = await store.forkAIChatThread(
        threadID,
        selectsThread: false
      ) else {
        return .error("This thread could not be forked.", statusCode: 409)
      }
      return .json(
        MobileRemoteMutationResponse(accepted: true, threadID: forkedThreadID),
        statusCode: 201
      )
    }
    if request.method == "POST", components.count == 4, components[3] == "messages" {
      let payload: MobileRemotePreparedSendMessage
      do {
        payload = try await backgroundWork.prepareSendMessage(from: request)
      } catch {
        return .error(error.localizedDescription, statusCode: 400)
      }
      guard let destinationThreadID = store.sendAIChatRemoteMessageDestination(
        payload.content,
        attachments: payload.attachments,
        threadID: threadID,
        delivery: payload.delivery.flatMap(AIChatMessageDeliveryPreference.init(rawValue:))
          ?? .automatic,
        origin: AIChatMessageProvenance(
          originClient: .mobile,
          originDeviceName: request.bearerToken.flatMap { credentialVault.device(forAccessToken: $0)?.name }
        )
      ) else {
        return .error("The message is empty or this thread is settled.", statusCode: 409)
      }
      return .json(
        MobileRemoteMutationResponse(accepted: true, threadID: destinationThreadID),
        statusCode: 202
      )
    }
    if request.method == "POST", components.count == 4, components[3] == "stop" {
      let stopped = await store.stopAIChatRemoteRun(threadID: threadID)
      return stopped
        ? .json(MobileRemoteMutationResponse(accepted: true, threadID: threadID), statusCode: 202)
        : .error("There is no live turn to stop.", statusCode: 409)
    }
    return .error("Remote action not found.", statusCode: 404)
  }

  /// `GET /v1/threads/ID/outputs` returns the files the thread edited or
  /// linked, derived exactly as the Mac's Outputs chip derives them.
  func handleThreadOutputs(threadID: UUID, store: WorkspaceStore) async -> MobileRemoteHTTPResponse {
    guard let thread = await store.hydratedAIChatThreadForDetail(threadID) else {
      return .error("This conversation could not be loaded.", statusCode: 503)
    }
    return await backgroundWork.threadOutputsResponse(
      thread: thread,
      corpusRoot: store.corpusRoot?.standardizedFileURL.path,
      remoteCorpusRoot: store.aiChatOutputsRemoteCorpusPath
    )
  }

  /// `GET|POST /v1/threads/ID/share` and `POST /v1/threads/ID/share/stop`
  /// manage the live read-only link this host serves for one thread.
  func handleThreadShare(
    _ request: MobileRemoteHTTPRequest,
    threadID: UUID,
    components: [String],
    store: WorkspaceStore
  ) async -> MobileRemoteHTTPResponse {
    func share(_ publication: LocalDocumentPublication?) -> MobileRemoteThreadShare {
      MobileRemoteThreadShare(
        threadID: threadID,
        isShared: publication != nil,
        url: publication?.url.absoluteString,
        sharedAt: publication?.createdAt
      )
    }
    switch (request.method, components.count) {
    case ("GET", 4):
      return .json(share(store.chatThreadPublication(for: threadID)))
    case ("POST", 4):
      guard store.aiChatThreads.contains(where: { $0.id == threadID }) else {
        return .error("This host doesn’t have that thread yet. Wait for the corpus to sync, then try again.", statusCode: 404)
      }
      let payload = request.body.isEmpty
        ? MobileRemoteThreadShareRequest()
        : (try? request.decode(MobileRemoteThreadShareRequest.self)) ?? MobileRemoteThreadShareRequest()
      do {
        let publication = try await store.publishChatThread(
          threadID,
          appearance: AIChatThreadShareAppearance(payload)
        )
        return .json(share(publication), statusCode: 201)
      } catch AIChatThreadPublishingError.missingThread {
        return .error("This host couldn’t load that thread for sharing.", statusCode: 404)
      } catch {
        return .error(error.localizedDescription, statusCode: 503)
      }
    case ("POST", 5) where components[4] == "stop":
      store.stopSharingChatThreadLocally(threadID)
      return .json(share(nil))
    default:
      return .error("Remote action not found.", statusCode: 404)
    }
  }

  private func handlePair(_ request: MobileRemoteHTTPRequest) -> MobileRemoteHTTPResponse {
    guard let payload = try? request.decode(MobileRemotePairRequest.self) else {
      return .error("Invalid pairing request.", statusCode: 400)
    }
    guard let pairingCode,
          let pairingExpiresAt,
          pairingExpiresAt > Date(),
          pairingCode == payload.code
    else {
      failedPairingAttempts += 1
      if failedPairingAttempts >= 10 {
        self.pairingCode = nil
        self.pairingExpiresAt = nil
        failedPairingAttempts = 0
      }
      return .error("The pairing code is invalid or expired.", statusCode: 401)
    }

    do {
      let paired = try credentialVault.pair(deviceName: payload.deviceName)
      pairedDevices = credentialVault.devices
      self.pairingCode = nil
      self.pairingExpiresAt = nil
      failedPairingAttempts = 0
      statusText = "Paired \(paired.device.name)"
      return .json(MobileRemotePairResponse(
        serverName: serverName,
        deviceID: paired.device.id,
        accessToken: paired.token
      ), statusCode: 201)
    } catch {
      return .error("Could not save the paired device.", statusCode: 500)
    }
  }

  private func refreshPushProviderState() {
    pushTeamID = pushCredentialStore.teamID
    pushKeyID = pushCredentialStore.keyID
    pushProviderConfigured = pushCredentialStore.isConfigured
    if pushProviderConfigured {
      pushStatusText = "Ready for real-time iPhone alerts"
    } else if pushTeamID.isEmpty || pushKeyID.isEmpty {
      pushStatusText = "Enter the Apple Team ID and APNs Key ID"
    } else {
      pushStatusText = "Import the APNs authentication key"
    }
    if pushProviderConfigured, store != nil {
      deliveredPushToTalkPrompts.removeAll()
      requestPushToTalkEvaluation()
    }
  }

  private func enqueuePushNotifications(
    for thread: AIChatThread,
    messages: [AIChatMessage]
  ) {
    guard pushProviderConfigured, !messages.isEmpty else { return }
    let registrations = credentialVault.pushRegistrations
    guard !registrations.isEmpty else { return }
    for message in messages {
      let visibleText = MobileRemoteMessagePreview.make(
        from: message,
        characterLimit: 220
      )?.text
      let envelope = MobileRemotePushEnvelope(
        messageID: message.id,
        threadID: thread.id,
        title: thread.title,
        body: visibleText ?? "An AI agent replied."
      )
      for registration in registrations {
        Task { [weak self] in
          guard let self else { return }
          do {
            try await self.deliverPush(envelope, to: registration.registration)
            self.pushStatusText = "Last push delivered at \(Date().formatted(date: .omitted, time: .shortened))"
          } catch let error as MobileRemotePushError {
            self.pushStatusText = error.localizedDescription
            if error.invalidatesDeviceToken {
              try? self.credentialVault.clearPushRegistration(deviceID: registration.deviceID)
              self.pairedDevices = self.credentialVault.devices
            }
          } catch {
            self.pushStatusText = error.localizedDescription
          }
        }
      }
    }
  }

  /// Reloads canonical approvals, then offers the next prompt. Use this wherever the host acts on
  /// its own (enrollment, snooze, decision, timers); the approval cache can lag the run files.
  func requestPushToTalkEvaluation() {
    Task { [weak self] in
      guard let self, let store = self.store else { return }
      if self.pushProviderConfigured || self.pushToTalkDeliveryForTesting != nil,
         !self.credentialVault.pushToTalkRegistrations.isEmpty {
        await store.refreshApprovals(clearsError: false)
      }
      self.enqueuePushToTalkApproval(from: store.approvalItems)
    }
  }

  /// Offers each enrolled, non-quiet device the next prompt it has not been pushed yet: explicitly
  /// urgent first, then oldest. A prompt that was delivered but left unanswered stays pending and
  /// listed, but no longer blocks newer prompts. Within `AudioApprovalPromptPolicy.answerWindow` of
  /// a delivery that is still pending, nothing new is pushed, so an answer is not cut off; the
  /// phone also defers a push that arrives mid-answer.
  private func enqueuePushToTalkApproval(from approvals: [ApprovalItem]) {
    guard pushProviderConfigured || pushToTalkDeliveryForTesting != nil else { return }
    let now = Date()
    snoozedAudioApprovalPrompts = snoozedAudioApprovalPrompts.filter { $0.value > now }
    let registrations = credentialVault.pushToTalkRegistrations
    let pendingKeys = Self.pendingAudioApprovalPromptKeys(in: approvals)
    deliveredPushToTalkPrompts = deliveredPushToTalkPrompts.mapValues { $0.filter { pendingKeys.contains($0.key) } }
    var wakes: [Date] = registrations.compactMap(\.registration.quietUntil).filter { $0 > now }
      + snoozedAudioApprovalPrompts.values.filter { $0 > now }
    for registration in registrations {
      if let quietUntil = registration.registration.quietUntil, quietUntil > now { continue }
      let delivered = deliveredPushToTalkPrompts[registration.deviceID] ?? [:]
      if let holdEnds = AudioApprovalPromptPolicy.holdEnds(delivered: delivered, now: now, window: pushToTalkAnswerWindow) {
        wakes.append(holdEnds)
        continue
      }
      guard let target = Self.nextAudioApprovalPrompt(
        from: approvals,
        snoozed: snoozedAudioApprovalPrompts,
        excluding: Set(delivered.keys),
        now: now
      ) else { continue }
      deliveredPushToTalkPrompts[registration.deviceID, default: [:]][target.key] = now
      wakes.append(now.addingTimeInterval(pushToTalkAnswerWindow))
      let envelope = MobileRemotePushToTalkEnvelope(
        messageID: UUID(),
        runID: target.runID,
        approvalID: target.approvalID,
        fingerprint: target.fingerprint
      )
      Task { [weak self] in
        guard let self else { return }
        do {
          try await self.deliverPushToTalk(envelope, to: registration.registration)
          self.pushStatusText = "Last audio approval push delivered at \(Date().formatted(date: .omitted, time: .shortened))"
        } catch let error as MobileRemotePushError {
          self.pushStatusText = error.localizedDescription
          self.deliveredPushToTalkPrompts[registration.deviceID]?[target.key] = nil
          if error.invalidatesDeviceToken {
            try? self.credentialVault.clearPushToTalkRegistration(deviceID: registration.deviceID)
            self.pairedDevices = self.credentialVault.devices
          }
        } catch {
          self.pushStatusText = error.localizedDescription
          self.deliveredPushToTalkPrompts[registration.deviceID]?[target.key] = nil
        }
      }
    }
    scheduleAudioApprovalWake(at: wakes.min(), now: now)
    schedulePushToTalkPoll(enabled: !registrations.isEmpty)
  }

  /// Re-evaluates when the earliest quiet period, snooze, or answer window ends.
  private func scheduleAudioApprovalWake(at wake: Date?, now: Date) {
    pushToTalkWakeTask?.cancel()
    pushToTalkWakeTask = nil
    guard let wake, wake < now.addingTimeInterval(48 * 60 * 60) else { return }
    pushToTalkWakeTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(max(1, wake.timeIntervalSinceNow + 1)))
      guard !Task.isCancelled, let self else { return }
      self.requestPushToTalkEvaluation()
    }
  }

  /// While a phone is enrolled, reread canonical approvals periodically: an approval written by
  /// another process (an agent's CLI, Syncthing) does not always reach the cache by itself.
  private func schedulePushToTalkPoll(enabled: Bool) {
    guard enabled else {
      pushToTalkPollTask?.cancel()
      pushToTalkPollTask = nil
      return
    }
    guard pushToTalkPollTask == nil else { return }
    pushToTalkPollTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(AudioApprovalPromptPolicy.canonicalRefreshInterval))
        guard !Task.isCancelled, let self else { return }
        self.requestPushToTalkEvaluation()
      }
    }
  }

  nonisolated static func pendingAudioApprovalPromptKeys(in approvals: [ApprovalItem]) -> Set<String> {
    Set(approvals.compactMap { audioApprovalPromptCandidate($0)?.target.key })
  }

  nonisolated private static func audioApprovalPromptCandidate(
    _ approval: ApprovalItem
  ) -> (target: AudioApprovalPromptTarget, urgent: Bool, requestedAt: String)? {
    guard approval.isRunApproval,
          approval.status == "pending",
          let runID = approval.runId, !runID.isEmpty,
          let approvalID = approval.approvalId, !approvalID.isEmpty,
          let fingerprint = approval.fingerprint, !fingerprint.isEmpty
    else { return nil }
    return (
      AudioApprovalPromptTarget(runID: runID, approvalID: approvalID, fingerprint: fingerprint),
      approval.isUrgent,
      approval.requestedAt ?? ""
    )
  }

  /// The next pending run approval with a complete exact identity that is neither snoozed nor
  /// excluded (already pushed to the device): explicitly urgent first, then oldest.
  nonisolated static func nextAudioApprovalPrompt(
    from approvals: [ApprovalItem],
    snoozed: [String: Date],
    excluding: Set<String> = [],
    now: Date
  ) -> AudioApprovalPromptTarget? {
    approvals
      .compactMap(audioApprovalPromptCandidate)
      .filter { candidate in
        (snoozed[candidate.target.key] ?? .distantPast) <= now && !excluding.contains(candidate.target.key)
      }
      .sorted { lhs, rhs in
        if lhs.urgent != rhs.urgent { return lhs.urgent }
        if lhs.requestedAt != rhs.requestedAt { return lhs.requestedAt < rhs.requestedAt }
        if lhs.target.runID != rhs.target.runID { return lhs.target.runID < rhs.target.runID }
        return lhs.target.approvalID < rhs.target.approvalID
      }
      .first?.target
  }

  private func deliverPush(
    _ envelope: MobileRemotePushEnvelope,
    to registration: MobileRemoteStoredPushRegistration
  ) async throws {
    let credentialStore = pushCredentialStore
    let credentials = await Task.detached(priority: .userInitiated) {
      credentialStore.credentials
    }.value
    guard let credentials else {
      throw MobileRemotePushError.deliveryFailed("APNs credentials are not configured.")
    }
    try await pushSender.send(envelope, to: registration, credentials: credentials)
  }

  private func deliverPushToTalk(
    _ envelope: MobileRemotePushToTalkEnvelope,
    to registration: MobileRemoteStoredPushToTalkRegistration
  ) async throws {
    if let pushToTalkDeliveryForTesting {
      try await pushToTalkDeliveryForTesting(envelope, registration)
      return
    }
    let credentialStore = pushCredentialStore
    let credentials = await Task.detached(priority: .userInitiated) {
      credentialStore.credentials
    }.value
    guard let credentials else {
      throw MobileRemotePushError.deliveryFailed("APNs credentials are not configured.")
    }
    try await pushSender.sendPushToTalk(envelope, to: registration, credentials: credentials)
  }

  private func threadProjectionContext(
    for threads: [AIChatThread],
    store: WorkspaceStore
  ) -> MobileRemoteThreadProjectionContext {
    var runningThreadIDs = Set<UUID>()
    var executionHostNames: [UUID: String] = [:]
    for thread in threads {
      if store.isAIChatThreadRunningOnCurrentHost(thread.id) {
        runningThreadIDs.insert(thread.id)
        executionHostNames[thread.id] = store.aiChatHostIdentity.name
      } else if let remote = store.aiChatRemoteLiveTurn(for: thread.id) {
        // A turn another host runs looks the same from every paired host.
        runningThreadIDs.insert(thread.id)
        executionHostNames[thread.id] = remote.host.name
      }
      // A remote harness (for example OpenCode over SSH) runs on its own
      // machine, not on the OpenOrg host that drove the turn.
      if let harnessHost = store.aiChatHarnessHostName(for: thread) {
        executionHostNames[thread.id] = harnessHost
      }
    }
    return MobileRemoteThreadProjectionContext(
      destinationNamesByID: store.aiChatDestinationTitlesByID,
      runningThreadIDs: runningThreadIDs,
      executionHostNamesByThreadID: executionHostNames
    )
  }

  private func mobileRemoteProjects(
    from projects: [WorkspaceProjectNote]
  ) -> [MobileRemoteProjectSummary] {
    projects.map { project in
      MobileRemoteProjectSummary(
        id: project.id,
        title: project.title,
        color: project.color,
        threadIDs: project.threadIDs.compactMap(UUID.init(uuidString:))
      )
    }
  }

  private func threadDetailProjectionContext(
    for thread: AIChatThread,
    store: WorkspaceStore
  ) -> MobileRemoteThreadDetailProjectionContext {
    let activeDestinationName = store.aiChatActiveDestinationID(for: thread.id)
      .map(store.aiChatDestinationTitle)
    if !store.isAIChatThreadRunningOnCurrentHost(thread.id),
       let remote = store.aiChatRemoteLiveTurn(for: thread.id) {
      return MobileRemoteThreadDetailProjectionContext(
        threads: threadProjectionContext(for: [thread], store: store),
        activeDestinationName: remote.turn.destinationName ?? activeDestinationName,
        streamingReply: remote.turn.streamingReply,
        reasoning: remote.turn.reasoning,
        activities: remote.turn.activities,
        connectionState: OpenClawGatewayConnectionState.connected.rawValue,
        connectionDetail: "Running on \(store.aiChatHarnessHostName(for: thread.id) ?? remote.host.name)"
      )
    }
    let livePresentation = store.aiChatLivePresentationSnapshot(for: thread.id)
    return MobileRemoteThreadDetailProjectionContext(
      threads: threadProjectionContext(for: [thread], store: store),
      activeDestinationName: activeDestinationName,
      streamingReply: livePresentation.streamingReply,
      reasoning: livePresentation.reasoning,
      activities: store.aiChatRunActivities(for: thread.id),
      connectionState: store.aiChatConnectionState(for: thread.id).rawValue,
      connectionDetail: store.aiChatConnectionDetail(for: thread.id)
    )
  }

  public var serverName: String {
    configuredServerName ?? Host.current().localizedName ?? "Celorga on Mac"
  }

  private func threadConfiguration(
    _ configuration: AIChatRemoteConfiguration,
    thread: AIChatThread
  ) -> MobileRemoteThreadConfiguration {
    MobileRemoteThreadConfiguration(
      threadID: thread.id,
      model: thread.model,
      models: configuration.models.map {
        MobileRemoteModelOption(
          id: $0.id,
          label: $0.label,
          detail: $0.detail,
          isDefault: $0.isDefault
        )
      },
      reasoningEffort: thread.reasoningEffort,
      reasoningOptions: configuration.reasoningOptions.map {
        MobileRemoteReasoningOption(id: $0.id, label: $0.label, detail: $0.detail)
      },
      defaultReasoningEffort: configuration.defaultReasoningEffort
    )
  }

  nonisolated public static func isTailscaleIPv4(_ address: String) -> Bool {
    let parts = address.split(separator: ".").compactMap { UInt8($0) }
    guard parts.count == 4 else { return false }
    return parts[0] == 100 && (64...127).contains(parts[1])
  }

  nonisolated public static func tailscaleIPv4Addresses() -> [String] {
    var firstAddress: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
    defer { freeifaddrs(firstAddress) }

    var results: [String] = []
    var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress
    while let current = cursor {
      defer { cursor = current.pointee.ifa_next }
      guard let address = current.pointee.ifa_addr,
            address.pointee.sa_family == UInt8(AF_INET)
      else {
        continue
      }
      var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let length = socklen_t(address.pointee.sa_len)
      guard getnameinfo(address, length, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
        continue
      }
      let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      let value = String(decoding: bytes, as: UTF8.self)
      if isTailscaleIPv4(value), !results.contains(value) {
        results.append(value)
      }
    }
    return results.sorted()
  }
}

final class MobileRemoteCredentialVault {
  struct PushTarget: Sendable {
    let deviceID: UUID
    let registration: MobileRemoteStoredPushRegistration
  }

  struct PushToTalkTarget: Sendable {
    let deviceID: UUID
    let registration: MobileRemoteStoredPushToTalkRegistration
  }

  private struct Record: Codable {
    let device: MobileRemotePairedDevice
    let token: String
    var pushRegistration: MobileRemoteStoredPushRegistration?
    var pushToTalkRegistration: MobileRemoteStoredPushToTalkRegistration?
  }

  private let service: String
  private let credentialFile: URL?
  private var credentialReadFailed = false
  private let account = "paired-devices"
  private var records: [Record]

  init(credentialNamespace: String? = nil, credentialFile: URL? = nil) {
    service = (credentialNamespace ?? Bundle.main.bundleIdentifier ?? "org.org2.workspace") + ".mobile-remote"
    self.credentialFile = credentialFile
    records = []
    records = load()
  }

  public var devices: [MobileRemotePairedDevice] {
    records.map { record in
      MobileRemotePairedDevice(
        id: record.device.id,
        name: record.device.name,
        pairedAt: record.device.pairedAt,
        pushRegisteredAt: [record.pushRegistration?.registeredAt, record.pushToTalkRegistration?.registeredAt]
          .compactMap { $0 }
          .max()
      )
    }.sorted { $0.pairedAt > $1.pairedAt }
  }

  public var pushRegistrations: [PushTarget] {
    records.compactMap { record in
      record.pushRegistration.map {
        PushTarget(deviceID: record.device.id, registration: $0)
      }
    }
  }

  public var pushToTalkRegistrations: [PushToTalkTarget] {
    records.compactMap { record in
      record.pushToTalkRegistration.map {
        PushToTalkTarget(deviceID: record.device.id, registration: $0)
      }
    }
  }

  func deviceID(forAccessToken accessToken: String) -> UUID? {
    records.first(where: { Self.securelyEqual($0.token, storedToken(accessToken)) })?.device.id
  }

  public func contains(token: String) -> Bool {
    records.contains { Self.securelyEqual($0.token, storedToken(token)) }
  }

  public func device(forAccessToken token: String) -> MobileRemotePairedDevice? {
    records.first { Self.securelyEqual($0.token, storedToken(token)) }?.device
  }

  public func pair(deviceName rawName: String) throws -> (device: MobileRemotePairedDevice, token: String) {
    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    let device = MobileRemotePairedDevice(
      id: UUID(),
      name: String((name.isEmpty ? "iPhone" : name).prefix(80)),
      pairedAt: Date()
    )
    let token = try Self.randomToken()
    records.append(Record(
      device: device,
      token: storedToken(token),
      pushRegistration: nil,
      pushToTalkRegistration: nil
    ))
    do {
      try save()
    } catch {
      records.removeAll { $0.device.id == device.id }
      throw error
    }
    return (device, token)
  }

  public func setPushRegistration(
    _ request: MobileRemotePushRegistrationRequest,
    forAccessToken accessToken: String
  ) throws -> Bool {
    guard let index = records.firstIndex(where: { Self.securelyEqual($0.token, storedToken(accessToken)) }) else {
      throw MobileRemoteCredentialError.unknownDevice
    }
    let previous = records[index].pushRegistration
    if request.enabled {
      guard let deviceToken = request.deviceToken?.lowercased(),
            !deviceToken.isEmpty,
            deviceToken.count <= 512,
            deviceToken.allSatisfy(\.isHexDigit),
            let environment = request.environment,
            environment == "production" || environment == "sandbox"
      else {
        throw MobileRemoteCredentialError.invalidPushRegistration
      }
      records[index].pushRegistration = MobileRemoteStoredPushRegistration(
        deviceToken: deviceToken,
        environment: environment
      )
    } else {
      records[index].pushRegistration = nil
    }
    do {
      try save()
    } catch {
      records[index].pushRegistration = previous
      throw error
    }
    return records[index].pushRegistration != nil
  }

  public func pushRegistration(forAccessToken accessToken: String) -> PushTarget? {
    records.first(where: { Self.securelyEqual($0.token, storedToken(accessToken)) }).flatMap { record in
      record.pushRegistration.map {
        PushTarget(deviceID: record.device.id, registration: $0)
      }
    }
  }

  public func setPushToTalkRegistration(
    _ request: MobileRemotePushToTalkRegistrationRequest,
    forAccessToken accessToken: String
  ) throws -> Bool {
    guard let index = records.firstIndex(where: { Self.securelyEqual($0.token, storedToken(accessToken)) }) else {
      throw MobileRemoteCredentialError.unknownDevice
    }
    let previous = records[index].pushToTalkRegistration
    if request.enabled {
      guard let pushToken = request.pushToken?.lowercased(),
            !pushToken.isEmpty,
            pushToken.count <= 512,
            pushToken.allSatisfy(\.isHexDigit),
            let environment = request.environment,
            environment == "production" || environment == "sandbox"
      else {
        throw MobileRemoteCredentialError.invalidPushRegistration
      }
      records[index].pushToTalkRegistration = MobileRemoteStoredPushToTalkRegistration(
        pushToken: pushToken,
        environment: environment,
        quietUntil: request.quietUntil
      )
    } else {
      records[index].pushToTalkRegistration = nil
    }
    do {
      try save()
    } catch {
      records[index].pushToTalkRegistration = previous
      throw error
    }
    return records[index].pushToTalkRegistration != nil
  }

  public func clearPushRegistration(deviceID: UUID) throws {
    guard let index = records.firstIndex(where: { $0.device.id == deviceID }) else { return }
    let previous = records[index].pushRegistration
    records[index].pushRegistration = nil
    do {
      try save()
    } catch {
      records[index].pushRegistration = previous
      throw error
    }
  }

  public func clearPushToTalkRegistration(deviceID: UUID) throws {
    guard let index = records.firstIndex(where: { $0.device.id == deviceID }) else { return }
    let previous = records[index].pushToTalkRegistration
    records[index].pushToTalkRegistration = nil
    do {
      try save()
    } catch {
      records[index].pushToTalkRegistration = previous
      throw error
    }
  }

  public func revoke(_ id: UUID) throws {
    let previous = records
    records.removeAll { $0.device.id == id }
    do {
      try save()
    } catch {
      records = previous
      throw error
    }
  }

  public func revokeAll() throws {
    let previous = records
    records = []
    do {
      try save()
    } catch {
      records = previous
      throw error
    }
  }

  private func load() -> [Record] {
    if let credentialFile {
      guard FileManager.default.fileExists(atPath: credentialFile.path) else { return [] }
      do {
        return try MobileRemoteProtocol.decoder().decode([Record].self, from: Data(contentsOf: credentialFile))
      } catch {
        credentialReadFailed = true
        return []
      }
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    var item: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
          let data = item as? Data
    else {
      return []
    }
    return (try? MobileRemoteProtocol.decoder().decode([Record].self, from: data)) ?? []
  }

  private func save() throws {
    guard !credentialReadFailed else { throw CocoaError(.fileReadCorruptFile) }
    let data = try MobileRemoteProtocol.encoder().encode(records)
    if let credentialFile {
      try data.write(to: credentialFile, options: [.atomic])
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: credentialFile.path)
      return
    }
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
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
      guard added == errSecSuccess else { throw MobileRemoteCredentialError.keychain(added) }
    } else if status != errSecSuccess {
      throw MobileRemoteCredentialError.keychain(status)
    }
  }

  private static func randomToken() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    let status = bytes.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else { throw MobileRemoteCredentialError.keychain(status) }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private func storedToken(_ token: String) -> String {
    // Headless login sessions may not have an unlocked Keychain. Persist only
    // token hashes inside the CLI's private state directory; iOS keeps its
    // actual credential in Keychain. Desktop credential storage is unchanged.
    guard credentialFile != nil else { return token }
    return SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func securelyEqual(_ lhs: String, _ rhs: String) -> Bool {
    let left = Array(lhs.utf8)
    let right = Array(rhs.utf8)
    guard left.count == right.count else { return false }
    return zip(left, right).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
  }
}

private enum MobileRemoteCredentialError: LocalizedError {
  case keychain(OSStatus)
  case invalidPushRegistration
  case unknownDevice

  public var errorDescription: String? {
    switch self {
    case .keychain(let status):
      "Keychain error \(status)"
    case .invalidPushRegistration:
      "The iPhone supplied an invalid push registration."
    case .unknownDevice:
      "Pair this device with this host again."
    }
  }
}

/// Timing for walkie-talkie prompts on the host.
enum AudioApprovalPromptPolicy {
  /// After a push, nothing new is pushed to that device for this long while it is still pending.
  /// The phone separately defers a push that arrives while an answer is in progress.
  static let answerWindow: TimeInterval = 30
  /// How often canonical approvals are reread while a phone is enrolled.
  static let canonicalRefreshInterval: TimeInterval = 60

  /// When the answer window of the most recent still-pending delivery ends, if it has not yet.
  static func holdEnds(delivered: [String: Date], now: Date, window: TimeInterval = answerWindow) -> Date? {
    guard let last = delivered.values.max() else { return nil }
    let ends = last.addingTimeInterval(window)
    return ends > now ? ends : nil
  }
}

/// The exact identity one audio approval prompt is bound to.
struct AudioApprovalPromptTarget: Hashable, Sendable {
  let runID: String
  let approvalID: String
  let fingerprint: String

  var key: String { "\(runID)|\(approvalID)|\(fingerprint)" }
}
