import Foundation

public enum OpenCodeError: LocalizedError, Sendable {
  case executableNotFound
  case invalidSSHHost
  case missingRemoteWorkspace
  case launchFailed(String)
  case invalidResponse(String)
  case turnFailed(String)
  case interrupted
  /// OpenOrg lost its SSH channel; the turn may still be running remotely.
  case connectionLost(String)
  /// No detached turn for this chat is running or waiting on the host.
  case detachedRunUnavailable

  public var errorDescription: String? {
    switch self {
    case .executableNotFound:
      "OpenCode was not found. Install `@opencode/cli`, then connect a provider."
    case .invalidSSHHost:
      "Remote OpenCode needs a valid SSH host or ~/.ssh/config alias."
    case .missingRemoteWorkspace:
      "Remote OpenCode needs the Celorga corpus path on that machine."
    case .launchFailed(let detail):
      "Could not start OpenCode: \(detail)"
    case .invalidResponse(let detail):
      "OpenCode returned an invalid response: \(detail)"
    case .turnFailed(let detail):
      "OpenCode turn failed: \(detail)"
    case .interrupted:
      "OpenCode was stopped."
    case .connectionLost(let detail):
      "Lost the connection to remote OpenCode: \(detail)"
    case .detachedRunUnavailable:
      "This OpenCode turn is no longer running."
    }
  }
}

public enum OpenCodeTransport: Equatable, Sendable {
  case local
  case managedRemote(sshHost: String, workspacePath: String)
}

public enum OpenCodeEvent: Sendable {
  /// The OpenCode process launched; the first JSON event can take a few
  /// seconds while its private server loads config, providers, and MCP servers.
  case processStarted
  case sessionStarted(sessionID: String)
  case reasoning(id: String, text: String)
  case textDelta(String)
  /// A later text part replaced the reply so far; the earlier part was
  /// working narration and arrives separately as `.reasoning`.
  case replyReplaced(String)
  case activity(id: String, title: String, status: AIChatRunActivity.Status)
  case warning(String)
}

public struct OpenCodeTurnResult: Equatable, Sendable {
  public let sessionID: String
  public let reply: String

  public init(sessionID: String, reply: String) {
    self.sessionID = sessionID
    self.reply = reply
  }
}

struct OpenCodeStreamResult: Equatable, Sendable {
  var sessionID: String?
  var reply = ""
  var errors: [String] = []
  var succeeded = false
}

struct OpenCodeStreamDecoder: Sendable {
  private(set) var result = OpenCodeStreamResult()
  private var currentTextPartID: String?
  private var textPartCount = 0

  mutating func consume(
    _ line: String,
    eventHandler: @Sendable (OpenCodeEvent) async -> Void
  ) async {
    guard let data = line.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let type = object["type"] as? String
    else { return }

    if let sessionID = object["sessionID"] as? String, !sessionID.isEmpty {
      if result.sessionID == nil {
        await eventHandler(.sessionStarted(sessionID: sessionID))
      }
      result.sessionID = sessionID
    }

    switch type {
    case "text":
      guard let part = object["part"] as? [String: Any],
            let text = part["text"] as? String,
            !text.isEmpty
      else { return }
      result.succeeded = true
      guard let partID = part["id"] as? String, !partID.isEmpty else {
        // Without part identity the text can only be a continuation.
        result.reply += text
        await eventHandler(.textDelta(text))
        return
      }
      if partID == currentTextPartID {
        // The same part again carries its complete, newer text.
        result.reply = text
        await eventHandler(.replyReplaced(text))
        return
      }
      textPartCount += 1
      let earlier = result.reply.trimmingCharacters(in: .whitespacesAndNewlines)
      let earlierID = currentTextPartID ?? "text-\(textPartCount - 1)"
      currentTextPartID = partID
      guard !earlier.isEmpty else {
        result.reply = text
        await eventHandler(.textDelta(text))
        return
      }
      // OpenCode emits one text part per step. Text before a later step is
      // narration between tool calls ("Let me check…"); concatenating every
      // part made one unbroken wall of text. The reply is the final part, as
      // with Claude Code's result and Codex's final message, and each earlier
      // part stays in the run's activity feed.
      await eventHandler(.reasoning(id: "narration-\(earlierID)", text: earlier))
      result.reply = text
      await eventHandler(.replyReplaced(text))
    case "reasoning":
      guard let part = object["part"] as? [String: Any],
            let text = (part["text"] as? String)?
              .trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty
      else { return }
      let id = (part["id"] as? String) ?? UUID().uuidString.lowercased()
      await eventHandler(.reasoning(id: id, text: text))
    case "tool_use":
      guard let part = object["part"] as? [String: Any] else { return }
      let id = (part["id"] as? String)
        ?? (part["partID"] as? String)
        ?? UUID().uuidString.lowercased()
      let tool = part["tool"] as? String ?? "tool"
      let state = part["state"] as? [String: Any]
      let status: AIChatRunActivity.Status
      switch state?["status"] as? String {
      case "completed": status = .succeeded
      case "error", "failed": status = .failed
      default: status = .running
      }
      await eventHandler(.activity(id: id, title: Self.activityTitle(for: tool), status: status))
    case "step_finish":
      if let part = object["part"] as? [String: Any],
         let reason = part["reason"] as? String,
         reason == "error" {
        result.errors.append("OpenCode ended the step with an error.")
      }
    case "error":
      let nestedError = object["error"] as? [String: Any]
      let detail = (object["message"] as? String)
        ?? (nestedError?["message"] as? String)
        ?? (object["error"] as? String)
        ?? "OpenCode reported an error."
      result.errors.append(detail)
      await eventHandler(.warning(detail))
    default:
      break
    }
  }

  private nonisolated static func activityTitle(for tool: String) -> String {
    switch tool.lowercased() {
    case "read": "Reading"
    case "glob", "grep", "list", "ls": "Searching"
    case "edit", "write", "patch": "Editing"
    case "bash", "shell": "Running command"
    case "webfetch", "websearch": "Browsing"
    case "task", "subagent": "Delegating"
    default: "Using \(tool)"
    }
  }
}

