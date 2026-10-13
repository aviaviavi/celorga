import Foundation

public enum MobileRemoteProtocol {
  public static let version = 2
  public static let defaultPort: UInt16 = 48_922

  public static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }

  public static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

public struct MobileRemoteServerStatus: Codable, Hashable, Sendable {
  public let protocolVersion: Int
  public let serverName: String
  public let hostRef: String?
  public let hostKind: String?
  public let corpusName: String?
  public let threadCount: Int
  public let runningThreadCount: Int
  public let aiChatDestinations: [MobileRemoteAIDestination]?
  public let pushNotificationsSupported: Bool?
  public let pushNotificationsConfigured: Bool?
  /// The host accepts a client-chosen `threadID` when creating a chat, so the
  /// phone can open the new thread before the round trip completes.
  public let supportsClientThreadIDs: Bool?
  /// The host can publish a live read-only link for a thread it stores.
  public let supportsThreadSharing: Bool?
  /// The host serves `GET /v1/threads/ID/outputs`.
  public let supportsThreadOutputs: Bool?

  public init(
    protocolVersion: Int = MobileRemoteProtocol.version,
    serverName: String,
    hostRef: String? = nil,
    hostKind: String? = nil,
    corpusName: String?,
    threadCount: Int,
    runningThreadCount: Int,
    aiChatDestinations: [MobileRemoteAIDestination]? = nil,
    pushNotificationsSupported: Bool? = nil,
    pushNotificationsConfigured: Bool? = nil,
    supportsClientThreadIDs: Bool? = true,
    supportsThreadSharing: Bool? = true,
    supportsThreadOutputs: Bool? = true
  ) {
    self.supportsThreadOutputs = supportsThreadOutputs
    self.supportsClientThreadIDs = supportsClientThreadIDs
    self.supportsThreadSharing = supportsThreadSharing
    self.protocolVersion = protocolVersion
    self.serverName = serverName
    self.hostRef = hostRef
    self.hostKind = hostKind
    self.corpusName = corpusName
    self.threadCount = threadCount
    self.runningThreadCount = runningThreadCount
    self.aiChatDestinations = aiChatDestinations
    self.pushNotificationsSupported = pushNotificationsSupported
    self.pushNotificationsConfigured = pushNotificationsConfigured
  }
}

public struct MobileRemotePushRegistrationRequest: Codable, Hashable, Sendable {
  public let deviceToken: String?
  public let environment: String?
  public let enabled: Bool

  public init(deviceToken: String?, environment: String?, enabled: Bool) {
    self.deviceToken = deviceToken
    self.environment = environment
    self.enabled = enabled
  }
}

public struct MobileRemotePushRegistrationResponse: Codable, Hashable, Sendable {
  public let enabled: Bool
  public let providerConfigured: Bool

  public init(enabled: Bool, providerConfigured: Bool) {
    self.enabled = enabled
    self.providerConfigured = providerConfigured
  }
}

public struct MobileRemotePushToTalkRegistrationRequest: Codable, Hashable, Sendable {
  public let pushToken: String?
  public let environment: String?
  public let enabled: Bool
  /// Quiet or snoozed until this time. The host sends no audio approval pushes
  /// to this device before then. `nil` means prompts are allowed.
  public let quietUntil: Date?

  public init(pushToken: String?, environment: String?, enabled: Bool, quietUntil: Date? = nil) {
    self.pushToken = pushToken
    self.environment = environment
    self.enabled = enabled
    self.quietUntil = quietUntil
  }
}

/// "Later" for one exact prompt. The host skips this exact approval until `until`
/// and moves on to the next pending approval, so a snooze never blocks other agents.
public struct MobileRemoteAudioApprovalSnoozeRequest: Codable, Hashable, Sendable {
  public let runID: String
  public let approvalID: String
  public let fingerprint: String
  public let until: Date

  public init(runID: String, approvalID: String, fingerprint: String, until: Date) {
    self.runID = runID
    self.approvalID = approvalID
    self.fingerprint = fingerprint
    self.until = until
  }
}

public struct MobileRemoteAudioApprovalSnoozeResponse: Codable, Hashable, Sendable {
  public let snoozedUntil: Date

  public init(snoozedUntil: Date) {
    self.snoozedUntil = snoozedUntil
  }
}

public struct MobileRemotePushToTalkRegistrationResponse: Codable, Hashable, Sendable {
  public let enabled: Bool
  public let providerConfigured: Bool

