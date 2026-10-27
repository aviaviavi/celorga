import Darwin
import Foundation

public enum JSONValue: Hashable, Codable, Sendable {
  case null
  case bool(Bool)
  case integer(Int64)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null:
      try container.encodeNil()
    case .bool(let value):
      try container.encode(value)
    case .integer(let value):
      try container.encode(value)
    case .number(let value):
      try container.encode(value)
    case .string(let value):
      try container.encode(value)
    case .array(let value):
      try container.encode(value)
    case .object(let value):
      try container.encode(value)
    }
  }

  public var objectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  public var arrayValue: [JSONValue]? {
    guard case .array(let value) = self else { return nil }
    return value
  }

  public var stringValue: String? {
    guard case .string(let value) = self else { return nil }
    return value
  }

  public var boolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }

  public subscript(key: String) -> JSONValue? {
    objectValue?[key]
  }
}

public enum CodexAccountState: Equatable, Sendable {
  case unknown
  case unavailable(String)
  case signedOut
  case chatGPT(email: String?, plan: String?)
  case apiKey
  case other(String)

  public var isReady: Bool {
    switch self {
    case .chatGPT:
      true
    case .unknown, .unavailable, .signedOut, .apiKey, .other:
      false
    }
  }

  public var label: String {
    switch self {
    case .unknown:
      return "Not checked"
    case .unavailable(let detail):
      return detail
    case .signedOut:
      return "Not signed in"
    case .chatGPT(let email, let plan):
      let details = [email, plan.map { "\($0) plan" }]
        .compactMap { $0 }
        .joined(separator: " · ")
      return details.isEmpty ? "Signed in with ChatGPT" : details
    case .apiKey:
      return "API key (separate API billing)"
    case .other(let type):
      return type
    }
  }
}

public enum CodexSandboxAccess: String, CaseIterable, Identifiable, Sendable {
  case readOnly
  case workspaceWrite
  case fullAccess

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .readOnly: "Read Only"
    case .workspaceWrite: "Workspace Write"
    case .fullAccess: "Full Access"
    }
  }

  var threadSandboxValue: String {
    switch self {
    case .readOnly: "read-only"
    case .workspaceWrite: "workspace-write"
    case .fullAccess: "danger-full-access"
    }
  }

  func turnSandboxPolicy(workspacePath: String) -> JSONValue {
    switch self {
    case .readOnly:
      .object(["type": .string("readOnly")])
    case .workspaceWrite:
      .object([
        "type": .string("workspaceWrite"),
        "writableRoots": .array([.string(workspacePath)]),
        "networkAccess": .bool(false)
      ])
    case .fullAccess:
      .object(["type": .string("dangerFullAccess")])
    }
  }

  func turnSandboxPolicy(cwd: URL) -> JSONValue {
    turnSandboxPolicy(workspacePath: cwd.standardizedFileURL.path)
  }
}

public enum CodexCorpusAccess: Equatable, Sendable {
  /// OpenOrg owns the canonical corpus and supplies review-gated workspace tools.
  case clientWorkspaceTools
  /// Codex runs inside a writable checkout of the corpus on its own host.
  case runtimeFilesystem
}

public struct CodexLoginStart: Equatable, Sendable {
  public let loginID: String
  public let authURL: URL

  public init(loginID: String, authURL: URL) {
    self.loginID = loginID
    self.authURL = authURL
  }
}

public struct CodexDynamicToolCall: Sendable {
  public let callID: String
  public let threadID: String
  public let turnID: String
  public let tool: String
  public let arguments: JSONValue
}

public struct CodexDynamicToolResult: Sendable {
  public let success: Bool
  public let text: String

  public init(success: Bool, text: String) {
    self.success = success
    self.text = text
  }
}

public struct CodexTurnResult: Sendable {
  public enum Status: String, Sendable {
    case completed
    case interrupted
    case failed
    case unknown
  }

  public let threadID: String
  public let turnID: String
  public let status: Status
  public let reply: String
  public let errorMessage: String?
  public let usage: AIChatTokenUsage?
}

public enum CodexAppServerEvent: Sendable {
  case connectionChanged(isConnected: Bool, detail: String?)
  case accountUpdated(authMode: String?, plan: String?)
  case loginCompleted(loginID: String?, success: Bool, error: String?)
  case turnStarted(threadID: String, turnID: String)
  case turnTerminal(
    threadID: String,
    turnID: String,
    status: CodexTurnResult.Status,
    detail: String?
  )
  case agentMessageDelta(threadID: String, turnID: String, itemID: String, delta: String)
  case reasoningDelta(threadID: String, turnID: String, delta: String)
  case activity(
    threadID: String,
    turnID: String,
    itemID: String,
    title: String,
    detail: String?,
    status: AIChatRunActivity.Status
  )
  case contextCompacted(threadID: String, turnID: String)
  case warning(threadID: String?, message: String)
}

enum CodexStreamingText {
  static func deltaWithItemBoundary(
    _ delta: String,
    itemID: String,
    after previousItemID: String?,
    hasExistingText: Bool
  ) -> String {
    guard let previousItemID,
          previousItemID != itemID,
          hasExistingText
    else { return delta }
    return "\n\n" + delta
  }

  static func appending(
    _ delta: String,
    itemID: String,
    after previousItemID: String?,
    to existing: String
  ) -> String {
    existing + deltaWithItemBoundary(
      delta,
      itemID: itemID,
      after: previousItemID,
      hasExistingText: !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    )
  }
}

public enum CodexAppServerError: LocalizedError, Sendable {
  case executableNotFound
  case launchFailed(String)
  case disconnected(String)
  case server(code: Int?, message: String)
  case invalidResponse(String)
  case requestTimedOut(String)
  case turnStartUnknown(String)
  case notAuthenticated
  case turnFailed(String)
  case turnInterrupted

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      "Codex was not found. Install the Codex CLI or the ChatGPT Mac app."
    case .launchFailed(let detail):
      "Could not start Codex: \(detail)"
    case .disconnected(let detail):
      "Codex disconnected\(detail.isEmpty ? "." : ": \(detail)")"
    case .server(_, let message):
      "Codex: \(message)"
    case .invalidResponse(let detail):
      "Codex returned an invalid response: \(detail)"
    case .requestTimedOut(let method):
      if method == "thread/resume" {
        "Codex took too long to reopen this task. Its connection was reset; retry once to reconnect."
      } else {
        "Codex did not respond to \(method) before the request timed out."
      }
    case .turnStartUnknown(let detail):
      "Codex may have accepted this turn, but Celorga could not confirm it yet. \(detail)"
    case .notAuthenticated:
      "Sign in with ChatGPT before using a Codex thread."
    case .turnFailed(let detail):
      "Codex turn failed: \(detail)"
    case .turnInterrupted:
      "Codex turn was stopped."
    }
  }
}

public enum CodexTurnStartPolicy: Sendable {
  /// This exact attempt has not been submitted before, so a verified history
  /// miss may be followed by one turn/start request.
  case startIfAbsent
  /// This attempt may already have been accepted. A history miss remains
  /// unknown and must never cause another turn/start request.
  case reconcileOnly
}

public struct CodexTurnAttemptIdentity: Equatable, Sendable {
  /// The Celorga message remains stable across explicitly authorized retries.
  public let messageID: UUID
  /// Every provider submission uses a distinct correlation identity.
  public let attemptID: UUID
  /// A retry is admissible only when the runtime-host journal has positively
  /// recorded this exact predecessor as failed or interrupted.
  public let predecessorAttemptID: UUID?

  public init(messageID: UUID, attemptID: UUID, predecessorAttemptID: UUID? = nil) {
    self.messageID = messageID
    self.attemptID = attemptID
    self.predecessorAttemptID = predecessorAttemptID
  }
}

public enum CodexAppServerTransport: Sendable, Equatable {
  case local
  case remote(endpoint: URL, bearerToken: String?)
  case managedRemote(sshHost: String)

  var connectionDescription: String {
    switch self {
    case .local: "Local Codex App Server"
    case .remote(let endpoint, _): endpoint.absoluteString
    case .managedRemote(let sshHost): "Remote Codex over SSH via \(sshHost)"
    }
  }
}

public struct CodexThreadResolution: Equatable, Sendable {
  public let threadID: String
  public let replacedStaleThread: Bool

  public init(threadID: String, replacedStaleThread: Bool) {
    self.threadID = threadID
    self.replacedStaleThread = replacedStaleThread
  }
}

public actor CodexAppServerClient {
  public typealias EventHandler = @Sendable (CodexAppServerEvent) async -> Void
  public typealias DynamicToolHandler =
    @Sendable (CodexDynamicToolCall) async -> CodexDynamicToolResult

  private final class PendingTurn {
    var threadID: String?
    var finalReply = ""
    var streamedReplyChunks: [String] = []
    var streamedItemID: String?
    var errorMessage: String?
    var usage: AIChatTokenUsage?
    /// Codex appends a turn/start sent during an active turn to that turn and
    /// returns its ID, so more than one send can wait on the same native turn.
    var continuations: [CheckedContinuation<CodexTurnResult, Never>] = []
    var completedResult: CodexTurnResult?
    var pendingCompletionResult: CodexTurnResult?
    var completionTask: Task<Void, Never>?

    var streamedReply: String {
      streamedReplyChunks.joined()
    }

    func appendStreamedReply(_ delta: String, itemID: String) {
      streamedReplyChunks.append(CodexStreamingText.deltaWithItemBoundary(
        delta,
        itemID: itemID,
        after: streamedItemID,
        hasExistingText: !streamedReplyChunks.isEmpty
      ))
      streamedItemID = itemID
    }
  }

  private struct RequestSubmissionError: Error, @unchecked Sendable {
    let underlying: Error
    let submissionStarted: Bool
  }

  private var executableURL: URL?
  private let executableResolver: (@Sendable () -> URL?)?
  private let sshExecutableURL: URL
  private let transport: CodexAppServerTransport
  private let eventHandler: EventHandler
  private let dynamicToolHandler: DynamicToolHandler
  private let requestTimeoutNanoseconds: UInt64
  private let threadResumeRequestTimeoutNanoseconds: UInt64
  private let initializeRequestTimeoutNanoseconds: UInt64
  private var process: Process?
  private var webSocketTask: URLSessionWebSocketTask?
  private var webSocketReceiveTask: Task<Void, Never>?
  private var standardInput: FileHandle?
  private var standardOutput: FileHandle?
  private var standardError: FileHandle?
  private var outputBuffer = Data()
  private var startupTask: Task<Void, Error>?
  private var initialized = false
  private var requestCounter: Int64 = 0
  private var pendingRequests: [
    String: CheckedContinuation<JSONValue, Error>
  ] = [:]
  private var pendingRequestTimeoutTasks: [String: Task<Void, Never>] = [:]
  private var cancelledRequestKeys = Set<String>()
  private var submittedRequestKeys = Set<String>()
  private var pendingTurns: [String: PendingTurn] = [:]
  private var reportedStartedTurnIDs = Set<String>()
  private var managedRemoteRecoveryTask: Task<Void, Never>?
  /// Recovery reported a disconnect; the next successful poll reports the reconnect.
  private var reportedRecoveryDisconnect = false
  private var cancelledTurnIDs = Set<String>()
  private var ignoredCompletedTurnIDs = Set<String>()
  private var loadedThreadIDs = Set<String>()
  private var modelCatalogLoadedAt: Date?
  private var latestStderr = ""
  private static let tokenUsageCompletionGraceNanoseconds: UInt64 = 250_000_000

  public init(
    executableURL: URL? = nil,
    executableResolver: (@Sendable () -> URL?)? = nil,
    sshExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/ssh"),
    transport: CodexAppServerTransport = .local,
    requestTimeoutNanoseconds: UInt64 = 30_000_000_000,
    // Codex serializes writers for a native task. When that task is still open
    // in Codex (or a prior app-server retained its writer), thread/resume does
    // not currently fail with a lock error; it simply waits. Keep this bound
    // short so OpenOrg can rebind the chat to a fresh task and carry its own
    // transcript context forward instead of looking disconnected for minutes.
    threadResumeRequestTimeoutNanoseconds: UInt64 = 8_000_000_000,
    // The initialize handshake waits for the app server to start. Nil uses
    // `requestTimeoutNanoseconds`, as before.
    initializeRequestTimeoutNanoseconds: UInt64? = nil,
    eventHandler: @escaping EventHandler,
    dynamicToolHandler: @escaping DynamicToolHandler
  ) {
    let resolvedExecutableResolver: (@Sendable () -> URL?)?
    if let executableResolver {
      resolvedExecutableResolver = executableResolver
    } else if executableURL == nil {
      resolvedExecutableResolver = { CodexAppServerClient.resolveExecutableURL() }
    } else {
      resolvedExecutableResolver = nil
    }
    self.executableResolver = resolvedExecutableResolver
    self.executableURL = executableURL ?? resolvedExecutableResolver?()
    self.sshExecutableURL = sshExecutableURL
    self.transport = transport
    self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
    self.threadResumeRequestTimeoutNanoseconds = threadResumeRequestTimeoutNanoseconds
    self.initializeRequestTimeoutNanoseconds = initializeRequestTimeoutNanoseconds ?? requestTimeoutNanoseconds
    self.eventHandler = eventHandler
    self.dynamicToolHandler = dynamicToolHandler
  }

  deinit {
    standardOutput?.readabilityHandler = nil
    standardError?.readabilityHandler = nil
    if process?.isRunning == true {
      process?.terminate()
    }
    webSocketReceiveTask?.cancel()
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    managedRemoteRecoveryTask?.cancel()
  }

  nonisolated public static func resolveExecutableURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    let home = environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
    var bundled: [String] = []
    if let path = Bundle.main.url(forResource: "codex", withExtension: nil)?.path {
      bundled.append(path)
    }
    let applicationRoots = ["/Applications", URL(fileURLWithPath: home).appendingPathComponent("Applications").path]
    let embedded = applicationRoots.flatMap { root in
      ["ChatGPT.app", "Codex.app"].flatMap { app in
        [
          "\(root)/\(app)/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
          "\(root)/\(app)/Contents/Resources/codex"
        ]
      }
    }
    return LocalAgentExecutableLocator.resolve(
      executableName: "codex",
      configuredKey: "ORG2_CODEX_EXECUTABLE",
      leadingCandidates: bundled + embedded,
      environment: environment,
      fileManager: fileManager
    )
  }

  nonisolated static func managedRemoteSSHArguments(sshHost rawSSHHost: String) throws -> [String] {
    let sshHost = rawSSHHost.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet.alphanumerics.union(
      CharacterSet(charactersIn: ".-_@:%[]+")
    )
    guard !sshHost.isEmpty,
          !sshHost.hasPrefix("-"),
          sshHost.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else {
      throw CodexAppServerError.invalidResponse(
        "managed remote Codex needs a valid SSH host or ~/.ssh/config alias"
      )
    }
    return [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=15",
      "-o", "ServerAliveInterval=15",
      "-o", "ServerAliveCountMax=12",
      sshHost,
      Self.managedRemoteCommand()
    ]
  }

  // The managed daemon speaks WebSocket frames on its private Unix socket,
  // while this client speaks JSONL over the SSH process pipes. Codex's proxy
  // command currently forwards neither framing reliably, so a fixed adapter
  // performs only that framing conversion. The daemon owns the turn; losing
  // this SSH process therefore no longer terminates work on the remote Mac.
  private nonisolated static func managedRemoteCommand() -> String {
    let adapter = Data(managedRemoteJSONLAdapter.utf8).base64EncodedString()
    return #"exec /bin/sh -lc 'PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; command -v python3 >/dev/null 2>&1 || { echo "Remote Codex over SSH requires python3 on the remote Mac." >&2; exit 127; }; codex app-server daemon start >/dev/null || exit $?; exec python3 -c "import base64;exec(compile(base64.b64decode(\"\#(adapter)\"),\"<openorg-codex-adapter>\",\"exec\"))"'"#
  }

  nonisolated static let managedRemoteJSONLAdapter = #"""
