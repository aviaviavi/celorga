import Foundation

enum MobileRemoteNotification {
  static let replyCategory = "org2.thread.reply"
  static let pendingReplyThreadIDKey = "Org2Mobile.remote.pendingReplyThreadID.v1"
  static let deviceTokenKey = "Org2Mobile.remote.apnsDeviceToken.v1"
  static let pushEnvironmentKey = "Org2Mobile.remote.apnsEnvironment.v1"
}

enum MobileRemoteWire {
  static let version = 2
  static let defaultPort: UInt16 = 48_922

  static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}

struct MobileRemoteSavedHost: Codable, Hashable, Identifiable {
  let id: UUID
  var name: String
  let endpoint: String
}

struct MobileRemoteServerStatus: Codable, Hashable {
  let protocolVersion: Int
  let serverName: String
  let hostRef: String?
  let hostKind: String?
  let corpusName: String?
  let threadCount: Int
  let runningThreadCount: Int
  let aiChatDestinations: [MobileRemoteAIDestination]?
  let pushNotificationsSupported: Bool?
  let pushNotificationsConfigured: Bool?
  let supportsClientThreadIDs: Bool?
  /// The host serves `GET /v1/threads/ID/outputs`.
  let supportsThreadOutputs: Bool?
}

struct MobileRemotePushRegistrationRequest: Codable {
  let deviceToken: String?
  let environment: String?
  let enabled: Bool
}

struct MobileRemotePushRegistrationResponse: Codable {
  let enabled: Bool
  let providerConfigured: Bool
}

struct MobileRemotePushToTalkRegistrationRequest: Codable {
  let pushToken: String?
  let environment: String?
  let enabled: Bool
  /// The host sends no audio approval pushes before this time. `nil` allows prompts.
  let quietUntil: Date?
}

struct MobileRemoteAudioApprovalSnoozeRequest: Codable {
  let runID: String
  let approvalID: String
  let fingerprint: String
  let until: Date
}

struct MobileRemoteAudioApprovalSnoozeResponse: Codable {
  let snoozedUntil: Date
}

struct MobileRemotePushToTalkRegistrationResponse: Codable {
  let enabled: Bool
  let providerConfigured: Bool
}

struct MobileRemoteAIDestination: Codable, Hashable, Identifiable {
  let id: String
  let name: String
  let mention: String
  let runtime: String
}

struct MobileRemotePairRequest: Codable {
  let code: String
  let deviceName: String
}

struct MobileRemotePairResponse: Codable {
  let protocolVersion: Int
  let serverName: String
  let deviceID: UUID
  let accessToken: String
}

struct MobileRemoteCreateThreadRequest: Codable {
  let runtime: String
  let destinationID: String?
  let projectID: String?
  var threadID: UUID? = nil
}

struct MobileRemoteUpdateThreadProjectRequest: Codable {
  let projectID: String
  let isMember: Bool
}

struct MobileRemoteSendMessageRequest: Codable {
  let content: String
  let attachments: [MobileRemoteAttachment]
  let delivery: String?
}

struct MobileRemoteAttachment: Codable, Hashable, Identifiable {
  let id = UUID()
  let fileName: String
  let mimeType: String
  let data: Data

  init(fileName: String, mimeType: String, data: Data) {
    self.fileName = fileName
    self.mimeType = mimeType
    self.data = data
  }

  enum CodingKeys: String, CodingKey {
    case fileName
    case mimeType
    case data
  }
}

struct MobileRemoteFilePreviewRequest: Codable, Hashable {
  let path: String
  let line: Int?
}

struct MobileRemoteImageRequest: Codable, Hashable {
  let path: String
}

struct MobileRemoteImage: Codable, Hashable {
  let relativePath: String
  let mimeType: String
  let data: Data
}

struct MobileRemoteFilePreview: Codable, Hashable {
  let title: String
  let relativePath: String
  let startLine: Int
  let highlightedLine: Int?
  let content: String
}