  public init(enabled: Bool, providerConfigured: Bool) {
    self.enabled = enabled
    self.providerConfigured = providerConfigured
  }
}

public struct MobileRemoteAIDestination: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let name: String
  public let mention: String
  public let runtime: String

  public init(id: String, name: String, mention: String, runtime: String) {
    self.id = id
    self.name = name
    self.mention = mention
    self.runtime = runtime
  }
}

public struct MobileRemotePairRequest: Codable, Hashable, Sendable {
  public let code: String
  public let deviceName: String

  public init(code: String, deviceName: String) {
    self.code = code
    self.deviceName = deviceName
  }
}

public struct MobileRemotePairResponse: Codable, Hashable, Sendable {
  public let protocolVersion: Int
  public let serverName: String
  public let deviceID: UUID
  public let accessToken: String

  public init(
    protocolVersion: Int = MobileRemoteProtocol.version,
    serverName: String,
    deviceID: UUID,
    accessToken: String
  ) {
    self.protocolVersion = protocolVersion
    self.serverName = serverName
    self.deviceID = deviceID
    self.accessToken = accessToken
  }
}

public struct MobileRemoteCreateThreadRequest: Codable, Hashable, Sendable {
  public let runtime: String
  public let destinationID: String?
  public let projectID: String?
  public let threadID: UUID?

  public init(
    runtime: String,
    destinationID: String? = nil,
    projectID: String? = nil,
    threadID: UUID? = nil
  ) {
    self.runtime = runtime
    self.destinationID = destinationID
    self.projectID = projectID
    self.threadID = threadID
  }
}

public struct MobileRemoteUpdateThreadProjectRequest: Codable, Hashable, Sendable {
  public let projectID: String
  public let isMember: Bool

  public init(projectID: String, isMember: Bool) {
    self.projectID = projectID
    self.isMember = isMember
  }
}

public struct MobileRemoteSendMessageRequest: Codable, Hashable, Sendable {
  public let content: String
  public let attachments: [MobileRemoteAttachment]
  public let delivery: String?

  public init(
    content: String,
    attachments: [MobileRemoteAttachment] = [],
    delivery: String? = nil
  ) {
    self.content = content
    self.attachments = attachments
    self.delivery = delivery
  }
}

public struct MobileRemoteAttachment: Codable, Hashable, Sendable {
  public let fileName: String
  public let mimeType: String
  public let data: Data

  public init(fileName: String, mimeType: String, data: Data) {
    self.fileName = fileName
    self.mimeType = mimeType
    self.data = data
  }
}

public struct MobileRemoteFilePreviewRequest: Codable, Hashable, Sendable {
  public let path: String
  public let line: Int?

  public init(path: String, line: Int? = nil) {
    self.path = path
    self.line = line
  }
}

public struct MobileRemoteImageRequest: Codable, Hashable, Sendable {
  public let path: String

  public init(path: String) {
    self.path = path
  }
}

/// Image bytes travel base64-encoded through JSON's default `Data` strategy.
public struct MobileRemoteImage: Codable, Hashable, Sendable {
  public let relativePath: String
  public let mimeType: String
  public let data: Data

  public init(relativePath: String, mimeType: String, data: Data) {
    self.relativePath = relativePath
    self.mimeType = mimeType
    self.data = data
  }
}

public struct MobileRemoteFilePreview: Codable, Hashable, Sendable {
  public let title: String
  public let relativePath: String
  public let startLine: Int
  public let highlightedLine: Int?
  public let content: String

  public init(
    title: String,
    relativePath: String,
    startLine: Int,
    highlightedLine: Int?,
    content: String
  ) {
    self.title = title
    self.relativePath = relativePath
    self.startLine = startLine
    self.highlightedLine = highlightedLine
    self.content = content
  }
}

public struct MobileRemoteModelOption: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let detail: String?
  public let isDefault: Bool

  public init(id: String, label: String, detail: String?, isDefault: Bool) {
    self.id = id
    self.label = label
    self.detail = detail
    self.isDefault = isDefault
  }
}

public struct MobileRemoteThreadConfiguration: Codable, Hashable, Sendable {
  public let threadID: UUID
  public let model: String?
  public let models: [MobileRemoteModelOption]
  public let reasoningEffort: String?
  public let reasoningOptions: [MobileRemoteReasoningOption]
  public let defaultReasoningEffort: String?