import base64
import fcntl
import hashlib
import json
import os
import socket
import struct
import sys
import threading
import uuid

codex_home = os.environ.get("CODEX_HOME", os.path.expanduser("~/.codex"))
socket_path = os.path.join(codex_home, "app-server-control", "app-server-control.sock")
connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
connection.connect(socket_path)

key = base64.b64encode(os.urandom(16)).decode("ascii")
upgrade = (
    "GET / HTTP/1.1\r\n"
    "Host: localhost\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    "Sec-WebSocket-Key: %s\r\n"
    "Sec-WebSocket-Version: 13\r\n\r\n" % key
).encode("ascii")
connection.sendall(upgrade)

buffer = b""
while b"\r\n\r\n" not in buffer:
    chunk = connection.recv(4096)
    if not chunk:
        raise RuntimeError("Codex daemon closed during WebSocket upgrade")
    buffer += chunk
header, buffer = buffer.split(b"\r\n\r\n", 1)
if not header.startswith(b"HTTP/1.1 101"):
    raise RuntimeError("Codex daemon rejected WebSocket upgrade: %s" % header.decode("utf-8", "replace"))
expected_accept = base64.b64encode(
    hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")).digest()
).decode("ascii")
if ("sec-websocket-accept: " + expected_accept).lower().encode("ascii") not in header.lower():
    raise RuntimeError("Codex daemon returned an invalid WebSocket accept value")

send_lock = threading.Lock()
output_lock = threading.Lock()
claim_lock = threading.Lock()
claims_by_request = {}
claims_by_turn = {}
# This authority is safe only when every dispatcher for the corpus uses this
# receipt-aware bridge. A rollout must quiesce legacy executors first; older
# direct clients do not participate in the journal and cannot be mixed live.
claim_root = os.environ.get(
    "CELORGA_MANAGED_REMOTE_CLAIM_ROOT",
    os.path.join(codex_home, "celorga-managed-remote-claims", "v3"),
)

def send_frame(opcode, payload):
    length = len(payload)
    if length < 126:
        prefix = bytes([0x80 | opcode, 0x80 | length])
    elif length <= 0xffff:
        prefix = bytes([0x80 | opcode, 0xfe]) + struct.pack("!H", length)
    else:
        prefix = bytes([0x80 | opcode, 0xff]) + struct.pack("!Q", length)
    mask = os.urandom(4)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    with send_lock:
        connection.sendall(prefix + mask + masked)

def emit_client_message(message):
    payload = json.dumps(message, separators=(",", ":")).encode("utf-8")
    with output_lock:
        sys.stdout.buffer.write(payload + b"\n")
        sys.stdout.buffer.flush()

def durable_json_replace(path, value):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    temporary = "%s.tmp-%s-%s" % (path, os.getpid(), threading.get_ident())
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        payload = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")
        os.write(descriptor, payload)
        os.fsync(descriptor)
    finally:
        os.close(descriptor)
    os.replace(temporary, path)
    directory = os.open(os.path.dirname(path), os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)