/// The files a thread edited or linked, mirroring the Mac's Outputs chip.
/// Paths are corpus-relative when the file lives in the host corpus.
struct MobileRemoteThreadOutputs: Codable, Hashable {
  let threadID: UUID
  let folderName: String?
  let folderDisplayPath: String?
  let isTruncated: Bool
  let maxGroups: Int
  let groups: [MobileRemoteThreadOutputGroup]

  var isEmpty: Bool { groups.isEmpty }
  var groupsInFolder: [MobileRemoteThreadOutputGroup] { groups.filter(\.isInFolder) }
  var groupsOutsideFolder: [MobileRemoteThreadOutputGroup] { groups.filter { !$0.isInFolder } }
  var staleCount: Int { groups.filter { !$0.staleFormats.isEmpty }.count }

  /// "acme · 3 outputs", the same label as the Mac chip.
  var chipCountText: String {
    let count = groupsInFolder.count
    return "\(count)\(isTruncated ? "+" : "") output\(count == 1 && !isTruncated ? "" : "s")"
  }
}

struct MobileRemoteThreadOutputGroup: Codable, Hashable, Identifiable {
  let id: String
  let title: String
  let isInFolder: Bool
  let exists: Bool
  let wasCreated: Bool
  let editCount: Int
  let linkCount: Int
  let activitySummary: String
  let staleFormats: [String]
  let lastMessageID: UUID?
  let files: [MobileRemoteThreadOutputFile]

  var primary: MobileRemoteThreadOutputFile? { files.first(where: \.isPrimary) ?? files.first }
}

struct MobileRemoteThreadOutputFile: Codable, Hashable, Identifiable {
  let path: String
  let displayPath: String
  let fileExtension: String
  let isInCorpus: Bool
  let exists: Bool
  let isSibling: Bool
  let isPrimary: Bool
  let isStale: Bool

  var id: String { path }
  /// Text formats open in the corpus reader (synced copy first, then the Mac).
  var opensInReader: Bool { exists && isInCorpus && !MobileRemoteThreadOutputFile.binaryExtensions.contains(fileExtension) }
  static let binaryExtensions: Set<String> = [
    "pdf", "docx", "odt", "xlsx", "pptx", "key", "pages", "numbers", "zip",
    "png", "jpg", "jpeg", "gif", "webp", "heic", "mp3", "m4a", "wav", "mp4", "mov",
  ]
}

struct MobileRemoteModelOption: Codable, Hashable, Identifiable {
  let id: String
  let label: String
  let detail: String?
  let isDefault: Bool
}

struct MobileRemoteThreadConfiguration: Codable, Hashable {
  let threadID: UUID
  let model: String?
  let models: [MobileRemoteModelOption]
  let reasoningEffort: String?
  let reasoningOptions: [MobileRemoteReasoningOption]
  let defaultReasoningEffort: String?
}

struct MobileRemoteUpdateThreadConfigurationRequest: Codable {
  let setting: String
  let value: String?

  init(model: String?) {
    setting = "model"
    value = model
  }

  init(reasoningEffort: String?) {
    setting = "reasoning"
    value = reasoningEffort
  }
}

struct MobileRemoteReasoningOption: Codable, Hashable, Identifiable {
  let id: String
  let label: String
  let detail: String?
}

struct MobileRemoteUpdateThreadStateRequest: Codable {
  let isPinned: Bool?
  let isSettled: Bool?
}

struct MobileRemoteThreadList: Codable {
  let threads: [MobileRemoteThreadSummary]
  let projects: [MobileRemoteProjectSummary]?
}

struct MobileRemoteProjectSummary: Codable, Hashable, Identifiable {
  let id: String
  let title: String
  let color: String
  let threadIDs: [UUID]

  func contains(_ threadID: UUID) -> Bool {
    threadIDs.contains(threadID)
  }
}