  public init(
    threadID: UUID,
    model: String?,
    models: [MobileRemoteModelOption],
    reasoningEffort: String?,
    reasoningOptions: [MobileRemoteReasoningOption],
    defaultReasoningEffort: String?
  ) {
    self.threadID = threadID
    self.model = model
    self.models = models
    self.reasoningEffort = reasoningEffort
    self.reasoningOptions = reasoningOptions
    self.defaultReasoningEffort = defaultReasoningEffort
  }
}

public struct MobileRemoteUpdateThreadConfigurationRequest: Codable, Hashable, Sendable {
  public let setting: String
  public let value: String?

  public init(model: String?) {
    setting = "model"
    value = model
  }

  public init(reasoningEffort: String?) {
    setting = "reasoning"
    value = reasoningEffort
  }
}

public struct MobileRemoteReasoningOption: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let detail: String?

  public init(id: String, label: String, detail: String?) {
    self.id = id
    self.label = label
    self.detail = detail
  }
}

public struct MobileRemoteUpdateThreadStateRequest: Codable, Hashable, Sendable {
  public let isPinned: Bool?
  public let isSettled: Bool?

  public init(isPinned: Bool? = nil, isSettled: Bool? = nil) {
    self.isPinned = isPinned
    self.isSettled = isSettled
  }
}

public struct MobileRemoteThreadList: Codable, Hashable, Sendable {
  public let threads: [MobileRemoteThreadSummary]
  public let projects: [MobileRemoteProjectSummary]?

  public init(
    threads: [MobileRemoteThreadSummary],
    projects: [MobileRemoteProjectSummary]? = nil
  ) {
    self.threads = threads
    self.projects = projects
  }
}

public struct MobileRemoteProjectSummary: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let color: String
  public let threadIDs: [UUID]

  public init(id: String, title: String, color: String, threadIDs: [UUID]) {
    self.id = id
    self.title = title
    self.color = color
    self.threadIDs = threadIDs
  }

  public func contains(_ threadID: UUID) -> Bool {
    threadIDs.contains(threadID)
  }
}

public struct MobileRemoteThreadSummary: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let title: String
  public let runtime: String
  public let destinationID: String?
  public let destinationName: String?
  public let isSharedRoom: Bool
  public let model: String?
  public let updatedAt: Date
  public let isSettled: Bool
  public let isPinned: Bool
  public let isRunning: Bool
  public let unreadMessageCount: Int
  public let preview: String?
  public let latestAssistantMessageID: UUID?
  public let latestAssistantPreview: String?
  /// The host running (or that last ran) the conversation, e.g. "OpenOrg on press".
  public let executionHostName: String?

  public init(
    id: UUID,
    title: String,
    runtime: String,
    destinationID: String? = nil,
    destinationName: String? = nil,
    isSharedRoom: Bool = false,
    model: String?,
    updatedAt: Date,
    isSettled: Bool,
    isPinned: Bool,
    isRunning: Bool,
    unreadMessageCount: Int,
    preview: String?,
    latestAssistantMessageID: UUID? = nil,
    latestAssistantPreview: String? = nil,
    executionHostName: String? = nil
  ) {
    self.id = id
    self.title = title
    self.runtime = runtime
    self.destinationID = destinationID
    self.destinationName = destinationName
    self.isSharedRoom = isSharedRoom
    self.model = model
    self.updatedAt = updatedAt
    self.isSettled = isSettled
    self.isPinned = isPinned
    self.isRunning = isRunning
    self.unreadMessageCount = unreadMessageCount
    self.preview = preview
    self.latestAssistantMessageID = latestAssistantMessageID
    self.latestAssistantPreview = latestAssistantPreview
    self.executionHostName = executionHostName
  }
}

public struct MobileRemoteThreadDetail: Codable, Hashable, Sendable {
  public let thread: MobileRemoteThreadSummary
  public let messages: [MobileRemoteChatMessage]
  public let activeDestinationName: String?
  public let streamingReply: String
  public let reasoning: String
  public let activities: [MobileRemoteActivity]
  public let connectionState: String
  public let connectionDetail: String?