def read_journal(path):
    with open(path, "r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("journal is not an object")
    return value

def authority_paths(message_id):
    key = hashlib.sha256(message_id.encode("utf-8")).hexdigest()
    namespace = os.path.join(claim_root, key)
    return (
        namespace,
        os.path.join(namespace, "journal.json"),
        os.path.join(namespace, "authority.lock"),
    )

def create_authority_namespace(message_id):
    namespace, path, lock_path = authority_paths(message_id)
    os.makedirs(claim_root, mode=0o700, exist_ok=True)
    created = False
    try:
        os.mkdir(namespace, mode=0o700)
        created = True
        directory = os.open(claim_root, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    except FileExistsError:
        pass
    return namespace, path, lock_path, created

def with_authority_lock(lock_path, operation):
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        return operation()
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)

def claim_hold_message(request_id, detail):
    return {
        "id": request_id,
        "error": {
            "code": -32098,
            "message": "Celorga managed-remote delivery is held for authoritative reconciliation.",
            "data": {"celorgaDeliveryState": "held", "detail": detail},
        },
    }

def claim_hold_response(request_id, detail):
    emit_client_message(claim_hold_message(request_id, detail))

def no_authority_response(request_id):
    emit_client_message({
        "id": request_id,
        "error": {
            "code": -32097,
            "message": "No admitted Celorga managed-remote attempt exists for this exact contract.",
            "data": {"celorgaDeliveryState": "notAdmitted"},
        },
    })

def parse_delivery_contract(contract, params):
    if not isinstance(contract, dict):
        raise ValueError("missing delivery contract")
    if contract.get("schema") != "celorga:managed-remote-delivery:v3":
        raise ValueError("unsupported delivery contract")
    message_id = str(uuid.UUID(contract["messageId"])).lower()
    attempt_id = str(uuid.UUID(contract["attemptId"])).lower()
    predecessor = contract.get("predecessorAttemptId")
    predecessor_id = str(uuid.UUID(predecessor)).lower() if predecessor is not None else None
    thread_id = contract["threadId"]
    if not isinstance(thread_id, str) or not thread_id or params.get("threadId") != thread_id:
        raise ValueError("thread identity mismatch")
    return message_id, attempt_id, predecessor_id, thread_id

def delivery_contract_hash(params):
    # Celorga's workspace snapshot and local edit correlation are transport
    # envelope values. They can be regenerated after a crash without changing
    # the user's requested work. Bind the durable claim to the exact user body,
    # attachments, native thread, model, workspace, sandbox, and attempt while
    # deliberately excluding only that leading envelope.
    canonical = json.loads(json.dumps(params))
    inputs = canonical.get("input")
    if not isinstance(inputs, list) or not inputs or not isinstance(inputs[0], dict):
        raise ValueError("missing text input")
    text = inputs[0].get("text")
    if not isinstance(text, str):
        raise ValueError("missing wrapped user message")
    start_marker = "<user-message>\n"
    end_marker = "\n</user-message>"
    start = text.find(start_marker)
    end = text.rfind(end_marker)
    if start < 0 or end < start + len(start_marker):
        raise ValueError("invalid wrapped user message")
    inputs[0]["text"] = text[start + len(start_marker):end]
    payload = json.dumps(canonical, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()

def claim_turn_start(request):
    params = request.get("params")
    if request.get("method") != "turn/start" or not isinstance(params, dict):
        return True
    contract = params.pop("celorgaDelivery", None)
    request_id = request.get("id")
    try:
        message_id, attempt_id, predecessor_id, thread_id = parse_delivery_contract(contract, params)
        if params.get("clientUserMessageId", "").lower() != attempt_id:
            raise ValueError("attempt identity mismatch")
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        claim_hold_response(request_id, "invalid delivery contract: %s" % error)
        return False
    try:
        contract_hash = delivery_contract_hash(params)
    except (TypeError, ValueError) as error:
        claim_hold_response(request_id, "invalid request binding: %s" % error)
        return False
    namespace, _, _ = authority_paths(message_id)
    if (
        not os.path.isdir(namespace)
        and (attempt_id != message_id or predecessor_id is not None)
    ):
        claim_hold_response(
            request_id,
            "only the deterministic initial attempt may create message authority",
        )
        return False
    _, path, lock_path, namespace_created = create_authority_namespace(message_id)
    accepted = False
    detail = "message already has an authoritative attempt"

    def admit():
        nonlocal accepted, detail
        if not os.path.exists(path):
            if not namespace_created:
                detail = "message authority exists without a valid journal"
                return
            if attempt_id != message_id or predecessor_id is not None:
                detail = "only the deterministic initial attempt may create message authority"
                return
            journal = {
                "schema": "celorga:managed-remote-delivery-journal:v3",
                "messageId": message_id,
                "threadId": thread_id,
                "currentAttemptId": attempt_id,
                "attempts": {},
            }
        else:
            journal = read_journal(path)
            if any(journal.get(key) != value for key, value in (
                ("schema", "celorga:managed-remote-delivery-journal:v3"),
                ("messageId", message_id),
                ("threadId", thread_id),
            )) or not isinstance(journal.get("attempts"), dict):
                detail = "message journal is corrupt or conflicts"
                return
            current_id = journal.get("currentAttemptId")
            current = journal["attempts"].get(current_id)
            if attempt_id == current_id:
                detail = (
                    "attempt already claimed"
                    if isinstance(current, dict) and current.get("contractHash") == contract_hash
                    else "attempt contract changed after admission"
                )
                return
            if (
                predecessor_id != current_id
                or not isinstance(current, dict)
                or current.get("state") not in ("failed", "interrupted")
                or not isinstance(current.get("nativeTurnId"), str)
                or not current.get("nativeTurnId")
                or attempt_id in journal["attempts"]
            ):
                detail = "retry lacks the exact authoritative failed or interrupted predecessor"
                return
        journal["attempts"][attempt_id] = {
            "attemptId": attempt_id,
            "predecessorAttemptId": predecessor_id,
            "contractHash": contract_hash,
            "state": "claimed",
        }
        journal["currentAttemptId"] = attempt_id
        durable_json_replace(path, journal)
        accepted = True

    try:
        with_authority_lock(lock_path, admit)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        detail = "message journal could not be persisted: %s" % error
    if not accepted:
        claim_hold_response(request_id, detail)
        return False
    with claim_lock:
        claims_by_request[str(request_id)] = (path, lock_path, attempt_id, "start", thread_id)
    return True

def track_delivery_read(request):
    params = request.get("params")
    if request.get("method") != "thread/read" or not isinstance(params, dict):
        return True
    contract = params.pop("celorgaDeliveryRead", None)
    if not isinstance(contract, dict):
        return True
    request_id = request.get("id")
    try:
        message_id, attempt_id, predecessor_id, thread_id = parse_delivery_contract(contract, params)
        start_params = contract["startParams"]
        if not isinstance(start_params, dict):
            raise ValueError("missing expected start contract")
        normalize_runtime_params(start_params)
        if start_params.get("threadId") != thread_id:
            raise ValueError("expected start thread mismatch")
        if str(start_params.get("clientUserMessageId", "")).lower() != attempt_id:
            raise ValueError("expected start attempt mismatch")
    except (KeyError, TypeError, ValueError, AttributeError) as error:
        claim_hold_response(request_id, "invalid reconciliation contract: %s" % error)
        return False
    try:
        contract_hash = delivery_contract_hash(start_params)
    except (TypeError, ValueError) as error:
        claim_hold_response(request_id, "invalid reconciliation binding: %s" % error)
        return False
    namespace, path, lock_path = authority_paths(message_id)
    if not os.path.isdir(namespace):
        no_authority_response(request_id)
        return False
    decision = "hold"
    detail = "message authority does not admit this reconciliation"

    def inspect():
        nonlocal decision, detail
        if not os.path.exists(path):
            detail = "message authority exists without a valid journal"
            return
        journal = read_journal(path)
        if any(journal.get(key) != value for key, value in (
            ("schema", "celorga:managed-remote-delivery-journal:v3"),
            ("messageId", message_id),
            ("threadId", thread_id),
        )) or not isinstance(journal.get("attempts"), dict):
            detail = "message journal is corrupt or runtime thread changed"
            return
        current_id = journal.get("currentAttemptId")
        current = journal["attempts"].get(current_id)
        if attempt_id == current_id:
            if isinstance(current, dict) and current.get("contractHash") == contract_hash:
                decision = "read"
            else:
                detail = "attempt contract changed after admission"
            return
        if (
            predecessor_id == current_id
            and isinstance(current, dict)
            and current.get("state") in ("failed", "interrupted")
            and isinstance(current.get("nativeTurnId"), str)
            and current.get("nativeTurnId")
            and attempt_id not in journal["attempts"]
        ):
            decision = "notAdmitted"
            return
        detail = "retry lacks the exact authoritative failed or interrupted predecessor"

    try:
        with_authority_lock(lock_path, inspect)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        detail = "message journal could not be read: %s" % error
    if decision == "notAdmitted":
        no_authority_response(request_id)
        return False
    if decision != "read":
        claim_hold_response(request_id, detail)
        return False
    with claim_lock:
        claims_by_request[str(request_id)] = (
            path, lock_path, attempt_id, "read", thread_id
        )
    return True

def update_attempt_receipt(path, lock_path, attempt_id, expected_thread_id, turn, response_error=False):
    def update():
        if not os.path.exists(path):
            return
        journal = read_journal(path)
        attempts = journal.get("attempts")
        attempt = attempts.get(attempt_id) if isinstance(attempts, dict) else None
        if not isinstance(attempt, dict):
            return
        prior_state = attempt.get("state")
        terminal = prior_state in ("completed", "failed", "interrupted")
        if response_error and not terminal:
            # An error can arrive after the daemon accepted or even started
            # the turn. Only exact native terminal evidence may unlock retry.
            attempt["state"] = "unknown"
        if isinstance(turn, dict):
            turn_id = turn.get("id")
            status = turn.get("status")
            has_turn_id = isinstance(turn_id, str) and bool(turn_id)
            if has_turn_id:
                existing_turn_id = attempt.get("nativeTurnId")
                if isinstance(existing_turn_id, str) and existing_turn_id != turn_id:
                    attempt["state"] = "unknown"
                    durable_json_replace(path, journal)
                    return
                attempt["nativeTurnId"] = turn_id
                with claim_lock:
                    claims_by_turn[turn_id] = (
                        path, lock_path, attempt_id, expected_thread_id
                    )
            if terminal:
                pass
            elif status == "inProgress":
                attempt["state"] = "started" if has_turn_id else "unknown"
            elif status in ("completed", "failed", "interrupted"):
                attempt["state"] = status if has_turn_id else "unknown"
            elif status is not None:
                attempt["state"] = "unknown"
        durable_json_replace(path, journal)
    try:
        with_authority_lock(lock_path, update)
    except (OSError, ValueError, json.JSONDecodeError):
        # The journal still blocks a second admission if receipt enrichment
        # fails, so uncertainty remains fail-closed.
        return

def turn_from_thread_read(message, attempt_id, expected_thread_id):
    result = message.get("result")
    thread = result.get("thread") if isinstance(result, dict) else None
    if not isinstance(thread, dict) or thread.get("id") != expected_thread_id:
        return None
    turns = thread.get("turns")
    if not isinstance(turns, list):
        return None
    for turn in reversed(turns):
        if not isinstance(turn, dict):
            continue
        items = turn.get("items")
        if isinstance(items, list) and any(
            isinstance(item, dict)
            and item.get("type") == "userMessage"
            and str(item.get("clientId", "")).lower() == attempt_id
            for item in items
        ):
            return turn
    return None

def turn_conflicts_with_bound_receipt(path, lock_path, attempt_id, turn):
    conflict = False

    def inspect():
        nonlocal conflict
        if not os.path.exists(path):
            conflict = True
            return
        journal = read_journal(path)
        attempts = journal.get("attempts")
        attempt = attempts.get(attempt_id) if isinstance(attempts, dict) else None
        if not isinstance(attempt, dict):
            conflict = True
            return
        existing_turn_id = attempt.get("nativeTurnId")
        candidate_turn_id = turn.get("id") if isinstance(turn, dict) else None
        if (
            isinstance(existing_turn_id, str)
            and existing_turn_id
            and candidate_turn_id != existing_turn_id
        ):
            conflict = True

    try:
        with_authority_lock(lock_path, inspect)
    except (OSError, ValueError, json.JSONDecodeError):
        conflict = True
    return conflict

def observe_server_message(payload):
    try:
        message = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return
    if not isinstance(message, dict):
        return
    binding = None
    with claim_lock:
        binding = claims_by_request.pop(str(message.get("id")), None)
    turn = None
    response_error = isinstance(message.get("error"), dict)
    if binding is not None:
        path, lock_path, attempt_id, kind, expected_thread_id = binding
        if kind == "start":
            result = message.get("result")
            if isinstance(result, dict) and isinstance(result.get("turn"), dict):
                turn = result["turn"]
        else:
            turn = turn_from_thread_read(message, attempt_id, expected_thread_id)
            if turn_conflicts_with_bound_receipt(path, lock_path, attempt_id, turn):
                update_attempt_receipt(
                    path, lock_path, attempt_id, expected_thread_id, turn
                )
                return json.dumps(
                    claim_hold_message(
                        message.get("id"),
                        "native turn identity conflicts with the admitted attempt",
                    ),
                    separators=(",", ":"),
                ).encode("utf-8")
    method = message.get("method")
    params = message.get("params")
    if method in ("turn/started", "turn/completed") and isinstance(params, dict):
        candidate = params.get("turn")
        if isinstance(candidate, dict):
            turn_id = candidate.get("id")
            if isinstance(turn_id, str):
                with claim_lock:
                    turn_binding = claims_by_turn.get(turn_id)
                if turn_binding is not None:
                    path, lock_path, attempt_id, expected_thread_id = turn_binding
                    if params.get("threadId") == expected_thread_id:
                        turn = candidate
    if binding is None and turn is None:
        return None
    update_attempt_receipt(
        path,
        lock_path,
        attempt_id,
        expected_thread_id,
        turn,
        response_error=response_error,
    )
    return None

def expand_runtime_path(value):
    if not isinstance(value, str) or not value:
        return value
    return os.path.abspath(os.path.expanduser(value))

def normalize_runtime_params(params):
    if "cwd" in params:
        params["cwd"] = expand_runtime_path(params["cwd"])
    if isinstance(params.get("runtimeWorkspaceRoots"), list):
        params["runtimeWorkspaceRoots"] = [
            expand_runtime_path(path) for path in params["runtimeWorkspaceRoots"]
        ]
    sandbox_policy = params.get("sandboxPolicy")
    if isinstance(sandbox_policy, dict) and isinstance(sandbox_policy.get("writableRoots"), list):
        sandbox_policy["writableRoots"] = [
            expand_runtime_path(path) for path in sandbox_policy["writableRoots"]
        ]

def normalize_client_request(payload):
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return payload
    params = request.get("params")
    if not isinstance(params, dict):
        return payload
    normalize_runtime_params(params)
    if not claim_turn_start(request):
        return None
    if not track_delivery_read(request):
        return None
    return json.dumps(request, separators=(",", ":")).encode("utf-8")

def forward_stdin():
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return
        payload = normalize_client_request(line.rstrip(b"\r\n"))
        if payload:
            send_frame(0x1, payload)

threading.Thread(target=forward_stdin, daemon=True).start()

def read_exact(count):
    global buffer
    while len(buffer) < count:
        chunk = connection.recv(max(4096, count - len(buffer)))
        if not chunk:
            raise EOFError()
        buffer += chunk
    result, buffer = buffer[:count], buffer[count:]
    return result

fragment_opcode = None
fragments = []
while True:
    try:
        first, second = read_exact(2)
    except EOFError:
        break
    finished = (first & 0x80) != 0
    opcode = first & 0x0f
    masked = (second & 0x80) != 0
    length = second & 0x7f
    if length == 126:
        length = struct.unpack("!H", read_exact(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", read_exact(8))[0]
    if length > 256 * 1024 * 1024:
        raise RuntimeError("Codex daemon WebSocket frame is too large")
    mask = read_exact(4) if masked else None
    payload = read_exact(length)
    if mask is not None:
        payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    if opcode == 0x8:
        break
    if opcode == 0x9:
        send_frame(0xA, payload)
        continue
    if opcode == 0xA:
        continue
    if opcode in (0x1, 0x2):
        fragment_opcode = opcode
        fragments = [payload]
    elif opcode == 0x0 and fragment_opcode is not None:
        fragments.append(payload)
    else:
        continue
    if finished:
        message = b"".join(fragments)
        message = message.rstrip(b"\r\n")
        replacement = observe_server_message(message)
        if replacement is not None:
            message = replacement
        with output_lock:
            sys.stdout.buffer.write(message + b"\n")
            sys.stdout.buffer.flush()
        fragment_opcode = None
        fragments = []
"""#

  public func accountState() async throws -> CodexAccountState {
    let result = try await request(
      method: "account/read",
      params: .object(["refreshToken": .bool(false)])
    )
    guard let object = result.objectValue else {
      throw CodexAppServerError.invalidResponse("account/read had no result object")
    }
    guard let account = object["account"], account != .null else {
      return .signedOut
    }
    guard let type = account["type"]?.stringValue else {
      return .other("Unknown Codex account")
    }
    switch type {
    case "chatgpt":
      return .chatGPT(
        email: account["email"]?.stringValue,
        plan: account["planType"]?.stringValue
      )
    case "apiKey":
      return .apiKey
    default:
      return .other(type)
    }
  }

  public func beginChatGPTLogin() async throws -> CodexLoginStart {
    let result = try await request(
      method: "account/login/start",
      params: .object([
        "type": .string("chatgpt"),
        "useHostedLoginSuccessPage": .bool(true),
        "appBrand": .string("chatgpt")
      ])
    )
    guard let loginID = result["loginId"]?.stringValue,
          let rawURL = result["authUrl"]?.stringValue,
          let authURL = URL(string: rawURL)
    else {
      throw CodexAppServerError.invalidResponse("login response omitted its browser URL")
    }
    return CodexLoginStart(loginID: loginID, authURL: authURL)
  }

  public func listModels(
    refreshingTransportIfOlderThan maximumAge: TimeInterval? = nil
  ) async throws -> [AIChatModelOption] {
    if let maximumAge,
       let modelCatalogLoadedAt,
       Date().timeIntervalSince(modelCatalogLoadedAt) >= max(0, maximumAge),
       pendingRequests.isEmpty,
       pendingTurns.isEmpty,
       startupTask == nil {
      // Codex snapshots its remote model catalog for the lifetime of the app-
      // server process. Rotate an idle transport before refreshing an aged
      // catalog so newly launched models appear without restarting OpenOrg.
      shutdown()
    }

    var models: [AIChatModelOption] = []
    var cursor: String?
    repeat {
      var params: [String: JSONValue] = [
        "limit": .integer(100),
        "includeHidden": .bool(false)
      ]
      if let cursor {
        params["cursor"] = .string(cursor)
      }
      let result = try await request(
        method: "model/list",
        params: .object(params)
      )
      guard let rows = result["data"]?.arrayValue else {
        throw CodexAppServerError.invalidResponse("model/list omitted its model catalog")
      }
      models.append(contentsOf: rows.compactMap(Self.modelOption))
      cursor = result["nextCursor"]?.stringValue
    } while cursor != nil
    modelCatalogLoadedAt = Date()
    return models
  }

  public func listExternalThreads(limit: Int = 100) async throws -> [ExternalThreadSummary] {
    let requestedLimit = max(1, min(limit, 2_000))
    var summaries: [ExternalThreadSummary] = []
    var cursor: String?
    repeat {
      var params: [String: JSONValue] = [
        "limit": .integer(Int64(min(200, requestedLimit - summaries.count))),
        "sortKey": .string("recency_at"),
        "sortDirection": .string("desc"),
        "useStateDbOnly": .bool(true),
        "sourceKinds": .array([
          .string("cli"),
          .string("vscode"),
          .string("appServer"),
          .string("exec"),
          .string("unknown")
        ])
      ]
      if let cursor {
        params["cursor"] = .string(cursor)
      }
      let result = try await request(method: "thread/list", params: .object(params))
      guard let rows = result["data"]?.arrayValue else {
        throw CodexAppServerError.invalidResponse("thread/list omitted its thread catalog")
      }
      summaries.append(contentsOf: rows.compactMap { Self.externalThreadSummary($0) })
      let nextCursor = result["nextCursor"]?.stringValue
      guard nextCursor != cursor else { break }
      cursor = nextCursor
    } while cursor != nil && summaries.count < requestedLimit
    return Array(summaries.prefix(requestedLimit))
  }

  public func searchExternalThreads(
    _ searchTerm: String,
    limit: Int = 100
  ) async throws -> [ExternalThreadSummary] {
    let normalizedSearchTerm = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedSearchTerm.isEmpty else {
      return try await listExternalThreads(limit: limit)
    }
    let requestedLimit = max(1, min(limit, 2_000))
    var summaries: [ExternalThreadSummary] = []
    var cursor: String?
    repeat {
      var params: [String: JSONValue] = [
        "searchTerm": .string(normalizedSearchTerm),
        "limit": .integer(Int64(min(200, requestedLimit - summaries.count))),
        "sortKey": .string("recency_at"),
        "sortDirection": .string("desc"),
        "sourceKinds": .array([
          .string("cli"),
          .string("vscode"),
          .string("appServer"),
          .string("exec"),
          .string("unknown")
        ])
      ]
      if let cursor {
        params["cursor"] = .string(cursor)
      }
      let result = try await request(method: "thread/search", params: .object(params))
      guard let rows = result["data"]?.arrayValue else {
        throw CodexAppServerError.invalidResponse("thread/search omitted its thread catalog")
      }
      summaries.append(contentsOf: rows.compactMap(Self.externalThreadSearchSummary))
      let nextCursor = result["nextCursor"]?.stringValue
      guard nextCursor != cursor else { break }
      cursor = nextCursor
    } while cursor != nil && summaries.count < requestedLimit
    return Array(summaries.prefix(requestedLimit))
  }

  public func readExternalThread(_ externalID: String) async throws -> ExternalThreadDetail {
    let result = try await request(
      method: "thread/read",
      params: .object([
        "threadId": .string(externalID),
        "includeTurns": .bool(false)
      ])
    )
    guard let rawThread = result["thread"],
          let summary = Self.externalThreadSummary(rawThread)
    else {
      throw CodexAppServerError.invalidResponse("thread/read omitted its thread")
    }
    guard let transcriptPath = rawThread["path"]?.stringValue,
          !transcriptPath.isEmpty
    else {
      throw CodexRolloutTranscriptError.pathUnavailable
    }
    let transcriptURL = URL(fileURLWithPath: transcriptPath).standardizedFileURL
    guard FileManager.default.isReadableFile(atPath: transcriptURL.path) else {
      throw CodexRolloutTranscriptError.pathUnavailable
    }
    return ExternalThreadDetail(
      thread: summary,
      messages: try await CodexRolloutTranscriptReader.messages(at: transcriptURL)
    )
  }

  public func ensureThread(
    existingThreadID: String?,
    cwd: URL,
    model: String? = nil,
    sandboxAccess: CodexSandboxAccess = .workspaceWrite
  ) async throws -> String {
    try await ensureThread(
      existingThreadID: existingThreadID,
      workspacePath: cwd.standardizedFileURL.path,
      corpusAccess: .clientWorkspaceTools,
      model: model,
      sandboxAccess: sandboxAccess
    )
  }

  public func ensureThread(
    existingThreadID: String?,
    workspacePath: String,
    corpusAccess: CodexCorpusAccess,
    model: String? = nil,
    sandboxAccess: CodexSandboxAccess = .workspaceWrite
  ) async throws -> String {
    try await connect()
    let developerInstructions = Self.developerInstructions(for: corpusAccess)
    if let existingThreadID {
      if !loadedThreadIDs.contains(existingThreadID) {
        var params: [String: JSONValue] = [
          "threadId": .string(existingThreadID),
          "cwd": .string(workspacePath),
          "approvalPolicy": .string("never"),
          "sandbox": .string(sandboxAccess.threadSandboxValue),
          "developerInstructions": .string(developerInstructions)
        ]
        if let model {
          params["model"] = .string(model)
        }
        let result: JSONValue
        do {
          result = try await requestRaw(
            method: "thread/resume",
            params: .object(params),
            timeoutNanoseconds: threadResumeRequestTimeoutNanoseconds
          )
        } catch let error as CodexAppServerError {
          if case .requestTimedOut("thread/resume") = error {
            // A large rollout can finish loading after the caller's deadline.
            // If that late response is ignored while this process keeps its
            // writer lock, every later retry attempts to resume an already
            // resumed thread and can never recover. Tear down the transport so
            // the next Retry starts from a clean app-server process.
            shutdown()
          }
          throw error
        }
        guard result["thread"]?["id"]?.stringValue == existingThreadID else {
          throw CodexAppServerError.invalidResponse("thread/resume returned a different thread")
        }
        loadedThreadIDs.insert(existingThreadID)
      }
      return existingThreadID
    }

    var params: [String: JSONValue] = [
      "cwd": .string(workspacePath),
      "approvalPolicy": .string("never"),
      "sandbox": .string(sandboxAccess.threadSandboxValue),
      "serviceName": .string(
        corpusAccess == .runtimeFilesystem ? "org2_runtime_workspace" : "org2_workspace"
      ),
      "developerInstructions": .string(developerInstructions),
      "dynamicTools": .array(Self.dynamicTools(for: corpusAccess))
    ]
    if let model {
      params["model"] = .string(model)
    }
    let result = try await requestRaw(
      method: "thread/start",
      params: .object(params)
    )
    guard let threadID = result["thread"]?["id"]?.stringValue else {
      throw CodexAppServerError.invalidResponse("thread/start omitted the thread id")
    }
    loadedThreadIDs.insert(threadID)
    return threadID
  }

  public func ensureThreadRecoveringStaleSession(
    existingThreadID: String?,
    cwd: URL,
    model: String? = nil,
    sandboxAccess: CodexSandboxAccess = .workspaceWrite,
    allowsFreshReplacement: Bool = true
  ) async throws -> CodexThreadResolution {
    try await ensureThreadRecoveringStaleSession(
      existingThreadID: existingThreadID,
      workspacePath: cwd.standardizedFileURL.path,
      corpusAccess: .clientWorkspaceTools,
      model: model,
      sandboxAccess: sandboxAccess,
      allowsFreshReplacement: allowsFreshReplacement
    )
  }

  public func ensureThreadRecoveringStaleSession(
    existingThreadID: String?,
    workspacePath: String,
    corpusAccess: CodexCorpusAccess,
    model: String? = nil,
    sandboxAccess: CodexSandboxAccess = .workspaceWrite,
    allowsFreshReplacement: Bool = true
  ) async throws -> CodexThreadResolution {
    guard let existingThreadID else {
      return CodexThreadResolution(
        threadID: try await ensureThread(
          existingThreadID: nil,
          workspacePath: workspacePath,
          corpusAccess: corpusAccess,
          model: model,
          sandboxAccess: sandboxAccess
        ),
        replacedStaleThread: false
      )
    }
    do {
      return CodexThreadResolution(
        threadID: try await ensureThread(
          existingThreadID: existingThreadID,
          workspacePath: workspacePath,
          corpusAccess: corpusAccess,
          model: model,
          sandboxAccess: sandboxAccess
        ),
        replacedStaleThread: false
      )
    } catch let error as CodexAppServerError {
      guard allowsFreshReplacement,
            Self.canRecoverByStartingFresh(after: error)
      else { throw error }
      // Reopening an old Codex task can fail when a previous OpenOrg process
      // died while holding its writer lease, or when the task can no longer be
      // resumed by this app-server. The user message has not been submitted at
      // this point, so it is safe to replace the stale task with a fresh one.
      shutdown()
      return CodexThreadResolution(
        threadID: try await ensureThread(
          existingThreadID: nil,
          workspacePath: workspacePath,
          corpusAccess: corpusAccess,
          model: model,
          sandboxAccess: sandboxAccess
        ),
        replacedStaleThread: true
      )
    }
  }

  nonisolated private static func canRecoverByStartingFresh(
    after error: CodexAppServerError
  ) -> Bool {
    switch error {
    case .requestTimedOut("thread/resume"), .disconnected:
      true
    case .server(_, let message):
      message.localizedCaseInsensitiveContains("active writer")
        || message.localizedCaseInsensitiveContains("writer lock")
        || message.localizedCaseInsensitiveContains("no rollout found")
        || message.localizedCaseInsensitiveContains("not found")
        || message.localizedCaseInsensitiveContains("does not exist")
        || message.localizedCaseInsensitiveContains("unknown thread")
    case .invalidResponse(let detail):
      detail.localizedCaseInsensitiveContains("thread/resume returned a different thread")
    case .executableNotFound, .launchFailed, .notAuthenticated,
         .requestTimedOut, .turnStartUnknown, .turnFailed, .turnInterrupted:
      false
    }
  }

  public func runTurn(
    threadID: String,
    turnID localTurnID: String,
    message: String,
    workspaceContext: String? = nil,
    attachments: [AIChatAttachment],
    cwd: URL,
    attemptIdentity: CodexTurnAttemptIdentity,
    turnStartPolicy: CodexTurnStartPolicy = .startIfAbsent,
    model: String? = nil,
    reasoningEffort: String? = nil,
    sandboxAccess: CodexSandboxAccess = .workspaceWrite
  ) async throws -> CodexTurnResult {
    try await runTurn(
      threadID: threadID,
      turnID: localTurnID,
      message: message,
      workspaceContext: workspaceContext,
      attachments: attachments,
      workspacePath: cwd.standardizedFileURL.path,
      corpusAccess: .clientWorkspaceTools,
      attemptIdentity: attemptIdentity,
      turnStartPolicy: turnStartPolicy,
      model: model,
      reasoningEffort: reasoningEffort,
      sandboxAccess: sandboxAccess
    )
  }

  public func runTurn(
    threadID: String,
    turnID localTurnID: String,
    message: String,
    workspaceContext: String? = nil,
    attachments: [AIChatAttachment],
    workspacePath: String,
    corpusAccess: CodexCorpusAccess,
    attemptIdentity: CodexTurnAttemptIdentity,
    turnStartPolicy: CodexTurnStartPolicy = .startIfAbsent,
    model: String? = nil,
    reasoningEffort: String? = nil,
    sandboxAccess: CodexSandboxAccess = .workspaceWrite
  ) async throws -> CodexTurnResult {
    try await connect()
    var input: [JSONValue] = [
      .object([
        "type": .string("text"),
        "text": .string(
          Self.wrappedUserMessage(
            message,
            localTurnID: localTurnID,
            workspaceContext: workspaceContext,
            corpusAccess: corpusAccess
          )
        )
      ])
    ]
    input.append(contentsOf: try attachments.map {
      .object([
        "type": .string("image"),
        "url": .string(try $0.loadedDataURLString())
      ])
    })
    var params: [String: JSONValue] = [
      "threadId": .string(threadID),
      "input": .array(input),
      "cwd": .string(workspacePath),
      "approvalPolicy": .string("never"),
      "sandboxPolicy": sandboxAccess.turnSandboxPolicy(workspacePath: workspacePath),
      "clientUserMessageId": .string(attemptIdentity.attemptID.uuidString.lowercased())
    ]
    params["model"] = model.map(JSONValue.string) ?? .null
    params["effort"] = reasoningEffort.map(JSONValue.string) ?? .null
    if case .managedRemote = transport {
      if let existingTurn = try await reconciledTurn(
        threadID: threadID,
        attemptIdentity: attemptIdentity,
        expectedStartParams: params,
        attempts: 3
      ) {
        return try await finishReconciledTurn(existingTurn, threadID: threadID)
      }
      if case .reconcileOnly = turnStartPolicy {
        throw CodexAppServerError.turnStartUnknown(
          "The matching native attempt is not visible with its exact request contract; delivery remains held for reconciliation."
        )
      }
    }
    if case .managedRemote = transport {
      var deliveryContract: [String: JSONValue] = [
        "schema": .string("celorga:managed-remote-delivery:v3"),
        "messageId": .string(attemptIdentity.messageID.uuidString.lowercased()),
        "attemptId": .string(attemptIdentity.attemptID.uuidString.lowercased()),
        "threadId": .string(threadID)
      ]
      if let predecessorAttemptID = attemptIdentity.predecessorAttemptID {
        deliveryContract["predecessorAttemptId"] = .string(
          predecessorAttemptID.uuidString.lowercased()
        )
      }
      params["celorgaDelivery"] = .object(deliveryContract)
    }
    let result: JSONValue
    do {
      result = try await requestRaw(
        method: "turn/start",
        params: .object(params),
        trackSubmission: true
      )
    } catch let submissionError as RequestSubmissionError {
      guard case .managedRemote = transport, submissionError.submissionStarted else {
        throw submissionError.underlying
      }
      if !Task.isCancelled {
        if let acceptedTurn = try? await reconciledTurn(
          threadID: threadID,
          attemptIdentity: attemptIdentity,
          expectedStartParams: params.filter { $0.key != "celorgaDelivery" },
          attempts: 4
        ) {
          return try await finishReconciledTurn(acceptedTurn, threadID: threadID)
        }
      }
      throw CodexAppServerError.turnStartUnknown(
        "The turn/start outcome is not confirmed; delivery remains held and no second start was sent."
      )
    }
    guard let returnedTurn = result["turn"],
          returnedTurn["id"]?.stringValue != nil,
          let returnedStatus = returnedTurn["status"]?.stringValue,
          returnedStatus == "inProgress"
            || (CodexTurnResult.Status(rawValue: returnedStatus) != nil
              && returnedStatus != CodexTurnResult.Status.unknown.rawValue)
    else {
      if let acceptedTurn = try? await reconciledTurn(
        threadID: threadID,
        attemptIdentity: attemptIdentity,
        expectedStartParams: params.filter { $0.key != "celorgaDelivery" },
        attempts: 4
      ) {
        return try await finishReconciledTurn(acceptedTurn, threadID: threadID)
      }
      throw CodexAppServerError.turnStartUnknown(
        "Codex responded without an exact recognized turn ID and status; delivery remains held and no second start was sent."
      )
    }
    return try await finishReconciledTurn(returnedTurn, threadID: threadID)
  }

  private func reconciledTurn(
    threadID: String,
    attemptIdentity: CodexTurnAttemptIdentity,
    expectedStartParams: [String: JSONValue],
    attempts: Int
  ) async throws -> JSONValue? {
    let clientID = attemptIdentity.attemptID.uuidString.lowercased()
    for attempt in 0..<max(1, attempts) {
      var params: [String: JSONValue] = [
        "threadId": .string(threadID),
        "includeTurns": .bool(true)
      ]
      if case .managedRemote = transport {
        params["celorgaDeliveryRead"] = .object([
          "schema": .string("celorga:managed-remote-delivery:v3"),
          "messageId": .string(attemptIdentity.messageID.uuidString.lowercased()),
          "attemptId": .string(clientID),
          "threadId": .string(threadID),
          "startParams": .object(expectedStartParams)
        ])
        if let predecessorAttemptID = attemptIdentity.predecessorAttemptID {
          var deliveryRead = params["celorgaDeliveryRead"]?.objectValue ?? [:]
          deliveryRead["predecessorAttemptId"] = .string(
            predecessorAttemptID.uuidString.lowercased()
          )
          params["celorgaDeliveryRead"] = .object(deliveryRead)
        }
      }
      let result: JSONValue
      do {
        result = try await request(method: "thread/read", params: .object(params))
      } catch let error as CodexAppServerError {
        if case .server(let code, _) = error, code == -32097 {
          return nil
        }
        if case .server(let code, let message) = error, code == -32098 {
          throw CodexAppServerError.turnStartUnknown(message)
        }
        throw error
      }
      guard result["thread"]?["id"]?.stringValue == threadID else {
        if attempt + 1 < attempts {
          try await Task.sleep(nanoseconds: 250_000_000 << attempt)
        }
        continue
      }
      if let turn = result["thread"]?["turns"]?.arrayValue?.last(where: { turn in
        (turn["items"]?.arrayValue ?? []).contains(where: { item in
          item["type"]?.stringValue == "userMessage"
            && item["clientId"]?.stringValue?.lowercased() == clientID
        })
      }) {
        return turn
      }
      if attempt + 1 < attempts {
        try await Task.sleep(nanoseconds: 250_000_000 << attempt)
      }
    }
    return nil
  }

  private func finishReconciledTurn(
    _ turn: JSONValue,
    threadID: String
  ) async throws -> CodexTurnResult {
    guard let turnID = turn["id"]?.stringValue, !turnID.isEmpty else {
      throw CodexAppServerError.turnStartUnknown(
        "The matching native turn has no usable ID; delivery remains held."
      )
    }
    let pending = pendingTurns[turnID] ?? PendingTurn()
    pending.threadID = threadID
    pendingTurns[turnID] = pending
    guard let status = turn["status"]?.stringValue else {
      throw CodexAppServerError.turnStartUnknown(
        "The matching native turn has no provider status; delivery remains held."
      )
    }
    guard status == "inProgress"
      || (CodexTurnResult.Status(rawValue: status) != nil
        && status != CodexTurnResult.Status.unknown.rawValue)
    else {
      throw CodexAppServerError.turnStartUnknown(
        "The matching native turn has unsupported status \(status); delivery remains held."
      )
    }
    await reportTurnStarted(threadID: threadID, turnID: turnID)
    if status == "inProgress" {
      // Only an SSH-bridged daemon can lose turn notifications while the turn
      // keeps running. A local or WebSocket app server delivers turn/completed
      // on the live transport, and transportEnded resolves the turn otherwise.
      if case .managedRemote = transport {
        scheduleManagedRemoteTurnRecovery()
      }
    } else {
      completeTurn(.object([
        "threadId": .string(threadID),
        "turn": turn
      ]))
    }
    let result = await waitForTurn(threadID: threadID, turnID: turnID)
    if Task.isCancelled, result.status == .interrupted {
      throw CodexAppServerError.turnStartUnknown(
        "Celorga stopped waiting after Codex accepted turn \(turnID); delivery remains held for reconciliation."
      )
    }
    await reportTurnTerminal(result)
    return try Self.requireSuccessfulTurn(result)
  }

  nonisolated static func isRecognizedTerminalTurnStatus(_ status: String) -> Bool {
    guard let parsed = CodexTurnResult.Status(rawValue: status) else { return false }
    return parsed != .unknown
  }

  nonisolated private static func requireSuccessfulTurn(
    _ turnResult: CodexTurnResult
  ) throws -> CodexTurnResult {
    switch turnResult.status {
    case .completed:
      return turnResult
    case .interrupted:
      throw CodexAppServerError.turnInterrupted
    case .unknown:
      throw CodexAppServerError.turnStartUnknown(
        "Codex reported a terminal event without a recognized native status; delivery remains held."
      )
    case .failed:
      throw CodexAppServerError.turnFailed(turnResult.errorMessage ?? "unknown failure")
    }
  }

  public func interrupt(threadID: String, turnID: String) async throws {
    _ = try await request(
      method: "turn/interrupt",
      params: .object([
        "threadId": .string(threadID),
        "turnId": .string(turnID)
      ])
    )
  }

  public func steer(
    threadID: String,
    expectedTurnID: String,
    message: String,
    attachments: [AIChatAttachment] = []
  ) async throws {
    try await connect()
    var input: [JSONValue] = [
      .object([
        "type": .string("text"),
        "text": .string(message)
      ])
    ]
    input.append(contentsOf: try attachments.map {
      .object([
        "type": .string("image"),
        "url": .string(try $0.loadedDataURLString())
      ])
    })
    let result = try await requestRaw(
      method: "turn/steer",
      params: .object([
        "threadId": .string(threadID),
        "input": .array(input),
        "expectedTurnId": .string(expectedTurnID)
      ])
    )
    guard result["turnId"]?.stringValue == expectedTurnID else {
      throw CodexAppServerError.invalidResponse("turn/steer returned a different turn id")
    }
  }

  public func shutdown() {
    managedRemoteRecoveryTask?.cancel()
    managedRemoteRecoveryTask = nil
    let processToStop = process
    process = nil
    standardOutput?.readabilityHandler = nil
    standardError?.readabilityHandler = nil
    standardOutput = nil
    standardError = nil
    standardInput = nil
    initialized = false
    startupTask = nil
    outputBuffer = Data()
    loadedThreadIDs.removeAll()
    modelCatalogLoadedAt = nil
    if let processToStop, processToStop.isRunning {
      processToStop.terminate()
      // A wedged app-server can ignore SIGTERM while retaining Codex's
      // advisory task-writer lock. This client has already discarded its
      // transport, so leaving that orphan alive only makes every later Retry
      // fail. Force the abandoned child down before another connection starts.
      if processToStop.isRunning {
        _ = Darwin.kill(processToStop.processIdentifier, SIGKILL)
      }
    }
    webSocketReceiveTask?.cancel()
    webSocketReceiveTask = nil
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    failPendingRequests(CodexAppServerError.disconnected("client shut down"))
  }

  private func connect() async throws {
    if initialized, transportIsConnected {
      return
    }
    if let startupTask {
      return try await startupTask.value
    }
    let task = Task { [weak self] in
      guard let self else {
        throw CodexAppServerError.disconnected("client was released")
      }
      do {
        try await self.performConnect()
      } catch {
        // The app-server can accept initialize after our request has timed
        // out. Reusing that transport would send initialize a second time and
        // poison every Codex thread with "Already initialized". Reset inside
        // the shared startup task so concurrent waiters rotate it only once.
        await self.shutdown()
        throw error
      }
    }
    startupTask = task
    do {
      try await task.value
      startupTask = nil
    } catch {
      startupTask = nil
      throw error
    }
  }

  private var transportIsConnected: Bool {
    switch transport {
    case .local, .managedRemote: process?.isRunning == true
    case .remote: webSocketTask != nil
    }
  }

  nonisolated private static func modelOption(_ value: JSONValue) -> AIChatModelOption? {
    guard let id = value["id"]?.stringValue,
          !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return nil
    }
    let reasoningOptions = value["supportedReasoningEfforts"]?.arrayValue?
      .compactMap { option -> AIChatReasoningOption? in
        guard let effort = option["reasoningEffort"]?.stringValue else { return nil }
        return AIChatReasoningOption(
          id: effort,
          label: Self.reasoningLabel(effort),
          detail: option["description"]?.stringValue
        )
      } ?? []
    return AIChatModelOption(
      id: id,
      label: value["displayName"]?.stringValue ?? id,
      detail: value["description"]?.stringValue,
      supportsReasoning: !reasoningOptions.isEmpty,
      reasoningOptions: reasoningOptions,
      defaultReasoningEffort: value["defaultReasoningEffort"]?.stringValue,
      isDefault: value["isDefault"]?.boolValue ?? false
    )
  }

  nonisolated static func externalThreadSummary(
    _ value: JSONValue,
    previewOverride: String? = nil
  ) -> ExternalThreadSummary? {
    guard let externalID = value["id"]?.stringValue else { return nil }
    let preview = normalizedExternalText(previewOverride)
      ?? normalizedExternalText(value["preview"]?.stringValue)
    let name = normalizedExternalText(value["name"]?.stringValue)
    let fallbackTitle = preview?
      .split(separator: "\n", omittingEmptySubsequences: true)
      .first
      .map(String.init)
    let title = String((name ?? fallbackTitle ?? "Untitled Codex task").prefix(180))
    let createdAt = Date(timeIntervalSince1970: externalTimestamp(value["createdAt"]) ?? 0)
    let updatedAt = Date(timeIntervalSince1970: externalTimestamp(value["updatedAt"]) ?? createdAt.timeIntervalSince1970)
    return ExternalThreadSummary(
      harness: .codex,
      externalID: externalID,
      title: title,
      preview: preview.map { String($0.prefix(500)) },
      workspacePath: normalizedExternalText(value["cwd"]?.stringValue),
      source: normalizedExternalText(value["source"]?.stringValue),
      modelProvider: normalizedExternalText(value["modelProvider"]?.stringValue),
      createdAt: createdAt,
      updatedAt: updatedAt,
      status: value["status"]?["type"]?.stringValue ?? "unknown",
      isPinned: value["isPinned"]?.boolValue ?? false
    )
  }

  nonisolated static func externalThreadSearchSummary(_ value: JSONValue) -> ExternalThreadSummary? {
    guard let thread = value["thread"] else { return nil }
    return externalThreadSummary(thread, previewOverride: value["snippet"]?.stringValue)
  }

  nonisolated static func externalThreadMessages(_ thread: JSONValue) -> [ExternalThreadMessage] {
    guard let turns = thread["turns"]?.arrayValue else { return [] }
    return turns.enumerated().flatMap { turnIndex, turn in
      let timestamp = Date(timeIntervalSince1970: externalTimestamp(turn["startedAt"]) ?? 0)
      return (turn["items"]?.arrayValue ?? []).enumerated().compactMap { itemIndex, item -> ExternalThreadMessage? in
        guard let type = item["type"]?.stringValue else { return nil }
        let role: ExternalThreadMessage.Role
        let content: String?
        switch type {
        case "userMessage":
          role = .user
          content = item["content"]?.arrayValue?
            .compactMap { part in
              guard part["type"]?.stringValue == "text" else { return nil }
              return part["text"]?.stringValue
            }
            .joined(separator: "\n")
        case "agentMessage":
          role = .assistant
          content = item["text"]?.stringValue
        default:
          return nil
        }
        guard let normalized = normalizedExternalText(content) else { return nil }
        let id = item["id"]?.stringValue ?? "turn-\(turnIndex)-item-\(itemIndex)"
        return ExternalThreadMessage(id: id, role: role, content: normalized, createdAt: timestamp)
      }
    }
  }

  nonisolated private static func normalizedExternalText(_ value: String?) -> String? {
    guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !normalized.isEmpty
    else { return nil }
    return normalized
  }

  nonisolated private static func externalTimestamp(_ value: JSONValue?) -> TimeInterval? {
    switch value {
    case .integer(let seconds): Double(seconds)
    case .number(let seconds): seconds
    default: nil
    }
  }

  nonisolated private static func reasoningLabel(_ value: String) -> String {
    switch value.lowercased() {
    case "off", "none": return "Off"
    case "minimal": return "Minimal"
    case "low": return "Low"
    case "medium": return "Medium"
    case "high": return "High"
    case "xhigh": return "Extra high"
    case "max": return "Maximum"
    case "ultra": return "Ultra"
    case "adaptive": return "Adaptive"
    default:
      return value
        .replacingOccurrences(of: "_", with: " ")
        .replacingOccurrences(of: "-", with: " ")
        .capitalized
    }
  }

  private func performConnect() async throws {
    if !transportIsConnected {
      switch transport {
      case .local, .managedRemote:
        try launch()
      case .remote(let endpoint, let bearerToken):
        try connectRemote(endpoint: endpoint, bearerToken: bearerToken)
      }
    }
    _ = try await requestRaw(
      method: "initialize",
      params: .object([
        "clientInfo": .object([
          "name": .string("org2_workspace"),
          "title": .string(WorkspaceProductIdentity.displayName),
          "version": .string(Self.clientVersion)
        ]),
        "capabilities": .object([
          "experimentalApi": .bool(true)
        ])
      ]),
      timeoutNanoseconds: initializeRequestTimeoutNanoseconds
    )
    try await sendMessage(.object([
      "method": .string("initialized"),
      "params": .object([:])
    ]))
    initialized = true
    await eventHandler(.connectionChanged(
      isConnected: true,
      detail: transport == .local ? executableURL?.path : transport.connectionDescription
    ))
  }

  private func connectRemote(endpoint: URL, bearerToken: String?) throws {
    guard endpoint.scheme?.lowercased() == "ws" || endpoint.scheme?.lowercased() == "wss" else {
      throw CodexAppServerError.invalidResponse("remote Codex endpoint must use ws:// or wss://")
    }
    var request = URLRequest(url: endpoint)
    if let bearerToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines),
       !bearerToken.isEmpty {
      request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    }
    let socket = URLSession.shared.webSocketTask(with: request)
    webSocketTask = socket
    socket.resume()
    webSocketReceiveTask = Task { [weak self] in
      do {
        while !Task.isCancelled {
          let message = try await socket.receive()
          await self?.receiveWebSocketMessage(message)
        }
      } catch {
        guard !Task.isCancelled else { return }
        await self?.transportEnded(error.localizedDescription)
      }
    }
  }

  private func launch() throws {
    let launchURL: URL
    let arguments: [String]
    switch transport {
    case .local:
      if let executableResolver {
        // Codex Desktop can replace or relocate its embedded CLI while
        // OpenOrg is running. Resolve again whenever a fresh local transport
        // launches so Refresh Options follows the updated installation.
        executableURL = executableResolver()
      }
      guard let executableURL else {
        throw CodexAppServerError.executableNotFound
      }
      launchURL = executableURL
      arguments = ["app-server", "--listen", "stdio://"]
    case .managedRemote(let sshHost):
      launchURL = sshExecutableURL
      arguments = try Self.managedRemoteSSHArguments(sshHost: sshHost)
    case .remote:
      throw CodexAppServerError.invalidResponse(
        "WebSocket Codex destinations cannot launch a subprocess transport"
      )
    }
    let process = Process()
    process.executableURL = launchURL
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    if case .local = transport {
      process.environment = LocalAgentExecutableLocator.processEnvironment(
        ProcessInfo.processInfo.environment,
        executableURL: launchURL
      )
    } else {
      process.environment = ProcessInfo.processInfo.environment
    }

    let input = Pipe()
    let output = Pipe()
    let error = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = error
    do {
      try process.run()
    } catch {
      throw CodexAppServerError.launchFailed(error.localizedDescription)
    }
    self.process = process
    standardInput = input.fileHandleForWriting
    latestStderr = ""
    startReaders(
      stdout: output.fileHandleForReading,
      stderr: error.fileHandleForReading
    )
  }

  private func receiveWebSocketMessage(_ message: URLSessionWebSocketTask.Message) async {
    switch message {
    case .string(let text):
      await receiveLine(Data(text.utf8))
    case .data(let data):
      await receiveLine(data)
    @unknown default:
      await eventHandler(.warning(threadID: nil, message: "Ignored an unknown Codex WebSocket frame."))
    }
  }

  private func startReaders(stdout: FileHandle, stderr: FileHandle) {
    standardOutput = stdout
    standardError = stderr
    outputBuffer = Data()
    stdout.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      Task {
        await self?.receiveOutput(data)
      }
    }
    stderr.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      Task {
        await self?.recordStderr(data)
      }
    }
  }

  private func receiveOutput(_ data: Data) async {
    guard !data.isEmpty else {
      if !outputBuffer.isEmpty {
        let finalLine = outputBuffer
        outputBuffer = Data()
        await receiveLine(finalLine)
      }
      await transportEnded()
      return
    }
    outputBuffer.append(data)
    while let newline = outputBuffer.firstIndex(of: 0x0A) {
      let line = Data(outputBuffer[..<newline])
      outputBuffer.removeSubrange(...newline)
      if !line.isEmpty {
        await receiveLine(line)
      }
    }
  }

  private func recordStderr(_ data: Data) {
    let text = String(decoding: data, as: UTF8.self)
    latestStderr = String((latestStderr + text).suffix(4_000))
  }

  private func transportEnded(_ detail: String? = nil) async {
    guard process != nil || webSocketTask != nil else { return }
    let stderr = latestStderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = detail ?? (stderr.isEmpty ? "connection closed" : stderr)
    process = nil
    webSocketReceiveTask?.cancel()
    webSocketReceiveTask = nil
    webSocketTask?.cancel(with: .goingAway, reason: nil)
    webSocketTask = nil
    standardInput = nil
    standardOutput?.readabilityHandler = nil
    standardError?.readabilityHandler = nil
    standardOutput = nil
    standardError = nil
    outputBuffer = Data()
    initialized = false
    startupTask = nil
    loadedThreadIDs.removeAll()
    failPendingRequests(CodexAppServerError.disconnected(message))
    if case .managedRemote = transport,
       pendingTurns.values.contains(where: { $0.completedResult == nil }) {
      scheduleManagedRemoteTurnRecovery()
      reportedRecoveryDisconnect = true
      await eventHandler(.connectionChanged(
        isConnected: false,
        detail: "\(message). The remote turn is still owned by Codex and will reconnect."
      ))
      return
    }
    for turnID in Array(pendingTurns.keys) {
      guard let pending = pendingTurns[turnID] else { continue }
      guard pending.completedResult == nil else { continue }
      if pending.pendingCompletionResult != nil {
        finalizePendingTurn(turnID)
        continue
      }
      let result = CodexTurnResult(
        threadID: "",
        turnID: turnID,
        status: .failed,
        reply: pending.finalReply.isEmpty ? pending.streamedReply : pending.finalReply,
        errorMessage: message,
        usage: pending.usage
      )
      resolvePendingTurn(turnID, with: result)
    }
    await eventHandler(.connectionChanged(isConnected: false, detail: message))
  }

  private func scheduleManagedRemoteTurnRecovery() {
    guard managedRemoteRecoveryTask == nil else { return }
    managedRemoteRecoveryTask = Task { [weak self] in
      guard let self else { return }
      await self.recoverManagedRemoteTurns()
      await self.clearManagedRemoteRecoveryTask()
    }
  }

  private func clearManagedRemoteRecoveryTask() {
    managedRemoteRecoveryTask = nil
  }

  private func recoverManagedRemoteTurns() async {
    var delayNanoseconds: UInt64 = 1_000_000_000
    while !Task.isCancelled {
      let recoverable = pendingTurns.compactMap { turnID, pending -> (String, String)? in
        guard pending.completedResult == nil, let threadID = pending.threadID else { return nil }
        return (threadID, turnID)
      }
      guard !recoverable.isEmpty else { return }

      do {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        try Task.checkCancellation()
        for (threadID, turnID) in recoverable {
          guard pendingTurns[turnID]?.completedResult == nil else { continue }
          let result = try await request(
            method: "thread/read",
            params: .object([
              "threadId": .string(threadID),
              "includeTurns": .bool(true)
            ])
          )
          guard let turn = result["thread"]?["turns"]?.arrayValue?.first(where: {
            $0["id"]?.stringValue == turnID
          }) else {
            continue
          }
          // Only a recognized terminal status is completion evidence. A missing,
          // in-progress, or unfamiliar status means the turn is still Codex's;
          // resolving it here would fail a message Codex is still answering.
          guard let status = turn["status"]?.stringValue,
                Self.isRecognizedTerminalTurnStatus(status)
          else { continue }
          guard let pending = pendingTurns[turnID], pending.completedResult == nil else {
            continue
          }
          completeTurn(.object([
            "threadId": .string(threadID),
            "turn": turn
          ]))
        }
        if reportedRecoveryDisconnect {
          reportedRecoveryDisconnect = false
          await eventHandler(.connectionChanged(isConnected: true, detail: nil))
        }
        delayNanoseconds = 2_000_000_000
      } catch is CancellationError {
        return
      } catch {
        reportedRecoveryDisconnect = true
        await eventHandler(.connectionChanged(
          isConnected: false,
          detail: "The remote turn is still saved; reconnecting after \(error.localizedDescription)"
        ))
        delayNanoseconds = min(delayNanoseconds * 2, 30_000_000_000)
      }
    }
  }

  private func request(method: String, params: JSONValue) async throws -> JSONValue {
    try await connect()
    return try await requestRaw(method: method, params: params)
  }

  private func requestRaw(
    method: String,
    params: JSONValue,
    timeoutNanoseconds: UInt64? = nil,
    trackSubmission: Bool = false
  ) async throws -> JSONValue {
    requestCounter &+= 1
    let requestID = requestCounter
    let key = String(requestID)
    let effectiveTimeoutNanoseconds = timeoutNanoseconds ?? requestTimeoutNanoseconds
    do {
      let result = try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<JSONValue, Error>) in
          if cancelledRequestKeys.remove(key) != nil || Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
          }
          pendingRequests[key] = continuation
          pendingRequestTimeoutTasks[key] = Task { [weak self] in
            do {
              try await Task.sleep(nanoseconds: effectiveTimeoutNanoseconds)
            } catch {
              return
            }
            await self?.failPendingRequest(
              key: key,
              error: CodexAppServerError.requestTimedOut(method)
            )
          }
          Task { [weak self] in
            await self?.sendPendingRequest(
              key: key,
              requestID: requestID,
              method: method,
              params: params,
              trackSubmission: trackSubmission
            )
          }
        }
      } onCancel: {
        Task { [weak self] in
          await self?.cancelPendingRequest(key: key)
        }
      }
      submittedRequestKeys.remove(key)
      return result
    } catch {
      let submissionStarted = submittedRequestKeys.remove(key) != nil
      if trackSubmission {
        throw RequestSubmissionError(
          underlying: error,
          submissionStarted: submissionStarted
        )
      }
      throw error
    }
  }

  private func sendPendingRequest(
    key: String,
    requestID: Int64,
    method: String,
    params: JSONValue,
    trackSubmission: Bool
  ) async {
    guard pendingRequests[key] != nil else { return }
    do {
      try await sendMessage(.object([
        "id": .integer(requestID),
        "method": .string(method),
        "params": params
      ]), submissionKey: trackSubmission ? key : nil)
    } catch {
      failPendingRequest(key: key, error: error)
    }
  }

  private func failPendingRequest(key: String, error: Error) {
    pendingRequestTimeoutTasks.removeValue(forKey: key)?.cancel()
    pendingRequests.removeValue(forKey: key)?.resume(throwing: error)
  }

  private func cancelPendingRequest(key: String) {
    if pendingRequests[key] == nil {
      cancelledRequestKeys.insert(key)
      return
    }
    failPendingRequest(key: key, error: CancellationError())
  }

  private func sendMessage(
    _ message: JSONValue,
    submissionKey: String? = nil
  ) async throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let data = try encoder.encode(message)
    switch transport {
    case .local, .managedRemote:
      guard let standardInput, process?.isRunning == true else {
        throw CodexAppServerError.disconnected("app server is not running")
      }
      var line = data
      line.append(0x0A)
      do {
        if let submissionKey {
          submittedRequestKeys.insert(submissionKey)
        }
        try standardInput.write(contentsOf: line)
      } catch {
        throw CodexAppServerError.disconnected(error.localizedDescription)
      }
    case .remote:
      guard let webSocketTask else {
        throw CodexAppServerError.disconnected("remote app server is not connected")
      }
      if let submissionKey {
        submittedRequestKeys.insert(submissionKey)
      }
      try await webSocketTask.send(.string(String(decoding: data, as: UTF8.self)))
    }
  }

  private func receiveLine(_ data: Data) async {
    let message: JSONValue
    do {
      message = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      await eventHandler(.warning(
        threadID: nil,
        message: "Ignored an invalid Codex protocol message."
      ))
      return
    }
    guard let object = message.objectValue else { return }
    if let method = object["method"]?.stringValue {
      if let id = object["id"] {
        await handleServerRequest(id: id, method: method, params: object["params"] ?? .object([:]))
      } else {
        await handleNotification(method: method, params: object["params"] ?? .object([:]))
      }
      return
    }
    guard let id = object["id"], let key = Self.requestKey(id),
          let continuation = pendingRequests.removeValue(forKey: key)
    else {
      return
    }
    pendingRequestTimeoutTasks.removeValue(forKey: key)?.cancel()
    if let error = object["error"], error != .null {
      continuation.resume(throwing: CodexAppServerError.server(
        code: error["code"].flatMap(Self.integer),
        message: error["message"]?.stringValue ?? "unknown app-server error"
      ))
    } else if let result = object["result"] {
      continuation.resume(returning: result)
    } else {
      continuation.resume(throwing: CodexAppServerError.invalidResponse("missing result"))
    }
  }

  private func handleServerRequest(id: JSONValue, method: String, params: JSONValue) async {
    guard method == "item/tool/call",
          let callID = params["callId"]?.stringValue,
          let threadID = params["threadId"]?.stringValue,
          let turnID = params["turnId"]?.stringValue,
          let tool = params["tool"]?.stringValue
    else {
      do {
        try await sendMessage(.object([
          "id": id,
          "error": .object([
            "code": .integer(-32601),
            "message": .string("Celorga does not support \(method)")
          ])
        ]))
      } catch {
        // The process-exit path will surface a transport failure.
      }
      return
    }
    let call = CodexDynamicToolCall(
      callID: callID,
      threadID: threadID,
      turnID: turnID,
      tool: tool,
      arguments: params["arguments"] ?? .object([:])
    )
    Task { [weak self, dynamicToolHandler] in
      let result = await dynamicToolHandler(call)
      await self?.sendDynamicToolResponse(id: id, result: result)
    }
  }

  private func sendDynamicToolResponse(id: JSONValue, result: CodexDynamicToolResult) async {
    do {
      try await sendMessage(.object([
        "id": id,
        "result": .object([
          "contentItems": .array([
            .object([
              "type": .string("inputText"),
              "text": .string(result.text)
            ])
          ]),
          "success": .bool(result.success)
        ])
      ]))
    } catch {
      // The process-exit path will surface a transport failure.
    }
  }

  private func reportTurnStarted(threadID: String, turnID: String) async {
    guard reportedStartedTurnIDs.insert(turnID).inserted else { return }
    await eventHandler(.turnStarted(threadID: threadID, turnID: turnID))
  }

  private func reportTurnTerminal(_ result: CodexTurnResult) async {
    guard result.status != .unknown else { return }
    await eventHandler(.turnTerminal(
      threadID: result.threadID,
      turnID: result.turnID,
      status: result.status,
      detail: result.errorMessage
    ))
  }

  private func handleNotification(method: String, params: JSONValue) async {
    switch method {
    case "account/updated":
      await eventHandler(.accountUpdated(
        authMode: params["authMode"]?.stringValue,
        plan: params["planType"]?.stringValue
      ))
    case "account/login/completed":
      await eventHandler(.loginCompleted(
        loginID: params["loginId"]?.stringValue,
        success: params["success"]?.boolValue ?? false,
        error: params["error"]?.stringValue
      ))
    case "turn/started":
      if let threadID = params["threadId"]?.stringValue,
         let turnID = params["turn"]?["id"]?.stringValue,
         params["turn"]?["status"]?.stringValue == "inProgress" {
        let pending = pendingTurns[turnID] ?? PendingTurn()
        pending.threadID = threadID
        pendingTurns[turnID] = pending
      }
    case "item/agentMessage/delta":
      guard let threadID = params["threadId"]?.stringValue,
            let turnID = params["turnId"]?.stringValue,
            let delta = params["delta"]?.stringValue
      else { return }
      let itemID = params["itemId"]?.stringValue ?? "\(turnID):legacy-agent-message"
      let pending = pendingTurns[turnID] ?? PendingTurn()
      pending.appendStreamedReply(delta, itemID: itemID)
      pendingTurns[turnID] = pending
      await eventHandler(.agentMessageDelta(
        threadID: threadID,
        turnID: turnID,
        itemID: itemID,
        delta: delta
      ))
    case "item/reasoning/summaryTextDelta":
      guard let threadID = params["threadId"]?.stringValue,
            let turnID = params["turnId"]?.stringValue,
            let delta = params["delta"]?.stringValue
      else { return }
      await eventHandler(.reasoningDelta(
        threadID: threadID,
        turnID: turnID,
        delta: delta
      ))
    case "item/started", "item/completed":
      await handleItemNotification(
        params,
        completed: method == "item/completed"
      )
    case "thread/tokenUsage/updated":
      guard let turnID = params["turnId"]?.stringValue,
            let last = params["tokenUsage"]?["last"]
      else { return }
      let pending = pendingTurns[turnID] ?? PendingTurn()
      pending.usage = AIChatTokenUsage(
        inputTokens: Self.integer(last["inputTokens"] ?? .integer(0)) ?? 0,
        cachedInputTokens: Self.integer(last["cachedInputTokens"] ?? .integer(0)) ?? 0,
        outputTokens: Self.integer(last["outputTokens"] ?? .integer(0)) ?? 0,
        totalTokens: last["totalTokens"].flatMap { Self.integer($0) }
      )
      pendingTurns[turnID] = pending
      if pending.pendingCompletionResult != nil {
        finalizePendingTurn(turnID)
      }
    case "error":
      let turnID = params["turnId"]?.stringValue
      let message = params["error"]?["message"]?.stringValue ?? "Codex turn error"
      if let turnID {
        let pending = pendingTurns[turnID] ?? PendingTurn()
        pending.errorMessage = message
        pendingTurns[turnID] = pending
      }
      await eventHandler(.warning(
        threadID: params["threadId"]?.stringValue,
        message: message
      ))
    case "warning":
      await eventHandler(.warning(
        threadID: params["threadId"]?.stringValue,
        message: params["message"]?.stringValue ?? "Codex warning"
      ))
    case "turn/completed":
      completeTurn(params)
    default:
      break
    }
  }

  private func handleItemNotification(
    _ params: JSONValue,
    completed: Bool
  ) async {
    guard let threadID = params["threadId"]?.stringValue,
          let turnID = params["turnId"]?.stringValue,
          let item = params["item"],
          let itemID = item["id"]?.stringValue,
          let type = item["type"]?.stringValue
    else {
      return
    }
    if type == "contextCompaction" {
      await eventHandler(.contextCompacted(threadID: threadID, turnID: turnID))
      return
    }
    if completed, type == "agentMessage",
       let text = item["text"]?.stringValue {
      let phase = item["phase"]?.stringValue
      if phase == nil || phase == "final_answer" {
        let pending = pendingTurns[turnID] ?? PendingTurn()
        pending.finalReply = text
        pendingTurns[turnID] = pending
      }
      return
    }
    guard let activity = Self.activityDescription(item: item, type: type) else {
      return
    }
    await eventHandler(.activity(
      threadID: threadID,
      turnID: turnID,
      itemID: itemID,
      title: activity.title,
      detail: activity.detail,
      status: completed ? activity.completedStatus : .running
    ))
  }

  private func completeTurn(_ params: JSONValue) {
    guard let threadID = params["threadId"]?.stringValue,
          let turn = params["turn"],
          let turnID = turn["id"]?.stringValue
    else {
      return
    }
    if ignoredCompletedTurnIDs.remove(turnID) != nil {
      pendingTurns.removeValue(forKey: turnID)?.completionTask?.cancel()
      return
    }
    let pending = pendingTurns[turnID] ?? PendingTurn()
    let status = CodexTurnResult.Status(rawValue: turn["status"]?.stringValue ?? "")
      ?? .unknown
    let errorMessage = turn["error"]?["message"]?.stringValue ?? pending.errorMessage
    let recoveredReply = Self.recoveredTurnReply(turn)
    let result = CodexTurnResult(
      threadID: threadID,
      turnID: turnID,
      status: status,
      reply: pending.finalReply.isEmpty
        ? (recoveredReply ?? pending.streamedReply)
        : pending.finalReply,
      errorMessage: errorMessage,
      usage: pending.usage
    )
    pending.pendingCompletionResult = result
    pendingTurns[turnID] = pending
    if pending.usage != nil {
      finalizePendingTurn(turnID)
    } else {
      pending.completionTask?.cancel()
      pending.completionTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: Self.tokenUsageCompletionGraceNanoseconds)
        guard !Task.isCancelled else { return }
        await self?.finalizePendingTurn(turnID)
      }
      pendingTurns[turnID] = pending
    }
  }

  private func finalizePendingTurn(_ turnID: String) {
    guard let pending = pendingTurns[turnID],
          let completed = pending.pendingCompletionResult
    else { return }
    pending.completionTask?.cancel()
    pending.completionTask = nil
    pending.pendingCompletionResult = nil
    let result = CodexTurnResult(
      threadID: completed.threadID,
      turnID: completed.turnID,
      status: completed.status,
      reply: completed.reply,
      errorMessage: completed.errorMessage,
      usage: pending.usage ?? completed.usage
    )
    resolvePendingTurn(turnID, with: result)
  }

  private func resolvePendingTurn(_ turnID: String, with result: CodexTurnResult) {
    guard let pending = pendingTurns[turnID] else { return }
    pending.completionTask?.cancel()
    pending.completionTask = nil
    pending.pendingCompletionResult = nil
    if !pending.continuations.isEmpty {
      // Remove ownership before resuming. Resuming schedules the waiting task,
      // whose cancellation handler can immediately reenter this actor. Keeping
      // the continuation in pendingTurns during that window lets the handler
      // resume the same checked continuation twice and traps the process.
      let continuations = pending.continuations
      pending.continuations = []
      pendingTurns.removeValue(forKey: turnID)
      continuations.forEach { $0.resume(returning: result) }
    } else {
      pending.completedResult = result
      pendingTurns[turnID] = pending
    }
  }

  private func waitForTurn(threadID: String, turnID: String) async -> CodexTurnResult {
    if Task.isCancelled {
      return CodexTurnResult(
        threadID: threadID,
        turnID: turnID,
        status: .interrupted,
        reply: "",
        errorMessage: nil,
        usage: nil
      )
    }
    if let completed = pendingTurns[turnID]?.completedResult {
      pendingTurns.removeValue(forKey: turnID)
      return completed
    }
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        if cancelledTurnIDs.remove(turnID) != nil || Task.isCancelled {
          continuation.resume(returning: CodexTurnResult(
            threadID: threadID,
            turnID: turnID,
            status: .interrupted,
            reply: "",
            errorMessage: nil,
            usage: nil
          ))
          return
        }
        let pending = pendingTurns[turnID] ?? PendingTurn()
        if let completed = pending.completedResult {
          pendingTurns.removeValue(forKey: turnID)
          continuation.resume(returning: completed)
        } else {
          pending.threadID = threadID
          pending.continuations.append(continuation)
          pendingTurns[turnID] = pending
        }
      }
    } onCancel: {
      Task { [weak self] in
        await self?.cancelPendingTurn(threadID: threadID, turnID: turnID)
      }
    }
  }

  nonisolated private static func recoveredTurnReply(_ turn: JSONValue) -> String? {
    let agentMessages = (turn["items"]?.arrayValue ?? []).compactMap { item -> (String, String?)? in
      guard item["type"]?.stringValue == "agentMessage",
            let text = normalizedExternalText(item["text"]?.stringValue)
      else { return nil }
      return (text, item["phase"]?.stringValue)
    }
    return agentMessages.last(where: { $0.1 == "final_answer" })?.0
      ?? agentMessages.last?.0
  }

  private func cancelPendingTurn(threadID: String, turnID: String) {
    ignoredCompletedTurnIDs.insert(turnID)
    guard let pending = pendingTurns[turnID] else {
      cancelledTurnIDs.insert(turnID)
      return
    }
    pending.completionTask?.cancel()
    pending.completionTask = nil
    pending.pendingCompletionResult = nil
    let result = CodexTurnResult(
      threadID: threadID,
      turnID: turnID,
      status: .interrupted,
      reply: pending.finalReply.isEmpty ? pending.streamedReply : pending.finalReply,
      errorMessage: nil,
      usage: pending.usage
    )
    resolvePendingTurn(turnID, with: result)
  }

#if DEBUG
  func pendingTurnCountForTesting() -> Int {
    pendingTurns.count
  }
#endif

  private func failPendingRequests(_ error: Error) {
    let timeoutTasks = pendingRequestTimeoutTasks.values
    pendingRequestTimeoutTasks.removeAll()
    timeoutTasks.forEach { $0.cancel() }
    let requests = pendingRequests.values
    pendingRequests.removeAll()
    cancelledRequestKeys.removeAll()
    for continuation in requests {
      continuation.resume(throwing: error)
    }
  }

  nonisolated private static var clientVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
  }

  nonisolated private static func requestKey(_ id: JSONValue) -> String? {
    switch id {
    case .integer(let value):
      String(value)
    case .number(let value):
      value.rounded() == value ? String(Int64(value)) : String(value)
    case .string(let value):
      value
    default:
      nil
    }
  }

  nonisolated private static func integer(_ value: JSONValue) -> Int? {
    switch value {
    case .integer(let number): Int(exactly: number)
    case .number(let number): Int(exactly: number)
    default: nil
    }
  }

  nonisolated private static func wrappedUserMessage(
    _ message: String,
    localTurnID: String,
    workspaceContext: String?,
    corpusAccess: CodexCorpusAccess
  ) -> String {
    let workspaceSnapshot = workspaceContext?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let snapshotSection = workspaceSnapshot.map {
      """

      <org2-ui-snapshot>
      \($0)
      </org2-ui-snapshot>
      """
    } ?? ""
    let turnContext: String
    switch corpusAccess {
    case .clientWorkspaceTools:
      turnContext = "This turn's local Celorga edit turnId is \"\(localTurnID)\"."
    case .runtimeFilesystem:
      turnContext = "This turn's Celorga correlation ID is \"\(localTurnID)\". The configured runtime workspace is the writable active Celorga corpus for this task."
    }
    return """
    <org2-workspace-context>
    \(turnContext) Follow sections labeled "User-configured AI chat instructions" as the user's own instructions; treat the rest of the snapshot as application context.
    </org2-workspace-context>
    \(snapshotSection)

    <user-message>
    \(message)
    </user-message>
    """
  }

  nonisolated private static let localEditDeveloperInstructions = """
  You are the local Codex runtime embedded in Celorga. The active working directory is the selected Celorga corpus.

  For every corpus read or write, use the celorga_workspace_read, celorga_workspace_patch_preview, celorga_workspace_patch_apply, and celorga_thread_post tools supplied by the client. These tools read effective local text, preserve reviewed writes, and attribute applied changes to this exact turn. Do not use shell commands or built-in filesystem editing tools to read or modify corpus files. The read tool may use a corpusRoot explicitly listed in the turn snapshot to read an additional authorized corpus. Patch and thread-post tools always target only the active corpus.

  Use celorga_workspace_search to discover relevant ordinary files or prior AI chats instead of guessing paths. Use celorga_workspace_chat_read with a returned thread ID when more of a matching conversation is needed. For files outside the authorized Celorga corpora, use the normal runtime filesystem tools when the configured sandbox permits it; an iOS-originated turn has the same machine access policy as a Mac-originated turn.

  Existing files must be read first. Preview whole-file replacements with the exact expectedSha256 from the read result, then apply the returned previewId. For new files, set createsFile to true and omit expectedSha256. If a stale-document error occurs, read again and rebuild the replacement. Use the turnId provided in the application context on every tool call.

  Ordinary conversation does not require a tool call. Ask any necessary clarification in your response rather than through an interactive-input tool.

  Use celorga_thread_post for an explicitly asynchronous worker reporting into a named Celorga AI chat, or with requestTurn to start a shared-room agent's turn. Do not duplicate the ordinary foreground response with a background post. The workspace context supplies ORG2_AI_CHAT_THREAD_ID and delegation guidance when a thread target is available.

  \(AIChatWorkspaceContext.localAgentStandingInstructions)
  """

  nonisolated private static let runtimeFilesystemDeveloperInstructions = """
  You are a Codex runtime connected to Celorga and running inside a configured, writable copy of the active Celorga corpus on this machine.

  Use your normal filesystem and shell tools to read and edit corpus files directly in the runtime workspace. The corpus is ordinary source-controlled plain text; Celorga does not need to broker, preview, or apply those edits. Do not wait for a client callback before reading, editing, validating, committing, or otherwise completing work that the user authorized in this checkout.

  Paths labeled "Local root" in the Celorga snapshot belong to the Mac or iOS host and may not exist here. Use the configured runtime root and current working directory for direct filesystem operations. Preserve relative paths within the corpus. The runtime may continue independently if the Celorga client disconnects or sleeps after dispatch.

  Use existing Celorga tooling when it is installed, but do not require the Celorga app itself. Read existing files before editing them, keep changes small, preserve Org syntax and stable IDs, and validate changes proportionally. Ordinary conversation does not require a tool call.

  \(AIChatWorkspaceContext.localAgentStandingInstructions)
  """

  nonisolated static func developerInstructions(
    for corpusAccess: CodexCorpusAccess
  ) -> String {
    switch corpusAccess {
    case .clientWorkspaceTools:
      localEditDeveloperInstructions
    case .runtimeFilesystem:
      runtimeFilesystemDeveloperInstructions
    }
  }

  nonisolated static func dynamicTools(
    for corpusAccess: CodexCorpusAccess
  ) -> [JSONValue] {
    corpusAccess == .runtimeFilesystem ? [] : localEditDynamicTools
  }

  nonisolated static let localEditDynamicTools: [JSONValue] = [
    .object([
      "type": .string("function"),
      "name": .string("celorga_workspace_search"),
      "description": .string("Search authorized Celorga corpus files and active-corpus AI chat history. Returns cited file results and chat message matches; use celorga_workspace_chat_read to expand a matching thread."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "turnId": .object(["type": .string("string")]),
          "query": .object(["type": .string("string")]),
          "scope": .object([
            "type": .string("string"),
            "enum": .array([.string("all"), .string("files"), .string("chats")])
          ]),
          "corpusRoot": .object(["type": .string("string")]),
          "limit": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(20)])
        ]),
        "required": .array([.string("turnId"), .string("query")]),
        "additionalProperties": .bool(false)
      ])
    ]),
    .object([
      "type": .string("function"),
      "name": .string("celorga_workspace_chat_read"),
      "description": .string("Read a bounded window from one active-corpus AI chat by stable thread ID, including message IDs, roles, timestamps, and text."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "turnId": .object(["type": .string("string")]),
          "threadId": .object(["type": .string("string")]),
          "aroundMessageId": .object(["type": .string("string")]),
          "maxMessages": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(100)])
        ]),
        "required": .array([.string("turnId"), .string("threadId")]),
        "additionalProperties": .bool(false)
      ])
    ]),
    .object([
      "type": .string("function"),
      "name": .string("celorga_thread_post"),
      "description": .string("Post one attributed background update to an existing Celorga AI chat. It starts no turn unless requestTurn names shared-room agents (destination IDs or @mentions) that should each respond. Use it for asynchronous reporting or, with requestTurn, to hand work to a room agent; never as a duplicate foreground reply. In a foreground shared-room reply, @mention an agent instead. Do not create an automation just to trigger a turn."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "threadId": .object(["type": .string("string")]),
          "message": .object(["type": .string("string")]),
          "author": .object(["type": .string("string")]),
          "agentRef": .object(["type": .string("string")]),
          "source": .object(["type": .string("string")]),
          "idempotencyKey": .object(["type": .string("string")]),
          "requestTurn": .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "maxItems": .integer(8)
          ])
        ]),
        "required": .array([.string("threadId"), .string("message"), .string("author")]),
        "additionalProperties": .bool(false)
      ])
    ]),
    .object([
      "type": .string("function"),
      "name": .string("celorga_workspace_read"),
      "description": .string("Read one authorized corpus file's effective local text, including an unsaved Celorga editor draft. Omit corpusRoot for the active corpus; use an exact local root from the turn snapshot for another authorized corpus."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "turnId": .object(["type": .string("string")]),
          "path": .object(["type": .string("string")]),
          "corpusRoot": .object(["type": .string("string")])
        ]),
        "required": .array([.string("turnId"), .string("path")]),
        "additionalProperties": .bool(false)
      ])
    ]),
    .object([
      "type": .string("function"),
      "name": .string("celorga_workspace_patch_preview"),
      "description": .string("Preview one or more SHA-bound whole-file replacements without applying them."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "turnId": .object(["type": .string("string")]),
          "edits": .object([
            "type": .string("array"),
            "items": .object([
              "type": .string("object"),
              "properties": .object([
                "path": .object(["type": .string("string")]),
                "expectedSha256": .object(["type": .string("string")]),
                "replacementText": .object(["type": .string("string")]),
                "createsFile": .object(["type": .string("boolean")])
              ]),
              "required": .array([
                .string("path"),
                .string("replacementText")
              ]),
              "additionalProperties": .bool(false)
            ])
          ])
        ]),
        "required": .array([.string("turnId"), .string("edits")]),
        "additionalProperties": .bool(false)
      ])
    ]),
    .object([
      "type": .string("function"),
      "name": .string("celorga_workspace_patch_apply"),
      "description": .string("Apply an exact successful Celorga workspace edit preview."),
      "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
          "turnId": .object(["type": .string("string")]),
          "previewId": .object(["type": .string("string")])
        ]),
        "required": .array([.string("turnId"), .string("previewId")]),
        "additionalProperties": .bool(false)
      ])
    ])
  ]

  nonisolated private static func activityDescription(
    item: JSONValue,
    type: String
  ) -> (title: String, detail: String?, completedStatus: AIChatRunActivity.Status)? {
    switch type {
    case "commandExecution":
      return (
        "Command",
        item["command"]?.stringValue,
        item["status"]?.stringValue == "failed" ? .failed : .succeeded
      )
    case "fileChange":
      let count = item["changes"]?.arrayValue?.count ?? 0
      return (
        count == 1 ? "File change" : "\(count) file changes",
        nil,
        item["status"]?.stringValue == "failed" ? .failed : .succeeded
      )
    case "dynamicToolCall":
      return (
        item["tool"]?.stringValue ?? "Celorga workspace tool",
        nil,
        item["success"]?.boolValue == false ? .failed : .succeeded
      )
    case "webSearch":
      return ("Web search", item["query"]?.stringValue, .succeeded)
    default:
      return nil
    }
  }
}