public actor OpenCodeClient {
  public typealias EventHandler = @Sendable (UUID, OpenCodeEvent) async -> Void

  private let transport: OpenCodeTransport
  private let executableURL: URL?
  private let environment: [String: String]
  private let eventHandler: EventHandler
  private struct ActiveRun {
    let process: Process
    /// The local warm server this turn runs on; nil for managed remote turns.
    let warmServer: WarmServer?
    /// Nil while following a detached turn, which cannot be steered.
    let serverURL: String?
    let serverPassword: String
  }

  private var activeRuns: [UUID: ActiveRun] = [:]
  private var interruptedThreadIDs: Set<UUID> = []
  /// Set while OpenOrg quits: managed remote turns keep running on their host
  /// and are reattached by the next launch instead of being stopped.
  private var isDetachingForTermination = false
  private var warmServers: [String: WarmServer] = [:]
  private var warmServerReapTask: Task<Void, Never>?
  private let warmServerIdleTimeout: TimeInterval
  /// Distinct configurations kept warm at once (for example one per sandbox mode).
  nonisolated static let warmServerLimit = 3

  public init(
    transport: OpenCodeTransport = .local,
    executableURL: URL? = OpenCodeClient.resolveExecutableURL(),
    environment: [String: String] = ProcessInfo.processInfo.environment,
    warmServerIdleTimeout: TimeInterval = TimeInterval(OpenCodeClient.warmServerIdleSeconds),
    eventHandler: @escaping EventHandler
  ) {
    self.transport = transport
    self.executableURL = executableURL
    self.environment = environment
    self.warmServerIdleTimeout = warmServerIdleTimeout
    self.eventHandler = eventHandler
  }

  deinit {
    warmServerReapTask?.cancel()
    for server in warmServers.values { server.stop() }
  }

  nonisolated public static func resolveExecutableURL(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    fileManager: FileManager = .default
  ) -> URL? {
    LocalAgentExecutableLocator.resolve(
      executableName: "opencode",
      configuredKey: "ORG2_OPENCODE_EXECUTABLE",
      environment: environment,
      fileManager: fileManager
    )
  }

  nonisolated static func arguments(
    sessionID: String?,
    model: String?,
    reasoningEffort: String?,
    attachmentPaths: [String]
  ) -> [String] {
    var arguments = ["run", "--format", "json", "--thinking", "--agent", "openorg", "--auto"]
    if let sessionID = normalized(sessionID) {
      arguments.append(contentsOf: ["--session", sessionID])
    }
    if let model = normalized(model) {
      let effort = normalized(reasoningEffort)
      let selected = effort.map { model.contains("#") ? model : "\(model)#\($0)" } ?? model
      arguments.append(contentsOf: ["--model", selected])
    }
    for path in attachmentPaths {
      arguments.append(contentsOf: ["--file", path])
    }
    // The message goes to standard input, never as a positional argument:
    // `opencode run` quotes each positional word, and it reads words after
    // `--` twice, so the model saw `"<prompt>" "<prompt>"`. Standard input is
    // delivered verbatim, and a message such as "- header chip…" cannot be
    // read as a flag.
    return arguments
  }

  nonisolated static func inlineConfiguration(
    systemPrompt: String,
    sandboxAccess: CodexSandboxAccess
  ) throws -> String {
    var permissions: [String: String] = [:]
    switch sandboxAccess {
    case .readOnly:
      permissions = [
        "edit": "deny",
        "bash": "deny",
        "external_directory": "deny"
      ]
    case .workspaceWrite:
      permissions = [
        "edit": "allow",
        "bash": "allow",
        "external_directory": "deny"
      ]
    case .fullAccess:
      permissions = [
        "edit": "allow",
        "bash": "allow",
        "external_directory": "allow"
      ]
    }
    // The top-level block applies the same sandbox to subagents such as
    // `explore` and `general`. Agent-level permissions are not inherited, and
    // a headless `opencode run` never answers a subagent's "ask" prompt, so a
    // subagent reading outside the session directory would hang the turn.
    let configuration: [String: Any] = [
      "$schema": "https://opencode.ai/config.json",
      "permission": permissions,
      "agent": [
        "openorg": [
          "description": "Celorga workspace agent",
          "mode": "primary",
          "prompt": systemPrompt,
          "permission": permissions
        ]
      ]
    ]
    // Sorted keys keep identical settings byte-identical: the configuration
    // is the key that lets later turns reuse a warm server.
    let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  nonisolated static func validatedSSHHost(_ rawSSHHost: String) throws -> String {
    let sshHost = rawSSHHost.trimmingCharacters(in: .whitespacesAndNewlines)
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_@:%[]+"))
    guard !sshHost.isEmpty,
          !sshHost.hasPrefix("-"),
          sshHost.unicodeScalars.allSatisfy({ allowed.contains($0) })
    else { throw OpenCodeError.invalidSSHHost }
    return sshHost
  }

  nonisolated static func managedRemoteSSHArguments(sshHost: String) throws -> [String] {
    [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=15",
      "-o", "ServerAliveInterval=15",
      "-o", "ServerAliveCountMax=12",
      try validatedSSHHost(sshHost),
      managedRemoteCommand()
    ]
  }

  nonisolated static func managedRemoteModelSSHArguments(sshHost: String) throws -> [String] {
    [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=15",
      try validatedSSHHost(sshHost),
      managedRemoteModelCommand()
    ]
  }

  nonisolated static func managedRemoteSteerSSHArguments(sshHost: String) throws -> [String] {
    [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=15",
      try validatedSSHHost(sshHost),
      managedRemoteSteerCommand()
    ]
  }

  nonisolated static func managedRemoteAttachSSHArguments(sshHost: String) throws -> [String] {
    [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=15",
      "-o", "ServerAliveInterval=15",
      "-o", "ServerAliveCountMax=12",
      try validatedSSHHost(sshHost),
      managedRemotePythonCommand(managedRemoteAttachPythonBootstrap, name: "openorg-opencode-attach")
    ]
  }

  nonisolated static func managedRemoteStopSSHArguments(sshHost: String) throws -> [String] {
    [
      "-T",
      "-o", "BatchMode=yes",
      "-o", "ConnectTimeout=15",
      try validatedSSHHost(sshHost),
      managedRemotePythonCommand(managedRemoteStopPythonBootstrap, name: "openorg-opencode-stop")
    ]
  }

  private nonisolated static func managedRemotePythonCommand(_ source: String, name: String) -> String {
    let script = Data(source.utf8).base64EncodedString()
    return #"exec /bin/sh -lc 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; command -v python3 >/dev/null 2>&1 || { echo "Remote OpenCode requires python3." >&2; exit 127; }; exec python3 -c "import base64;exec(compile(base64.b64decode(\"\#(script)\"),\"<\#(name)>\",\"exec\"))"'"#
  }

  private nonisolated static func managedRemoteCommand() -> String {
    let script = Data(managedRemotePythonBootstrap.utf8).base64EncodedString()
    return #"exec /bin/sh -lc 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; command -v python3 >/dev/null 2>&1 || { echo "Remote OpenCode requires python3." >&2; exit 127; }; exec python3 -c "import base64;exec(compile(base64.b64decode(\"\#(script)\"),\"<openorg-opencode-adapter>\",\"exec\"))"'"#
  }

  private nonisolated static func managedRemoteModelCommand() -> String {
    let script = Data(managedRemoteModelPythonBootstrap.utf8).base64EncodedString()
    return #"exec /bin/sh -lc 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; command -v python3 >/dev/null 2>&1 || { echo "Remote OpenCode requires python3." >&2; exit 127; }; exec python3 -c "import base64;exec(compile(base64.b64decode(\"\#(script)\"),\"<openorg-opencode-models>\",\"exec\"))"'"#
  }

  private nonisolated static func managedRemoteSteerCommand() -> String {
    let script = Data(managedRemoteSteerPythonBootstrap.utf8).base64EncodedString()
    return #"exec /bin/sh -lc 'PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH; command -v python3 >/dev/null 2>&1 || { echo "Remote OpenCode requires python3." >&2; exit 127; }; exec python3 -c "import base64;exec(compile(base64.b64decode(\"\#(script)\"),\"<openorg-opencode-steer>\",\"exec\"))"'"#
  }

  nonisolated static let managedRemoteModelPythonBootstrap = #"""
import json
import os
import shutil
import subprocess
import sys

payload = json.load(sys.stdin)
workspace = os.path.expanduser(payload["workspacePath"])
if not os.path.isabs(workspace) or not os.path.isdir(workspace):
    sys.stderr.write("Remote OpenCode workspace does not exist: %s\n" % workspace)
    sys.exit(66)

opencode = shutil.which("opencode")
if not opencode:
    sys.stderr.write("OpenCode was not found on the remote PATH.\n")
    sys.exit(127)

def models():
    return subprocess.run([opencode, "models"], cwd=workspace, capture_output=True, text=True)

result = models()
if result.returncode == 0 and not result.stdout.strip():
    subprocess.run([opencode, "reload"], cwd=workspace, capture_output=True, text=True)
    result = models()

sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
"""#

  /// Shared helpers for the durable run record kept on the OpenCode host.
  /// A record exists only while a turn runs, or after it finished while no
  /// OpenOrg client was connected to receive its output.
  nonisolated static let managedRemoteRunRecordPython = #"""
import json
import os
import re
import signal
import time

OPENORG_RUN_DIRECTORY = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "openorg",
    "opencode-runs",
)

def openorg_run_files(payload):
    thread_id = str(payload.get("threadID") or "").lower()
    if not re.fullmatch(r"[0-9a-f-]{36}", thread_id):
        return None
    os.makedirs(OPENORG_RUN_DIRECTORY, mode=0o700, exist_ok=True)
    base = os.path.join(OPENORG_RUN_DIRECTORY, thread_id)
    return {
        "threadID": thread_id,
        "token": str(payload.get("runToken") or ""),
        "record": base + ".json",
        "events": base + ".events.jsonl",
    }

def openorg_read_record(run):
    try:
        with open(run["record"], "r") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None

def openorg_owns_run(run):
    record = openorg_read_record(run)
    return record is not None and record.get("pid") == os.getpid()

def openorg_write_record(run, fields):
    record = {
        "version": 1,
        "threadID": run["threadID"],
        "token": run["token"],
        "pid": os.getpid(),
        "updatedAt": time.time(),
    }
    record.update(fields)
    temporary = run["record"] + ".tmp"
    with open(temporary, "w") as handle:
        json.dump(record, handle)
    os.chmod(temporary, 0o600)
    os.replace(temporary, run["record"])

def openorg_remove_run(run):
    for path in (run["record"], run["events"]):
        try:
            os.remove(path)
        except OSError:
            pass

def openorg_pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False

def openorg_prune_finished_runs(max_age_seconds=3 * 24 * 3600):
    # Finished records stay so a later client can still collect the turn;
    # drop ones nobody collected within a few days.
    now = time.time()
    try:
        names = os.listdir(OPENORG_RUN_DIRECTORY)
    except OSError:
        return
    for name in names:
        if not name.endswith(".json"):
            continue
        path = os.path.join(OPENORG_RUN_DIRECTORY, name)
        try:
            with open(path, "r") as handle:
                record = json.load(handle)
        except (OSError, ValueError):
            continue
        if record.get("state") == "finished" and now - float(record.get("updatedAt") or 0) > max_age_seconds:
            for stale in (path, path[:-len(".json")] + ".events.jsonl"):
                try:
                    os.remove(stale)
                except OSError:
                    pass

def openorg_stop_previous_run(run):
    record = openorg_read_record(run)
    if record and record.get("state") == "running" and record.get("pid") != os.getpid():
        if openorg_pid_alive(record.get("pid")):
            os.kill(int(record["pid"]), signal.SIGTERM)
    openorg_remove_run(run)
"""#

  /// How long an unused warm OpenCode server stays up, locally and on a
  /// managed remote host.
  nonisolated public static let warmServerIdleSeconds = 600

  /// Owns one warm `opencode serve` on a managed remote host. It runs
  /// detached from any SSH session, publishes the server in a 0600 record,
  /// and stops the server once no turn has held a lease for the idle period.
  /// Arguments: state directory, server key, opencode path, idle seconds.
  nonisolated static let managedRemoteWarmServerKeeperPython = #"""
import fcntl
import json
import os
import signal
import subprocess
import sys
import threading
import time

directory, key, opencode, idle_seconds = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4])
base = os.path.join(directory, key)
record_path = base + ".json"
lease_directory = base + ".leases"
signal.signal(signal.SIGHUP, signal.SIG_IGN)