  public init(
    thread: MobileRemoteThreadSummary,
    messages: [MobileRemoteChatMessage],
    activeDestinationName: String? = nil,
    streamingReply: String,
    reasoning: String,
    activities: [MobileRemoteActivity],
    connectionState: String,
    connectionDetail: String?
  ) {
    self.thread = thread
    self.messages = messages
    self.activeDestinationName = activeDestinationName
    self.streamingReply = streamingReply
    self.reasoning = reasoning
    self.activities = activities
    self.connectionState = connectionState
    self.connectionDetail = connectionDetail
  }
}

public struct MobileRemoteChatMessage: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let role: String
  public let content: String
  public let attachmentNames: [String]
  public let createdAt: Date
  public let deliveryStatus: String
  public let deliveryKind: String?
  public let sendFailure: String?
  public let authorRuntime: String?
  public let authorDestinationID: String?
  public let authorDestinationName: String?
  public let audience: String?
  public let audienceDestinationNames: [String]?
  public let isRoomDispatchCopy: Bool
  public let roomRoundID: UUID?
  /// Where the message came from and which host handled it, e.g.
  /// "Avi's iPhone via OpenOrg on press · runs on AiroPress".
  public let provenanceCaption: String?
  public let originClient: String?
  public let originDeviceName: String?
  public let receivedByHostName: String?
  public let executionHostName: String?

  public init(
    id: UUID,
    role: String,
    content: String,
    attachmentNames: [String],
    createdAt: Date,
    deliveryStatus: String,
    deliveryKind: String? = nil,
    sendFailure: String?,
    authorRuntime: String? = nil,
    authorDestinationID: String? = nil,
    authorDestinationName: String? = nil,
    audience: String? = nil,
    audienceDestinationNames: [String]? = nil,
    isRoomDispatchCopy: Bool = false,
    roomRoundID: UUID? = nil,
    provenanceCaption: String? = nil,
    originClient: String? = nil,
    originDeviceName: String? = nil,
    receivedByHostName: String? = nil,
    executionHostName: String? = nil
  ) {
    self.provenanceCaption = provenanceCaption
    self.originClient = originClient
    self.originDeviceName = originDeviceName
    self.receivedByHostName = receivedByHostName
    self.executionHostName = executionHostName
    self.id = id
    self.role = role
    self.content = content
    self.attachmentNames = attachmentNames
    self.createdAt = createdAt
    self.deliveryStatus = deliveryStatus
    self.deliveryKind = deliveryKind
    self.sendFailure = sendFailure
    self.authorRuntime = authorRuntime
    self.authorDestinationID = authorDestinationID
    self.authorDestinationName = authorDestinationName
    self.audience = audience
    self.audienceDestinationNames = audienceDestinationNames
    self.isRoomDispatchCopy = isRoomDispatchCopy
    self.roomRoundID = roomRoundID
  }
}

public struct MobileRemoteActivity: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let detail: String?
  public let status: String
  public let updatedAt: Date

  public init(id: String, title: String, detail: String?, status: String, updatedAt: Date) {
    self.id = id
    self.title = title
    self.detail = detail
    self.status = status
    self.updatedAt = updatedAt
  }
}

public enum MobileRemoteActivityPresentation {
  public static func items(from activities: [AIChatRunActivity]) -> [MobileRemoteActivity] {
    AIChatActivityFeed.items(from: activities).map { item in
      MobileRemoteActivity(
        id: item.id,
        title: item.title,
        detail: item.detail,
        status: item.status.rawValue,
        updatedAt: item.updatedAt
      )
    }
  }
}

public struct MobileRemoteMutationResponse: Codable, Hashable, Sendable {
  public let accepted: Bool
  public let threadID: UUID?

  public init(accepted: Bool, threadID: UUID? = nil) {
    self.accepted = accepted
    self.threadID = threadID
  }
}

/// Appearance a client asks the host to use for a shared thread page, so a
/// link hosted elsewhere still looks like the sharer's OpenOrg.
public struct MobileRemoteThreadShareRequest: Codable, Hashable, Sendable {
  public let appearanceMode: String?
  public let lightThemeID: String?
  public let darkThemeID: String?

  public init(appearanceMode: String? = nil, lightThemeID: String? = nil, darkThemeID: String? = nil) {
    self.appearanceMode = appearanceMode
    self.lightThemeID = lightThemeID
    self.darkThemeID = darkThemeID
  }
}

/// The host's live link for one thread. `url` is a bearer secret.
public struct MobileRemoteThreadShare: Codable, Hashable, Sendable {
  public let threadID: UUID
  public let isShared: Bool
  public let url: String?
  public let sharedAt: Date?