struct MobileRemoteThreadSummary: Codable, Hashable, Identifiable {
  let id: UUID
  let title: String
  let runtime: String
  let destinationID: String?
  let destinationName: String?
  let isSharedRoom: Bool?
  let model: String?
  let updatedAt: Date
  let isSettled: Bool
  let isPinned: Bool
  let isRunning: Bool
  let unreadMessageCount: Int
  let preview: String?
  let latestAssistantMessageID: UUID?
  let latestAssistantPreview: String?
  /// The OpenOrg host running (or that last ran) the conversation.
  var executionHostName: String? = nil
}

extension Array where Element == MobileRemoteThreadSummary {
  /// Running chats first, then the rest, each group keeping the host's order
  /// (pinned, then most recent). Matches the Mac sidebar's Running group.
  var runningFirst: [MobileRemoteThreadSummary] {
    filter(\.isRunning) + filter { !$0.isRunning }
  }
}

struct MobileRemoteThreadDetail: Codable, Hashable {
  let thread: MobileRemoteThreadSummary
  let messages: [MobileRemoteChatMessage]
  let activeDestinationName: String?
  let streamingReply: String
  let reasoning: String
  let activities: [MobileRemoteActivity]
  let connectionState: String
  let connectionDetail: String?
}

struct MobileRemoteChatMessage: Codable, Hashable, Identifiable {
  let id: UUID
  let role: String
  let content: String
  let attachmentNames: [String]
  let createdAt: Date
  let deliveryStatus: String
  let deliveryKind: String?
  let sendFailure: String?
  let authorRuntime: String?
  let authorDestinationID: String?
  let authorDestinationName: String?
  let audience: String?
  let audienceDestinationNames: [String]?
  let isRoomDispatchCopy: Bool?
  let roomRoundID: UUID?
  /// Where the message came from and which host handled it.
  var provenanceCaption: String? = nil
  var originClient: String? = nil
  var originDeviceName: String? = nil
  var receivedByHostName: String? = nil
  var executionHostName: String? = nil
}

struct MobileRemoteActivity: Codable, Hashable, Identifiable {
  let id: String
  let title: String
  let detail: String?
  let status: String
  let updatedAt: Date
}

struct MobileRemoteMutationResponse: Codable {
  let accepted: Bool
  let threadID: UUID?
}

struct MobileRemoteWorkspaceSnapshot: Codable, Hashable {
  let updatedAt: Date
  let agenda: [MobileRemoteAgendaItem]
  let approvals: [MobileRemoteApprovalItem]
  let workflows: [MobileRemoteWorkflowItem]
  let approvalDecisionReceipt: MobileRemoteApprovalDecisionReceipt?
  var approvalHistory: [MobileRemoteApprovalHistoryItem]? = nil
}

struct MobileRemoteApprovalHistoryItem: Codable, Hashable, Identifiable {
  var id: String { "\(runID):\(approvalID)" }
  let runID: String
  let approvalID: String
  let title: String
  let status: String
  let decidedAt: String?
  let decidedBy: String?
  let decisionNote: String?
}

struct MobileRemoteApprovalDecisionReceipt: Codable, Hashable {
  let runID: String
  let approvalID: String
  let decision: String
  let runStatus: String
  let pendingApprovalCount: Int
  let continuation: String
  let receipt: String?
  let duplicate: Bool?
}

struct MobileRemoteAgendaItem: Codable, Hashable, Identifiable {
  let id: String
  let title: String
  let todo: String
  let file: String
  let line: Int
  let date: String
  let kind: String
  let tags: [String]
  let body: String
  let priority: String?
  let time: String?
  let effort: String?