def write_record(fields):
    record = {"version": 1, "pid": os.getpid(), "updatedAt": time.time()}
    record.update(fields)
    temporary = "%s.%d.tmp" % (record_path, os.getpid())
    with open(temporary, "w") as handle:
        json.dump(record, handle)
    os.chmod(temporary, 0o600)
    os.replace(temporary, record_path)

def owns_record():
    try:
        with open(record_path, "r") as handle:
            return json.load(handle).get("pid") == os.getpid()
    except (OSError, ValueError, AttributeError):
        return False

def has_live_lease():
    try:
        names = os.listdir(lease_directory)
    except OSError:
        return False
    live = False
    for name in names:
        try:
            os.kill(int(name), 0)
            live = True
        except (OSError, ValueError):
            try:
                os.remove(os.path.join(lease_directory, name))
            except OSError:
                pass
    return live

log = open(base + ".log", "wb")
server = subprocess.Popen(
    [opencode, "serve", "--hostname", "127.0.0.1", "--port", "0"],
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=log,
)

def stop(*_):
    if server.poll() is None:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
    if owns_record():
        try:
            os.remove(record_path)
        except OSError:
            pass
    os._exit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
line = server.stdout.readline().decode("utf-8", "replace").strip()
prefix = "server listening on "
if not line.startswith(prefix):
    write_record({"state": "failed", "detail": line or "OpenCode warm server did not start"})
    if server.poll() is None:
        server.terminate()
    sys.exit(1)

def drain():
    for _ in iter(lambda: server.stdout.read(65536), b""):
        pass
threading.Thread(target=drain, daemon=True).start()
write_record({
    "state": "ready",
    "serverPid": server.pid,
    "url": line[len(prefix):],
    "password": os.environ.get("OPENCODE_SERVER_PASSWORD", ""),
})