  public init(threadID: UUID, isShared: Bool, url: String? = nil, sharedAt: Date? = nil) {
    self.threadID = threadID
    self.isShared = isShared
    self.url = url
    self.sharedAt = sharedAt
  }
}

/// `GET /v1/threads/ID/outputs`: the files a thread edited or linked, as shown
/// by the Mac's AI chat Outputs chip. File paths are corpus-relative when the
/// file lives in the host corpus, so the phone can open its synced copy first.
public struct MobileRemoteThreadOutputs: Codable, Hashable, Sendable {
  public let threadID: UUID
  public let folderName: String?
  public let folderDisplayPath: String?
  public let isTruncated: Bool
  public let maxGroups: Int
  public let groups: [MobileRemoteThreadOutputGroup]

  public init(
    threadID: UUID,
    folderName: String?,
    folderDisplayPath: String?,
    isTruncated: Bool,
    maxGroups: Int,
    groups: [MobileRemoteThreadOutputGroup]
  ) {
    self.threadID = threadID
    self.folderName = folderName
    self.folderDisplayPath = folderDisplayPath
    self.isTruncated = isTruncated
    self.maxGroups = maxGroups
    self.groups = groups
  }
}

public struct MobileRemoteThreadOutputGroup: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let isInFolder: Bool
  public let exists: Bool
  public let wasCreated: Bool
  public let editCount: Int
  public let linkCount: Int
  public let activitySummary: String
  public let staleFormats: [String]
  public let lastMessageID: UUID?
  public let files: [MobileRemoteThreadOutputFile]

  public init(
    id: String,
    title: String,
    isInFolder: Bool,
    exists: Bool,
    wasCreated: Bool,
    editCount: Int,
    linkCount: Int,
    activitySummary: String,
    staleFormats: [String],
    lastMessageID: UUID?,
    files: [MobileRemoteThreadOutputFile]
  ) {
    self.id = id
    self.title = title
    self.isInFolder = isInFolder
    self.exists = exists
    self.wasCreated = wasCreated
    self.editCount = editCount
    self.linkCount = linkCount
    self.activitySummary = activitySummary
    self.staleFormats = staleFormats
    self.lastMessageID = lastMessageID
    self.files = files
  }
}

public struct MobileRemoteThreadOutputFile: Codable, Hashable, Identifiable, Sendable {
  /// Corpus-relative when inside the host corpus, otherwise the host's absolute path.
  public let path: String
  public let displayPath: String
  public let fileExtension: String
  public let isInCorpus: Bool
  public let exists: Bool
  public let isSibling: Bool
  public let isPrimary: Bool
  public let isStale: Bool

  public var id: String { path }

  public init(
    path: String,
    displayPath: String,
    fileExtension: String,
    isInCorpus: Bool,
    exists: Bool,
    isSibling: Bool,
    isPrimary: Bool,
    isStale: Bool
  ) {
    self.path = path
    self.displayPath = displayPath
    self.fileExtension = fileExtension
    self.isInCorpus = isInCorpus
    self.exists = exists
    self.isSibling = isSibling
    self.isPrimary = isPrimary
    self.isStale = isStale
  }
}

public struct MobileRemoteWorkspaceSnapshot: Codable, Hashable, Sendable {
  public let updatedAt: Date
  public let agenda: [MobileRemoteAgendaItem]
  public let approvals: [MobileRemoteApprovalItem]
  public let workflows: [MobileRemoteWorkflowItem]
  public let approvalDecisionReceipt: MobileRemoteApprovalDecisionReceipt?

  public init(
    updatedAt: Date = Date(),
    agenda: [MobileRemoteAgendaItem],
    approvals: [MobileRemoteApprovalItem],
    workflows: [MobileRemoteWorkflowItem],
    approvalDecisionReceipt: MobileRemoteApprovalDecisionReceipt? = nil
  ) {
    self.updatedAt = updatedAt
    self.agenda = agenda
    self.approvals = approvals
    self.workflows = workflows
    self.approvalDecisionReceipt = approvalDecisionReceipt
  }
}