  var localEntry: AgendaEntry {
    let normalizedKind: OrgPlanningKind
    switch kind.lowercased() {
    case let value where value.contains("deadline"):
      normalizedKind = .deadline
    case let value where value.contains("timestamp"):
      normalizedKind = .timestamp
    default:
      normalizedKind = .scheduled
    }
    return AgendaEntry(
      id: id,
      title: title,
      todo: todo,
      file: file,
      line: line,
      date: date,
      kind: normalizedKind,
      tags: tags,
      body: body
    )
  }
}

struct MobileRemoteApprovalItem: Codable, Hashable, Identifiable {
  let id: String
  let title: String
  let status: String
  let todo: String?
  let level: Int?
  let file: String
  let line: Int
  let sourceID: String?
  let properties: [String: String]
  let body: String
  let tags: [String]
  let kind: String?
  let runID: String?
  let approvalID: String?
  let fingerprint: String?
  let action: String?
  let riskClass: String?
  let requestedRole: String?
  let requestedFrom: String?
  let requestedAt: String?
  let runGoal: String?
  let runStatus: String?
  let runDecisionEffect: String?
  var priority: String? = nil

  var localEntry: ApprovalEntry {
    ApprovalEntry(
      id: id,
      title: title,
      status: status,
      todo: todo,
      level: level,
      file: file,
      line: line,
      sourceID: sourceID,
      properties: properties,
      body: body,
      tags: tags,
      kind: kind,
      runID: runID,
      approvalID: approvalID,
      fingerprint: fingerprint,
      action: action,
      riskClass: riskClass,
      requestedFrom: requestedFrom,
      requestedAt: requestedAt,
      priority: priority
    )
  }
}

struct MobileRemoteWorkflowInput: Codable, Hashable, Identifiable {
  let id: String
  let description: String
  let required: Bool
  let defaultValue: String?
}

struct MobileRemoteWorkflowItem: Codable, Hashable, Identifiable {
  let id: String
  let title: String
  let description: String
  let state: String
  let riskClass: String
  let scheduleSummary: String
  let file: String
  let agentRef: String?
  let goalRef: String?
  let inputs: [MobileRemoteWorkflowInput]
}

struct MobileRemoteAgendaStatusRequest: Codable {
  let status: String
}

struct MobileRemoteApprovalDecisionRequest: Codable {
  let decision: String
  let note: String?
  let endStatus: String?
  // Optional exact identity. The host refuses the decision if the current approval differs.
  var runID: String?
  var approvalID: String?
  var fingerprint: String?
  // Provenance key recorded on the approval; replaying it returns the original receipt.
  var receipt: String?
}

struct MobileRemoteWorkflowStateRequest: Codable {
  let state: String
}

struct MobileRemoteWorkflowRunRequest: Codable {
  let inputs: [String: String]
}

enum MobileExternalThreadHarness: String, Codable, CaseIterable, Identifiable {
  case codex

  var id: String { rawValue }

  var title: String {
    switch self {
    case .codex: "Codex"
    }
  }

  var systemImage: String {
    switch self {
    case .codex: "chevron.left.forwardslash.chevron.right"
    }
  }
}

struct MobileExternalThreadSummary: Codable, Hashable, Identifiable {
  let harness: MobileExternalThreadHarness
  let externalID: String
  let title: String
  let preview: String?
  let workspacePath: String?
  let source: String?
  let modelProvider: String?
  let createdAt: Date
  let updatedAt: Date
  let status: String
  let isPinned: Bool

  var id: String { "\(harness.rawValue):\(externalID)" }
}

struct MobileExternalThreadMessage: Codable, Hashable, Identifiable {
  enum Role: String, Codable {
    case user
    case assistant
  }

  let id: String
  let role: Role
  let content: String
  let createdAt: Date
}

struct MobileExternalThreadDetail: Codable, Hashable {
  let thread: MobileExternalThreadSummary
  let messages: [MobileExternalThreadMessage]
}

struct MobileExternalThreadList: Codable, Hashable {
  let threads: [MobileExternalThreadSummary]
}

struct MobileRemoteErrorEnvelope: Codable {
  let error: String
}