while server.poll() is None:
    time.sleep(min(15.0, idle_seconds))
    with open(base + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if not owns_record():
            break
        try:
            last_used = os.path.getmtime(record_path)
        except OSError:
            last_used = 0
        if has_live_lease() or time.time() - last_used < idle_seconds:
            continue
        os.remove(record_path)
        break
stop()
"""#

  /// Adapter helpers that find or start the warm server for a configuration,
  /// hold a lease on it for one turn, and stop a turn's session in it.
  nonisolated static let managedRemoteWarmServerPython = #"""

import fcntl
import hashlib
import secrets
import socket

OPENORG_SERVER_DIRECTORY = os.path.join(
    os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"),
    "openorg",
    "opencode-servers",
)
OPENORG_WARM_SERVER_IDLE_SECONDS = \#(warmServerIdleSeconds)
OPENORG_WARM_SERVER_KEEPER = base64.b64decode("\#(Data(managedRemoteWarmServerKeeperPython.utf8).base64EncodedString())").decode("utf-8")

def openorg_read_json(path):
    try:
        with open(path, "r") as handle:
            value = json.load(handle)
        return value if isinstance(value, dict) else None
    except (OSError, ValueError):
        return None

def openorg_server_reachable(url):
    try:
        port = int(url.rsplit(":", 1)[1].split("/")[0])
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except (OSError, ValueError, IndexError):
        return False

def openorg_warm_server_usable(record):
    return (
        record is not None
        and record.get("state") == "ready"
        and openorg_pid_alive(record.get("pid"))
        and openorg_pid_alive(record.get("serverPid"))
        and openorg_server_reachable(str(record.get("url") or ""))
    )

def openorg_acquire_warm_server(opencode, workspace, configuration):
    os.makedirs(OPENORG_SERVER_DIRECTORY, mode=0o700, exist_ok=True)
    executable = os.path.realpath(opencode)
    try:
        executable_stamp = os.stat(executable).st_mtime
    except OSError:
        executable_stamp = 0
    key = hashlib.sha256(json.dumps(
        ["openorg-opencode-server:v1", executable, executable_stamp, workspace, configuration]
    ).encode("utf-8")).hexdigest()[:32]
    base = os.path.join(OPENORG_SERVER_DIRECTORY, key)
    record_path = base + ".json"
    lease_directory = base + ".leases"
    with open(base + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = openorg_read_json(record_path)
        if not openorg_warm_server_usable(record):
            if record and record.get("pid") and openorg_pid_alive(record.get("pid")):
                try:
                    os.kill(int(record["pid"]), signal.SIGTERM)
                except (OSError, ValueError):
                    pass
            try:
                os.remove(record_path)
            except OSError:
                pass
            os.makedirs(lease_directory, mode=0o700, exist_ok=True)
            environment = os.environ.copy()
            environment["OPENCODE_CONFIG_CONTENT"] = configuration
            environment["OPENCODE_SERVER_PASSWORD"] = secrets.token_hex(24)
            keeper = subprocess.Popen(
                [sys.executable, "-c", OPENORG_WARM_SERVER_KEEPER, OPENORG_SERVER_DIRECTORY,
                 key, opencode, str(OPENORG_WARM_SERVER_IDLE_SECONDS)],
                cwd=workspace,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                close_fds=True,
            )
            deadline = time.time() + 120
            while True:
                record = openorg_read_json(record_path)
                if record and record.get("state") in ("ready", "failed"):
                    break
                if keeper.poll() is not None or time.time() > deadline:
                    raise RuntimeError("OpenCode server did not start")
                time.sleep(0.02)
            if record.get("state") != "ready":
                try:
                    os.remove(record_path)
                except OSError:
                    pass
                raise RuntimeError(record.get("detail") or "OpenCode server did not start")
        os.makedirs(lease_directory, mode=0o700, exist_ok=True)
        lease = os.path.join(lease_directory, str(os.getpid()))
        open(lease, "w").close()
        try:
            os.utime(record_path)
        except OSError:
            pass
    return record, lease, record_path

def openorg_release_warm_server(lease, record_path):
    try:
        os.remove(lease)
    except OSError:
        return
    try:
        os.utime(record_path)
    except OSError:
        pass

def openorg_interrupt_session(opencode, environment, server_url, session_id):
    if not session_id:
        return
    try:
        subprocess.run(
            [opencode, "api", "--server", server_url, "session.interrupt",
             "--param", "sessionID=" + session_id],
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=10,
        )
    except (OSError, subprocess.SubprocessError):
        pass
"""#

  nonisolated static let managedRemotePythonBootstrap = #"""
import base64
import json
import os
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading

"""# + managedRemoteRunRecordPython + managedRemoteWarmServerPython + #"""

payload = json.load(sys.stdin)
workspace = os.path.expanduser(payload["workspacePath"])
if not os.path.isabs(workspace) or not os.path.isdir(workspace):
    sys.stderr.write("Remote OpenCode workspace does not exist: %s\n" % workspace)
    sys.exit(66)

opencode = shutil.which("opencode")
if not opencode:
    sys.stderr.write("OpenCode was not found on the remote PATH.\n")
    sys.exit(127)

temporary_root = tempfile.mkdtemp(prefix="openorg-opencode-")
try:
    attachment_paths = []
    for index, attachment in enumerate(payload.get("attachments", [])):
        raw_name = os.path.basename(attachment.get("fileName") or ("attachment-%d" % (index + 1)))
        safe_name = raw_name.replace("/", "-")
        if safe_name in ("", ".", ".."):
            safe_name = "attachment-%d" % (index + 1)
        path = os.path.join(temporary_root, safe_name)
        with open(path, "wb") as handle:
            handle.write(base64.b64decode(attachment["data"]))
        os.chmod(path, 0o600)
        attachment_paths.append(path)

    arguments = list(payload["arguments"])
    session_id = [None]
    if "--session" in arguments:
        session_id[0] = arguments[arguments.index("--session") + 1]
    for path in attachment_paths:
        arguments.extend(["--file", path])

    # A cold `opencode serve` spends about a second loading config, providers,
    # skills, and MCP servers before the model sees the prompt. Reuse a warm
    # server with the same configuration; it stops itself once idle.
    server, lease, server_record = openorg_acquire_warm_server(
        opencode, workspace, payload["configuration"]
    )
    server_url = server["url"]
    environment = os.environ.copy()
    environment["OPENCODE_CONFIG_CONTENT"] = payload["configuration"]
    environment["OPENCODE_SERVER_PASSWORD"] = server["password"]
    sys.stdout.write(json.dumps({
        "type": "openorg_server",
        "url": server_url,
        "password": server["password"],
    }) + "\n")
    sys.stdout.flush()

    arguments[1:1] = ["--server", server_url]
    # The turn must outlive the SSH channel: OpenOrg may quit or be rebuilt
    # mid-turn. Relay the event stream through this process, keep a durable
    # copy, and let a later `attach` replay it once OpenOrg reconnects.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    detached = [False]
    run = openorg_run_files(payload)
    if run is not None:
        openorg_prune_finished_runs()
        openorg_stop_previous_run(run)
        events = open(run["events"], "wb")
        os.chmod(run["events"], 0o600)
        openorg_write_record(run, {"state": "running"})
    process = subprocess.Popen(
        [opencode] + arguments,
        cwd=workspace,
        env=environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        start_new_session=True,
    )
    # `opencode run` reads the message verbatim from standard input.
    try:
        process.stdin.write(payload["message"].encode("utf-8"))
    except (BrokenPipeError, OSError):
        pass
    try:
        process.stdin.close()
    except (BrokenPipeError, OSError):
        pass
    stopping = [False]
    def forward(_signum, _frame):
        # The session runs inside the shared server, so only SIGINT (which
        # `opencode run` turns into an abort) or an explicit interrupt stops
        # it; SIGTERM would leave the turn running after its client exits.
        stopping[0] = True
        if process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGINT)
            except OSError:
                process.send_signal(signal.SIGINT)
        openorg_interrupt_session(opencode, environment, server_url, session_id[0])
    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    # The durable copy never waits on the client: a sleeping client stops
    # reading without closing the channel, and a blocked write must not hold
    # back the rest of the turn's events.
    outbound = queue.Queue()
    def relay():
        for line in iter(process.stdout.readline, b""):
            if session_id[0] is None:
                try:
                    session_id[0] = json.loads(line).get("sessionID") or None
                except (ValueError, AttributeError):
                    pass
            if run is not None:
                events.write(line)
                events.flush()
            outbound.put(line)
        outbound.put(None)
    def deliver():
        while True:
            line = outbound.get()
            if line is None:
                return
            if detached[0]:
                continue
            try:
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
            except OSError:
                detached[0] = True
    relay_thread = threading.Thread(target=relay, daemon=True)
    relay_thread.start()
    deliver_thread = threading.Thread(target=deliver, daemon=True)
    deliver_thread.start()
    status = process.wait()
    # A stray descendant may keep the pipe open after the turn exits.
    relay_thread.join(5)
    if status != 0 and not stopping[0]:
        # The client died mid-turn; do not leave its session running.
        openorg_interrupt_session(opencode, environment, server_url, session_id[0])
    openorg_release_warm_server(lease, server_record)
    if run is not None:
        events.close()
        # Keep the finished record even when a client is connected: it may be
        # asleep, and a later attach (or another OpenOrg host on this machine)
        # must still be able to collect the turn. A newer turn in this chat
        # replaces (and stops) this one; never overwrite its record.
        if openorg_owns_run(run):
            openorg_write_record(run, {"state": "finished", "exitCode": status})
    deliver_thread.join(10)
    if deliver_thread.is_alive():
        detached[0] = True
    if detached[0]:
        # stdout is gone; skip interpreter shutdown flushes that would fail.
        shutil.rmtree(temporary_root, ignore_errors=True)
        os._exit(status)
    sys.exit(status)
finally:
    if "lease" in locals():
        openorg_release_warm_server(lease, server_record)
    shutil.rmtree(temporary_root, ignore_errors=True)
"""#

  /// Exit status reported by the attach script when no matching turn exists.
  nonisolated static let detachedRunMissingStatus: Int32 = 86
  /// Exit status reported when the turn's supervisor died without finishing.
  nonisolated static let detachedRunLostStatus: Int32 = 87

  /// Replays a detached turn's event stream from the start, follows it until
  /// the turn ends, and exits with the turn's status. The output has the same
  /// shape as `opencode run --format json`, so one decoder serves both.
  nonisolated static let managedRemoteAttachPythonBootstrap = #"""
import json
import os
import sys
import time

"""# + managedRemoteRunRecordPython + #"""

payload = json.load(sys.stdin)
run = openorg_run_files(payload)
record = openorg_read_record(run) if run else None
if record is None or (run["token"] and record.get("token") != run["token"]):
    sys.exit(\#(detachedRunMissingStatus))

def relay(handle):
    while True:
        line = handle.readline()
        if not line or not line.endswith(b"\n"):
            if line:
                handle.seek(-len(line), os.SEEK_CUR)
            return
        try:
            sys.stdout.buffer.write(line)
            sys.stdout.buffer.flush()
        except OSError:
            os._exit(0)

try:
    handle = open(run["events"], "rb")
except OSError:
    sys.exit(\#(detachedRunLostStatus))
while True:
    relay(handle)
    record = openorg_read_record(run)
    if record is None:
        # The supervisor delivered the result to another client and cleaned up.
        relay(handle)
        sys.exit(0)
    if record.get("state") == "finished":
        relay(handle)
        openorg_remove_run(run)
        sys.exit(int(record.get("exitCode") or 0))
    if not openorg_pid_alive(record.get("pid")):
        relay(handle)
        openorg_remove_run(run)
        sys.exit(\#(detachedRunLostStatus))
    time.sleep(0.25)
"""#

  /// Stops a chat's detached turn, if one is still running on the host.
  nonisolated static let managedRemoteStopPythonBootstrap = #"""
import json
import os
import signal
import sys

"""# + managedRemoteRunRecordPython + #"""

payload = json.load(sys.stdin)
run = openorg_run_files(payload)
record = openorg_read_record(run) if run else None
if record and record.get("state") == "running" and openorg_pid_alive(record.get("pid")):
    os.kill(int(record["pid"]), signal.SIGTERM)
elif run:
    openorg_remove_run(run)
"""#

  nonisolated static let managedRemoteSteerPythonBootstrap = #"""
import json
import os
import shutil
import subprocess
import sys

payload = json.load(sys.stdin)
opencode = shutil.which("opencode")
if not opencode:
    sys.stderr.write("OpenCode was not found on the remote PATH.\n")
    sys.exit(127)

environment = os.environ.copy()
environment["OPENCODE_SERVER_PASSWORD"] = payload["serverPassword"]
result = subprocess.run(
    [
        opencode,
        "api",
        "--server",
        payload["serverURL"],
        "session.prompt",
        "--param",
        "sessionID=" + payload["sessionID"],
        "--data",
        payload["requestData"],
    ],
    capture_output=True,
    env=environment,
    text=True,
)
sys.stdout.write(result.stdout)
sys.stderr.write(result.stderr)
sys.exit(result.returncode)
"""#

  public func listModels(
    cwd: URL,
    configuredModel: String? = nil
  ) async throws -> [AIChatModelOption] {
    let output: String
    switch transport {
    case .local:
      guard let executableURL else { throw OpenCodeError.executableNotFound }
      var result = try await Self.runCommand(
        executableURL: executableURL,
        arguments: ["models"],
        cwd: cwd.standardizedFileURL,
        environment: environment
      )
      if Self.modelIDs(from: result.output).isEmpty {
        _ = try? await Self.runCommand(
          executableURL: executableURL,
          arguments: ["reload"],
          cwd: cwd.standardizedFileURL,
          environment: environment
        )
        result = try await Self.runCommand(
          executableURL: executableURL,
          arguments: ["models"],
          cwd: cwd.standardizedFileURL,
          environment: environment
        )
      }
      output = result.output
    case .managedRemote(let sshHost, let workspacePath):
      let workspacePath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !workspacePath.isEmpty else { throw OpenCodeError.missingRemoteWorkspace }
      let input = try JSONEncoder().encode(OpenCodeRemoteModelPayload(workspacePath: workspacePath))
      let result = try await Self.runCommand(
        executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
        arguments: try Self.managedRemoteModelSSHArguments(sshHost: sshHost),
        cwd: nil,
        environment: environment,
        input: input
      )
      output = result.output
    }

    var ids = Self.modelIDs(from: output)
    if let configuredModel = Self.normalized(configuredModel), !ids.contains(configuredModel) {
      ids.append(configuredModel)
      ids.sort()
    }
    return ids.map { id in
      AIChatModelOption(
        id: id,
        label: id,
        supportsReasoning: true,
        isDefault: id == Self.normalized(configuredModel)
      )
    }
  }

  /// The prompt OpenCode receives for one turn: this turn's Celorga snapshot,
  /// then the user's message. The agent configuration carries only standing
  /// instructions, so it stays identical across turns and a warm server can
  /// serve them all.
  nonisolated static func turnPrompt(message: String, turnContext: String?) -> String {
    guard let context = normalized(turnContext) else { return message }
    return """
    <org2-workspace-context>
    Celorga's snapshot for this turn has the authority of your Celorga instructions; "User-configured AI chat instructions" are the user's own. A later snapshot supersedes this one.
    </org2-workspace-context>

    <org2-ui-snapshot>
    \(context)
    </org2-ui-snapshot>

    <user-message>
    \(message)
    </user-message>
    """
  }

  public func runTurn(
    openOrgThreadID: UUID,
    existingSessionID: String?,
    message rawMessage: String,
    turnContext: String?,
    agentInstructions: String = AIChatWorkspaceContext.localAgentStandingInstructions,
    attachments: [AIChatAttachment],
    cwd: URL,
    model: String?,
    reasoningEffort: String?,
    sandboxAccess: CodexSandboxAccess,
    runToken: String? = nil
  ) async throws -> OpenCodeTurnResult {
    if let existing = activeRuns[openOrgThreadID]?.process, existing.isRunning {
      throw OpenCodeError.launchFailed("another turn is already running in this chat")
    }

    let message = Self.turnPrompt(message: rawMessage, turnContext: turnContext)
    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()
    let temporaryRoot: URL?
    var inputData: Data?
    var warmServer: WarmServer?
    var serverURL: String?
    var serverPassword = ""
    let configuration = try Self.inlineConfiguration(
      systemPrompt: agentInstructions,
      sandboxAccess: sandboxAccess
    )

    switch transport {
    case .local:
      guard let executableURL else { throw OpenCodeError.executableNotFound }
      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("openorg-opencode-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      temporaryRoot = root
      let attachmentURLs: [URL]
      let server: WarmServer
      do {
        attachmentURLs = try Self.materializeAttachments(attachments, under: root)
        server = try await acquireWarmServer(
          executableURL: executableURL,
          cwd: cwd.standardizedFileURL,
          configuration: configuration
        )
      } catch {
        try? FileManager.default.removeItem(at: root)
        throw error
      }
      warmServer = server
      serverURL = server.url
      serverPassword = server.password
      let processEnvironment = Self.privateServerEnvironment(
        environment,
        serverPassword: server.password,
        configuration: configuration
      )
      process.executableURL = executableURL
      var arguments = Self.arguments(
        sessionID: existingSessionID,
        model: model,
        reasoningEffort: reasoningEffort,
        attachmentPaths: attachmentURLs.map(\.path)
      )
      arguments.insert(contentsOf: ["--server", server.url], at: 1)
      process.arguments = arguments
      process.currentDirectoryURL = cwd.standardizedFileURL
      process.environment = LocalAgentExecutableLocator.processEnvironment(
        processEnvironment,
        executableURL: executableURL
      )
      inputData = Data(message.utf8)
    case .managedRemote(let sshHost, let workspacePath):
      temporaryRoot = nil
      let workspacePath = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !workspacePath.isEmpty else { throw OpenCodeError.missingRemoteWorkspace }
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
      process.arguments = try Self.managedRemoteSSHArguments(sshHost: sshHost)
      let remoteArguments = Self.arguments(
        sessionID: existingSessionID,
        model: model,
        reasoningEffort: reasoningEffort,
        attachmentPaths: []
      )
      let payload = OpenCodeRemotePayload(
        workspacePath: workspacePath,
        threadID: openOrgThreadID.uuidString.lowercased(),
        runToken: runToken,
        arguments: remoteArguments,
        message: message,
        configuration: configuration,
        attachments: try attachments.map {
          OpenCodeRemoteAttachment(
            fileName: $0.fileName,
            data: try $0.loadData().base64EncodedString()
          )
        }
      )
      inputData = try JSONEncoder().encode(payload)
      process.environment = environment
    }

    defer {
      if let warmServer { releaseWarmServer(warmServer) }
      if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = standardError

    do {
      try process.run()
      await eventHandler(openOrgThreadID, .processStarted)
      if let inputData { try standardInput.fileHandleForWriting.write(contentsOf: inputData) }
      try standardInput.fileHandleForWriting.close()
      if serverURL == nil {
        let remote = try await Self.readRemoteServer(from: standardOutput.fileHandleForReading)
        serverURL = remote.url
        serverPassword = remote.password
      }
      guard let serverURL else {
        throw OpenCodeError.invalidResponse("the private server did not report its endpoint")
      }
      activeRuns[openOrgThreadID] = ActiveRun(
        process: process,
        warmServer: warmServer,
        serverURL: serverURL,
        serverPassword: serverPassword
      )
    } catch {
      if process.isRunning { process.terminate() }
      activeRuns.removeValue(forKey: openOrgThreadID)
      if let warmServer { retireWarmServer(warmServer) }
      throw OpenCodeError.launchFailed(error.localizedDescription)
    }

    return try await followTurn(
      process: process,
      standardOutput: standardOutput,
      standardError: standardError,
      openOrgThreadID: openOrgThreadID,
      mayOutliveConnection: transport != .local,
      warmServer: warmServer
    )
  }

  // MARK: Warm local servers

  /// A local `opencode serve` kept running between turns. A cold server
  /// spends about a second loading config, providers, skills, and MCP servers
  /// before the model sees a prompt; reusing one removes that from each turn.
  /// Mutated only on the client actor (and read by its deinit, which has
  /// exclusive access), hence the unchecked conformance.
  private final class WarmServer: @unchecked Sendable {
    let key: String
    let process: Process
    let url: String
    let password: String
    let outputDrain: Task<Void, Never>
    var activeTurns = 0
    var lastUsed = Date()
    /// No longer offered to new turns; stopped once its last turn ends.
    var isRetired = false

    init(key: String, process: Process, url: String, password: String, outputDrain: Task<Void, Never>) {
      self.key = key
      self.process = process
      self.url = url
      self.password = password
      self.outputDrain = outputDrain
    }

    func stop() {
      outputDrain.cancel()
      if process.isRunning { process.terminate() }
    }
  }

  nonisolated static func warmServerKey(
    executablePath: String,
    cwd: String,
    configuration: String
  ) -> String {
    [executablePath, cwd, configuration].joined(separator: "\u{0}")
  }

  /// Number of warm servers currently offered to new turns.
  public var warmServerCount: Int {
    warmServers.values.filter { $0.process.isRunning }.count
  }

  private func acquireWarmServer(
    executableURL: URL,
    cwd: URL,
    configuration: String
  ) async throws -> WarmServer {
    let key = Self.warmServerKey(
      executablePath: executableURL.path,
      cwd: cwd.path,
      configuration: configuration
    )
    if let server = warmServers[key] {
      if server.process.isRunning {
        server.activeTurns += 1
        server.lastUsed = Date()
        return server
      }
      warmServers.removeValue(forKey: key)
      server.stop()
    }
    let password = UUID().uuidString.lowercased()
    let started = try await Self.startServer(
      executableURL: executableURL,
      cwd: cwd,
      environment: Self.privateServerEnvironment(
        environment,
        serverPassword: password,
        configuration: configuration
      )
    )
    let server = WarmServer(
      key: key,
      process: started.process,
      url: started.url,
      password: password,
      outputDrain: started.outputDrain
    )
    server.activeTurns = 1
    if warmServers[key] == nil {
      warmServers[key] = server
      trimWarmServers()
    } else {
      // Another turn started the same server meanwhile; use this one once.
      server.isRetired = true
    }
    return server
  }

  private func releaseWarmServer(_ server: WarmServer) {
    server.activeTurns = max(0, server.activeTurns - 1)
    server.lastUsed = Date()
    if server.isRetired {
      if server.activeTurns == 0 { server.stop() }
      return
    }
    scheduleWarmServerReap()
  }

  /// Stops offering a server that may be unhealthy.
  private func retireWarmServer(_ server: WarmServer) {
    if warmServers[server.key] === server {
      warmServers.removeValue(forKey: server.key)
    }
    server.isRetired = true
    if server.activeTurns == 0 { server.stop() }
  }

  private func trimWarmServers() {
    while warmServers.count > Self.warmServerLimit,
          let oldest = warmServers.values
            .filter({ $0.activeTurns == 0 })
            .min(by: { $0.lastUsed < $1.lastUsed }) {
      warmServers.removeValue(forKey: oldest.key)
      oldest.stop()
    }
  }

  private func scheduleWarmServerReap() {
    guard warmServerReapTask == nil else { return }
    let interval = max(0.05, min(30, warmServerIdleTimeout / 2))
    warmServerReapTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard let self, await self.reapIdleWarmServers() else { return }
      }
    }
  }

  /// Stops servers idle past the timeout. Returns whether any remain.
  private func reapIdleWarmServers(now: Date = Date()) -> Bool {
    for server in warmServers.values where server.activeTurns == 0
      && (now.timeIntervalSince(server.lastUsed) >= warmServerIdleTimeout || !server.process.isRunning) {
      warmServers.removeValue(forKey: server.key)
      server.stop()
    }
    if warmServers.isEmpty {
      warmServerReapTask = nil
      return false
    }
    return true
  }

  private func interruptSession(_ sessionID: String, on server: WarmServer) async {
    guard let executableURL else { return }
    _ = try? await Self.runCommand(
      executableURL: executableURL,
      arguments: [
        "api", "--server", server.url,
        "session.interrupt",
        "--param", "sessionID=\(sessionID)"
      ],
      cwd: nil,
      environment: Self.privateServerEnvironment(environment, serverPassword: server.password)
    )
  }

  /// Directory where this machine's managed-remote supervisors keep their
  /// durable run records (see ``managedRemoteRunRecordPython``).
  nonisolated static func localRunDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    let stateHome = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
      .map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state", isDirectory: true)
    return stateHome
      .appendingPathComponent("openorg", isDirectory: true)
      .appendingPathComponent("opencode-runs", isDirectory: true)
  }

  /// The outcome of a managed-remote turn that ran on *this* machine and has
  /// finished, read from its durable record without consuming it. Returns nil
  /// when no such finished turn exists here (it is still running, ran on
  /// another machine, or was already collected).
  nonisolated static func finishedLocalRun(
    threadID: UUID,
    runToken: String,
    directory: URL = OpenCodeClient.localRunDirectory()
  ) async -> Result<OpenCodeTurnResult, OpenCodeError>? {
    let base = directory.appendingPathComponent(threadID.uuidString.lowercased())
    guard let recordData = try? Data(contentsOf: base.appendingPathExtension("json")),
          let record = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any],
          record["state"] as? String == "finished",
          let token = record["token"] as? String, !token.isEmpty, token == runToken,
          let events = try? String(
            contentsOf: base.appendingPathExtension("events.jsonl"),
            encoding: .utf8
          )
    else { return nil }
    var decoder = OpenCodeStreamDecoder()
    for line in events.split(whereSeparator: \.isNewline) {
      await decoder.consume(String(line)) { _ in }
    }
    let decoded = decoder.result
    let status = (record["exitCode"] as? NSNumber)?.int32Value ?? 0
    guard status == 0, decoded.succeeded, decoded.errors.isEmpty else {
      let detail = decoded.errors.joined(separator: "\n")
      return .failure(.turnFailed(detail.isEmpty ? "OpenCode exited with status \(status)." : detail))
    }
    guard let sessionID = decoded.sessionID, !sessionID.isEmpty else {
      return .failure(.invalidResponse("the response did not include a session ID"))
    }
    return .success(OpenCodeTurnResult(sessionID: sessionID, reply: decoded.reply))
  }

  /// Whether this client's OpenCode installation knows `sessionID`. A local
  /// client shares its session store with any managed-remote turns that ran
  /// on this machine, so it can resume them.
  public func hasSession(_ sessionID: String, cwd: URL) async -> Bool {
    guard case .local = transport, let executableURL,
          let sessionID = Self.normalized(sessionID)
    else { return false }
    guard let result = try? await Self.runCommand(
      executableURL: executableURL,
      arguments: ["api", "session.get", "--param", "sessionID=\(sessionID)"],
      cwd: cwd.standardizedFileURL,
      environment: environment
    ) else { return false }
    guard let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]
    else { return false }
    let session = (object["data"] as? [String: Any]) ?? object
    return session["id"] as? String == sessionID
  }

  /// Follows a turn that a previous OpenOrg process started on a managed
  /// remote host, replaying its progress from the start. Throws
  /// ``OpenCodeError/detachedRunUnavailable`` when no such turn exists.
  public func attachDetachedTurn(
    openOrgThreadID: UUID,
    runToken: String?
  ) async throws -> OpenCodeTurnResult {
    guard case .managedRemote(let sshHost, _) = transport else {
      throw OpenCodeError.detachedRunUnavailable
    }
    if let existing = activeRuns[openOrgThreadID]?.process, existing.isRunning {
      throw OpenCodeError.launchFailed("another turn is already running in this chat")
    }
    let process = Process()
    let standardInput = Pipe()
    let standardOutput = Pipe()
    let standardError = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = try Self.managedRemoteAttachSSHArguments(sshHost: sshHost)
    process.environment = environment
    process.standardInput = standardInput
    process.standardOutput = standardOutput
    process.standardError = standardError
    let input = try JSONEncoder().encode(OpenCodeRemoteRunReference(
      threadID: openOrgThreadID.uuidString.lowercased(),
      runToken: runToken
    ))
    do {
      try process.run()
      try standardInput.fileHandleForWriting.write(contentsOf: input)
      try standardInput.fileHandleForWriting.close()
    } catch {
      if process.isRunning { process.terminate() }
      throw OpenCodeError.connectionLost(error.localizedDescription)
    }
    activeRuns[openOrgThreadID] = ActiveRun(
      process: process,
      warmServer: nil,
      serverURL: nil,
      serverPassword: ""
    )
    return try await followTurn(
      process: process,
      standardOutput: standardOutput,
      standardError: standardError,
      openOrgThreadID: openOrgThreadID,
      mayOutliveConnection: true
    )
  }

  private func followTurn(
    process: Process,
    standardOutput: Pipe,
    standardError: Pipe,
    openOrgThreadID: UUID,
    mayOutliveConnection: Bool,
    warmServer: WarmServer? = nil
  ) async throws -> OpenCodeTurnResult {
    let handler = eventHandler
    let outputTask = Task.detached(priority: .userInitiated) {
      try await Self.consumeOutput(
        standardOutput.fileHandleForReading,
        openOrgThreadID: openOrgThreadID,
        eventHandler: handler
      )
    }
    let errorTask = Task.detached(priority: .utility) {
      String(
        decoding: try await BlockingIO.readToEnd(standardError.fileHandleForReading) ?? Data(),
        as: UTF8.self
      )
    }
    let status: Int32 = await withTaskCancellationHandler {
      await BlockingIO.terminationStatus(of: process)
    } onCancel: {
      Task { await self.interrupt(openOrgThreadID: openOrgThreadID) }
    }
    let decoded: OpenCodeStreamResult
    do {
      decoded = try await outputTask.value
    } catch {
      activeRuns.removeValue(forKey: openOrgThreadID)
      throw OpenCodeError.invalidResponse(error.localizedDescription)
    }
    let stderr = (try? await errorTask.value)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let wasInterrupted = activeRuns[openOrgThreadID]?.process === process
      ? interruptedThreadIDs.remove(openOrgThreadID) != nil
      : false
    if activeRuns[openOrgThreadID]?.process === process {
      activeRuns.removeValue(forKey: openOrgThreadID)
    }
    if let warmServer, status != 0, !wasInterrupted, !Task.isCancelled {
      if let sessionID = decoded.sessionID {
        // The session lives in the shared server and keeps running after its
        // client dies; stop it rather than leave an orphaned turn.
        await interruptSession(sessionID, on: warmServer)
      } else {
        // Failing before any session suggests the server itself is unwell.
        retireWarmServer(warmServer)
      }
    }

    if mayOutliveConnection, isDetachingForTermination {
      throw OpenCodeError.connectionLost("Celorga is quitting; the turn continues on the host")
    }
    if Task.isCancelled || wasInterrupted || process.terminationReason == .uncaughtSignal {
      throw OpenCodeError.interrupted
    }
    if mayOutliveConnection {
      switch status {
      case Self.detachedRunMissingStatus, Self.detachedRunLostStatus:
        throw OpenCodeError.detachedRunUnavailable
      case 255:
        // ssh reports its own failures as 255. The remote supervisor keeps
        // the turn running and can be reattached.
        throw OpenCodeError.connectionLost(stderr.isEmpty ? "ssh exited with status 255" : stderr)
      default:
        break
      }
    }
    guard status == 0, decoded.succeeded, decoded.errors.isEmpty else {
      let detail = decoded.errors.joined(separator: "\n")
      throw OpenCodeError.turnFailed(
        [detail, stderr].first(where: { !$0.isEmpty }) ?? "OpenCode exited with status \(status)."
      )
    }
    guard let sessionID = decoded.sessionID, !sessionID.isEmpty else {
      throw OpenCodeError.invalidResponse("the response did not include a session ID")
    }
    return OpenCodeTurnResult(sessionID: sessionID, reply: decoded.reply)
  }

  /// Stops this chat's turn. On a managed remote host this also stops a turn
  /// that is still running after an earlier OpenOrg process went away.
  public func interrupt(openOrgThreadID: UUID) async {
    if let process = activeRuns[openOrgThreadID]?.process, process.isRunning {
      interruptedThreadIDs.insert(openOrgThreadID)
      process.interrupt()
    }
    guard !isDetachingForTermination,
          case .managedRemote(let sshHost, _) = transport,
          let arguments = try? Self.managedRemoteStopSSHArguments(sshHost: sshHost),
          let input = try? JSONEncoder().encode(OpenCodeRemoteRunReference(
            threadID: openOrgThreadID.uuidString.lowercased(),
            runToken: nil
          ))
    else { return }
    _ = try? await Self.runCommand(
      executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
      arguments: arguments,
      cwd: nil,
      environment: environment,
      input: input
    )
  }

  public func steer(
    openOrgThreadID: UUID,
    sessionID: String,
    message: String,
    attachments: [AIChatAttachment]
  ) async throws {
    guard let active = activeRuns[openOrgThreadID], active.process.isRunning else {
      throw OpenCodeError.invalidResponse("there is no active OpenCode turn to steer")
    }
    guard let serverURL = active.serverURL else {
      throw OpenCodeError.invalidResponse(
        "the active OpenCode turn was reconnected after Celorga restarted and cannot be steered; queue a follow-up instead"
      )
    }
    let data = try Self.steerRequestData(
      message: message,
      attachments: attachments
    )
    switch transport {
    case .local:
      guard let executableURL else { throw OpenCodeError.executableNotFound }
      _ = try await Self.runCommand(
        executableURL: executableURL,
        arguments: Self.steerArguments(
          serverURL: serverURL,
          sessionID: sessionID,
          data: data
        ),
        cwd: nil,
        environment: Self.privateServerEnvironment(
          environment,
          serverPassword: active.serverPassword
        )
      )
    case .managedRemote(let sshHost, _):
      let input = try JSONEncoder().encode(OpenCodeRemoteSteerPayload(
        serverURL: serverURL,
        sessionID: sessionID,
        requestData: data,
        serverPassword: active.serverPassword
      ))
      _ = try await Self.runCommand(
        executableURL: URL(fileURLWithPath: "/usr/bin/ssh"),
        arguments: try Self.managedRemoteSteerSSHArguments(sshHost: sshHost),
        cwd: nil,
        environment: environment,
        input: input
      )
    }
  }

  /// Lets managed remote turns outlive this process. Call before canceling
  /// their requests during termination; their local SSH channels still close.
  public func detachForTermination() {
    isDetachingForTermination = true
  }

  public func shutdown() {
    for run in activeRuns.values {
      if run.process.isRunning { run.process.terminate() }
      run.warmServer?.stop()
    }
    activeRuns.removeAll()
    warmServerReapTask?.cancel()
    warmServerReapTask = nil
    for server in warmServers.values { server.stop() }
    warmServers.removeAll()
  }

  nonisolated static func steerArguments(
    serverURL: String,
    sessionID: String,
    data: String
  ) -> [String] {
    [
      "api", "--server", serverURL,
      "session.prompt",
      "--param", "sessionID=\(sessionID)",
      "--data", data
    ]
  }

  nonisolated static func steerRequestData(
    message: String,
    attachments: [AIChatAttachment]
  ) throws -> String {
    var request: [String: Any] = [
      "text": message,
      "delivery": "steer"
    ]
    if !attachments.isEmpty {
      request["files"] = try attachments.map { attachment in
        [
          "uri": "data:\(attachment.mimeType);base64,\(try attachment.loadData().base64EncodedString())",
          "name": attachment.fileName
        ]
      }
    }
    let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  nonisolated static func privateServerEnvironment(
    _ environment: [String: String],
    serverPassword: String,
    configuration: String? = nil
  ) -> [String: String] {
    var result = environment
    result["OPENCODE_SERVER_PASSWORD"] = serverPassword
    if let configuration { result["OPENCODE_CONFIG_CONTENT"] = configuration }
    return result
  }

  private nonisolated static func startServer(
    executableURL: URL,
    cwd: URL,
    environment: [String: String]
  ) async throws -> (process: Process, url: String, outputDrain: Task<Void, Never>) {
    let process = Process()
    let output = Pipe()
    process.executableURL = executableURL
    process.arguments = ["serve", "--hostname", "127.0.0.1", "--port", "0"]
    process.currentDirectoryURL = cwd
    process.environment = LocalAgentExecutableLocator.processEnvironment(
      environment,
      executableURL: executableURL
    )
    process.standardOutput = output
    process.standardError = output
    do {
      try process.run()
      let line = try await readLine(from: output.fileHandleForReading)
      let prefix = "server listening on "
      guard line.hasPrefix(prefix) else {
        if process.isRunning { process.terminate() }
        throw OpenCodeError.launchFailed(
          line.isEmpty ? "the private server did not report its endpoint" : line
        )
      }
      let url = String(line.dropFirst(prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard isLoopbackServerURL(url) else {
        if process.isRunning { process.terminate() }
        throw OpenCodeError.invalidResponse("the private server reported an invalid endpoint")
      }
      let outputDrain = Task.detached(priority: .utility) {
        _ = try? await BlockingIO.readToEnd(output.fileHandleForReading)
      }
      return (process, url, outputDrain)
    } catch {
      if process.isRunning { process.terminate() }
      throw error
    }
  }

  /// The remote host reports the warm server the turn runs on, including the
  /// password steering needs: a reused server keeps the one it started with.
  private nonisolated static func readRemoteServer(
    from handle: FileHandle
  ) async throws -> (url: String, password: String) {
    let line = try await readLine(from: handle)
    guard let data = line.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["type"] as? String == "openorg_server",
          let url = object["url"] as? String,
          isLoopbackServerURL(url),
          let password = object["password"] as? String, !password.isEmpty
    else {
      throw OpenCodeError.invalidResponse("the remote private server did not report its endpoint")
    }
    return (url, password)
  }

  private nonisolated static func readLine(from handle: FileHandle) async throws -> String {
    try await BlockingIO.run {
      var data = Data()
      while let byte = try handle.read(upToCount: 1), !byte.isEmpty {
        if byte[byte.startIndex] == 0x0A { break }
        data.append(byte)
        if data.count > 16_384 {
          throw OpenCodeError.invalidResponse("the private server response was too large")
        }
      }
      return String(decoding: data, as: UTF8.self)
    }
  }

  private nonisolated static func isLoopbackServerURL(_ value: String) -> Bool {
    guard let components = URLComponents(string: value),
          components.scheme == "http",
          components.host == "127.0.0.1",
          components.port != nil
    else { return false }
    return true
  }

  private nonisolated static func consumeOutput(
    _ handle: FileHandle,
    openOrgThreadID: UUID,
    eventHandler: @escaping EventHandler
  ) async throws -> OpenCodeStreamResult {
    var decoder = OpenCodeStreamDecoder()
    var buffer = Data()
    while let chunk = try await BlockingIO.read(handle, upToCount: 16_384), !chunk.isEmpty {
      buffer.append(chunk)
      while let newline = buffer.firstIndex(of: 0x0A) {
        let lineData = buffer[..<newline]
        buffer.removeSubrange(...newline)
        await decoder.consume(String(decoding: lineData, as: UTF8.self)) { event in
          await eventHandler(openOrgThreadID, event)
        }
      }
    }
    if !buffer.isEmpty {
      await decoder.consume(String(decoding: buffer, as: UTF8.self)) { event in
        await eventHandler(openOrgThreadID, event)
      }
    }
    return decoder.result
  }

  nonisolated static func modelIDs(from output: String) -> [String] {
    Array(Set(output.split(whereSeparator: \.isNewline).compactMap { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !line.isEmpty,
            !line.contains(where: \.isWhitespace),
            let slash = line.firstIndex(of: "/"),
            slash != line.startIndex,
            line.index(after: slash) != line.endIndex
      else { return nil }
      return line
    })).sorted()
  }

  private nonisolated static func runCommand(
    executableURL: URL,
    arguments: [String],
    cwd: URL?,
    environment: [String: String],
    input: Data? = nil
  ) async throws -> (output: String, error: String) {
    try await BlockingIO.run {
      let process = Process()
      let standardInput = Pipe()
      let standardOutput = Pipe()
      let standardError = Pipe()
      process.executableURL = executableURL
      process.arguments = arguments
      process.currentDirectoryURL = cwd
      process.environment = LocalAgentExecutableLocator.processEnvironment(
        environment,
        executableURL: executableURL
      )
      process.standardInput = standardInput
      process.standardOutput = standardOutput
      process.standardError = standardError
      do {
        try process.run()
        if let input { try standardInput.fileHandleForWriting.write(contentsOf: input) }
        try standardInput.fileHandleForWriting.close()
      } catch {
        if process.isRunning { process.terminate() }
        throw OpenCodeError.launchFailed(error.localizedDescription)
      }
      let output = String(
        decoding: try standardOutput.fileHandleForReading.readToEnd() ?? Data(),
        as: UTF8.self
      )
      let error = String(
        decoding: try standardError.fileHandleForReading.readToEnd() ?? Data(),
        as: UTF8.self
      ).trimmingCharacters(in: .whitespacesAndNewlines)
      process.waitUntilExit()
      guard process.terminationStatus == 0 else {
        throw OpenCodeError.launchFailed(
          error.isEmpty ? "OpenCode exited with status \(process.terminationStatus)." : error
        )
      }
      return (output, error)
    }
  }

  private nonisolated static func materializeAttachments(
    _ attachments: [AIChatAttachment],
    under temporaryRoot: URL
  ) throws -> [URL] {
    var usedNames = Set<String>()
    return try attachments.enumerated().map { index, attachment in
      let rawName = attachment.fileName.trimmingCharacters(in: .whitespacesAndNewlines)
      let safeName = URL(fileURLWithPath: rawName.isEmpty ? "attachment-\(index + 1)" : rawName)
        .lastPathComponent
      var uniqueName = ["", ".", ".."].contains(safeName)
        ? "attachment-\(index + 1)"
        : safeName
      var suffix = 2
      while usedNames.contains(uniqueName.lowercased()) {
        let base = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        uniqueName = ext.isEmpty ? "\(base)-\(suffix)" : "\(base)-\(suffix).\(ext)"
        suffix += 1
      }
      usedNames.insert(uniqueName.lowercased())
      let url = temporaryRoot.appendingPathComponent(uniqueName)
      try attachment.loadData().write(to: url, options: .atomic)
      try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
      return url
    }
  }

  private nonisolated static func normalized(_ value: String?) -> String? {
    let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? nil : value
  }
}

private struct OpenCodeRemotePayload: Encodable {
  let workspacePath: String
  let threadID: String
  let runToken: String?
  let arguments: [String]
  let message: String
  let configuration: String
  let attachments: [OpenCodeRemoteAttachment]
}

private struct OpenCodeRemoteRunReference: Encodable {
  let threadID: String
  let runToken: String?
}

private struct OpenCodeRemoteModelPayload: Encodable {
  let workspacePath: String
}

private struct OpenCodeRemoteSteerPayload: Encodable {
  let serverURL: String
  let sessionID: String
  let requestData: String
  let serverPassword: String
}

private struct OpenCodeRemoteAttachment: Encodable {
  let fileName: String
  let data: String
}