/// What the host did with an exact decision, read back from the durable run after the
/// decision and any agent continuation. The phone acknowledges this, not its own request.
public struct MobileRemoteApprovalDecisionReceipt: Codable, Hashable, Sendable {
  public let runID: String
  public let approvalID: String
  public let decision: String
  public let runStatus: String
  public let pendingApprovalCount: Int
  /// One of `MobileRemoteApprovalContinuation`'s raw values.
  public let continuation: String
  /// The provenance key recorded on the approval, when the client supplied one.
  public let receipt: String?
  /// True when this request replayed a decision that was already recorded with the same receipt.
  public let duplicate: Bool

  public init(
    runID: String,
    approvalID: String,
    decision: String,
    runStatus: String,
    pendingApprovalCount: Int,
    continuation: String,
    receipt: String? = nil,
    duplicate: Bool = false
  ) {
    self.runID = runID
    self.approvalID = approvalID
    self.decision = decision
    self.runStatus = runStatus
    self.pendingApprovalCount = pendingApprovalCount
    self.continuation = continuation
    self.receipt = receipt
    self.duplicate = duplicate
  }
}

/// How the requesting agent learns about a decision.
public enum MobileRemoteApprovalContinuation: String, Codable, Sendable {
  /// The host resumed the requesting agent's session.
  case continued
  /// The requesting agent was already resumed for this decision.
  case alreadyContinuing = "already-continuing"
  /// Resuming the agent failed; the run is durably blocked with the reason.
  case continuationFailedBlocked = "continuation-failed-blocked"
  /// Resuming the agent failed and the block could not be recorded.
  case continuationFailed = "continuation-failed"
  /// A requested revision was handed back to the workflow.
  case revisionContinuing = "revision-continuing"
  /// The run still waits on other approvals on the same boundary.
  case awaitingOtherApprovals = "awaiting-other-approvals"
  /// Recorded in the durable run; the requesting agent reads it with `run wait` or `run show`.
  case recorded
}

public struct MobileRemoteAgendaItem: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let todo: String
  public let file: String
  public let line: Int
  public let date: String
  public let kind: String
  public let tags: [String]
  public let body: String
  public let priority: String?
  public let time: String?
  public let effort: String?

  public init(
    id: String,
    title: String,
    todo: String,
    file: String,
    line: Int,
    date: String,
    kind: String,
    tags: [String],
    body: String,
    priority: String?,
    time: String?,
    effort: String?
  ) {
    self.id = id
    self.title = title
    self.todo = todo
    self.file = file
    self.line = line
    self.date = date
    self.kind = kind
    self.tags = tags
    self.body = body
    self.priority = priority
    self.time = time
    self.effort = effort
  }
}

public struct MobileRemoteApprovalItem: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let status: String
  public let todo: String?
  public let level: Int?
  public let file: String
  public let line: Int
  public let sourceID: String?
  public let properties: [String: String]
  public let body: String
  public let tags: [String]
  public let kind: String?
  public let runID: String?
  public let approvalID: String?
  public let fingerprint: String?
  public let action: String?
  public let riskClass: String?
  public let requestedRole: String?
  public let requestedFrom: String?
  public let requestedAt: String?
  public let runGoal: String?
  public let runStatus: String?
  public let runDecisionEffect: String?
  public let priority: String?

  public init(
    id: String,
    title: String,
    status: String,
    todo: String?,
    level: Int?,
    file: String,
    line: Int,
    sourceID: String?,
    properties: [String: String],
    body: String,
    tags: [String],
    kind: String?,
    runID: String?,
    approvalID: String?,
    fingerprint: String?,
    action: String?,
    riskClass: String?,
    requestedRole: String?,
    requestedFrom: String?,
    requestedAt: String?,
    runGoal: String?,
    runStatus: String?,
    runDecisionEffect: String?,
    priority: String? = nil
  ) {
    self.id = id
    self.title = title
    self.status = status
    self.todo = todo
    self.level = level
    self.file = file
    self.line = line
    self.sourceID = sourceID
    self.properties = properties
    self.body = body
    self.tags = tags
    self.kind = kind
    self.runID = runID
    self.approvalID = approvalID
    self.fingerprint = fingerprint
    self.action = action
    self.riskClass = riskClass
    self.requestedRole = requestedRole
    self.requestedFrom = requestedFrom
    self.requestedAt = requestedAt
    self.runGoal = runGoal
    self.runStatus = runStatus
    self.runDecisionEffect = runDecisionEffect
    self.priority = priority
  }
}

public struct MobileRemoteWorkflowInput: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let description: String
  public let required: Bool
  public let defaultValue: String?

  public init(id: String, description: String, required: Bool, defaultValue: String?) {
    self.id = id
    self.description = description
    self.required = required
    self.defaultValue = defaultValue
  }
}

public struct MobileRemoteWorkflowItem: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let description: String
  public let state: String
  public let riskClass: String
  public let scheduleSummary: String
  public let file: String
  public let agentRef: String?
  public let goalRef: String?
  public let inputs: [MobileRemoteWorkflowInput]

  public init(
    id: String,
    title: String,
    description: String,
    state: String,
    riskClass: String,
    scheduleSummary: String,
    file: String,
    agentRef: String?,
    goalRef: String?,
    inputs: [MobileRemoteWorkflowInput]
  ) {
    self.id = id
    self.title = title
    self.description = description
    self.state = state
    self.riskClass = riskClass
    self.scheduleSummary = scheduleSummary
    self.file = file
    self.agentRef = agentRef
    self.goalRef = goalRef
    self.inputs = inputs
  }
}

public struct MobileRemoteAgendaStatusRequest: Codable, Hashable, Sendable {
  public let status: String

  public init(status: String) {
    self.status = status
  }
}

public struct MobileRemoteApprovalDecisionRequest: Codable, Hashable, Sendable {
  public let decision: String
  public let note: String?
  public let endStatus: String?
  /// Optional exact identity. When present, the host applies the decision only to this
  /// run, approval, and fingerprint, and refuses it if the current approval differs.
  /// Older clients omit these fields and keep the previous behaviour.
  public let runID: String?
  public let approvalID: String?
  public let fingerprint: String?
  /// Optional provenance key recorded on the approval, for example
  /// `audio-approval:<prompt UUID>`. Replaying the same key returns the original
  /// receipt instead of failing or applying again.
  public let receipt: String?

  public init(
    decision: String,
    note: String? = nil,
    endStatus: String? = nil,
    runID: String? = nil,
    approvalID: String? = nil,
    fingerprint: String? = nil,
    receipt: String? = nil
  ) {
    self.decision = decision
    self.note = note
    self.endStatus = endStatus
    self.runID = runID
    self.approvalID = approvalID
    self.fingerprint = fingerprint
    self.receipt = receipt
  }

  /// Receipts are short single-line keys. Anything else is refused rather than recorded.
  public static func normalizedReceipt(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
      return nil
    }
    guard trimmed.count <= 200,
          trimmed.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7F })
    else { return nil }
    return trimmed
  }
}

public struct MobileRemoteWorkflowStateRequest: Codable, Hashable, Sendable {
  public let state: String

  public init(state: String) {
    self.state = state
  }
}

public struct MobileRemoteWorkflowRunRequest: Codable, Hashable, Sendable {
  public let inputs: [String: String]

  public init(inputs: [String: String]) {
    self.inputs = inputs
  }
}

public struct MobileRemoteErrorEnvelope: Codable, Hashable, Sendable {
  public let error: String

  public init(error: String) {
    self.error = error
  }
}

public struct MobileRemoteHTTPRequest: Hashable, Sendable {
  public let method: String
  public let path: String
  public let headers: [String: String]
  public let body: Data

  public init(method: String, path: String, headers: [String: String] = [:], body: Data = Data()) {
    self.method = method.uppercased()
    self.path = path
    self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
    self.body = body
  }

  public var bearerToken: String? {
    guard let value = headers["authorization"]?.trimmingCharacters(in: .whitespacesAndNewlines),
          value.lowercased().hasPrefix("bearer ")
    else {
      return nil
    }
    return String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try MobileRemoteProtocol.decoder().decode(type, from: body)
  }
}

public struct MobileRemoteHTTPResponse: Hashable, Sendable {
  public let statusCode: Int
  public let headers: [String: String]
  public let body: Data

  public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }

  public static func json<T: Encodable>(_ value: T, statusCode: Int = 200) -> MobileRemoteHTTPResponse {
    do {
      return MobileRemoteHTTPResponse(
        statusCode: statusCode,
        headers: ["Content-Type": "application/json; charset=utf-8"],
        body: try MobileRemoteProtocol.encoder().encode(value)
      )
    } catch {
      return .error("Could not encode the response.", statusCode: 500)
    }
  }

  public static func error(_ message: String, statusCode: Int) -> MobileRemoteHTTPResponse {
    .json(MobileRemoteErrorEnvelope(error: message), statusCode: statusCode)
  }
}
