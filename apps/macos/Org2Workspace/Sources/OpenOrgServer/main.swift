import AppKit
import Darwin
import Foundation
import Security
import Org2WorkspaceCore

private struct ServerConfiguration: Decodable {
  let schema: String
  let hostRef: String
  let name: String
  let corpusRoot: String
  let bindHost: String
  let port: UInt16
  let repoRoot: String
  let nodePath: String
  let destinations: [AIChatDestinationConfiguration]
  let schedulesEnabled: Bool
  let chatRepairIntervalSeconds: Double?
  let localAgentFilesystemAccess: String?
}

/// The CLI owns process supervision and the private control socket. This worker
/// owns the same chat/relay implementation as the desktop, without any windows.
@main
struct OpenOrgServer {
  @MainActor
  static func main() async {
    CelorgaNames.mirrorCelorgaEnvironment()
    do {
      if CommandLine.arguments.dropFirst().first == "--repair-transcript" {
        try await repairTranscript()
        return
      }
      // A LaunchAgent cannot answer Keychain dialogs. Blocking reads can
      // exhaust Swift's cooperative executor and freeze the entire relay.
      // Keep this policy process-local; the desktop retains interactive access.
      SecKeychainSetUserInteractionAllowed(false)
      guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--config" else {
        throw CocoaError(.fileReadInvalidFileName)
      }
      let configURL = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
      let stateDirectory = configURL.deletingLastPathComponent()
      let attributes = try FileManager.default.attributesOfItem(atPath: stateDirectory.path)
      guard let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o077 == 0 else {
        throw CocoaError(.fileReadNoPermission)
      }
      let data = try Data(contentsOf: configURL)
      let config = try JSONDecoder().decode(ServerConfiguration.self, from: data)
      guard CelorgaNames.schemaMatches(config.schema, "org2:server-config:v1"),
            !config.hostRef.isEmpty,
            MobileRemoteCoordinator.isTailscaleIPv4(config.bindHost),
            config.port > 0,
            CelorgaNames.hasConfigFile(in: URL(fileURLWithPath: config.corpusRoot)) else {
        throw CocoaError(.fileReadCorruptFile)
      }
      // The inode is kept across crashes; the OS releases this advisory lock.
      // This also protects against two configurations selecting the same corpus.
      let corpusStateDirectory = CelorgaNames.stateDirectory(corpusRoot: URL(fileURLWithPath: config.corpusRoot))
      let lockPath = corpusStateDirectory.appendingPathComponent("openorg-server.lock").path
      try FileManager.default.createDirectory(at: corpusStateDirectory, withIntermediateDirectories: true)
      let lock = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
      guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else {
        throw NSError(domain: "OpenOrgServer", code: 2, userInfo: [NSLocalizedDescriptionKey: "A server already owns this corpus"])
      }
      defer { Darwin.close(lock) }
      let activity = ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .userInitiated],
        reason: "Celorga is hosting chat and scheduled automations"
      )
      defer { ProcessInfo.processInfo.endActivity(activity) }
      NSApplication.shared.setActivationPolicy(.prohibited)
      let namespace = "org.org2.server.\(config.hostRef)"
      guard let defaults = UserDefaults(suiteName: namespace) else {
        throw CocoaError(.fileWriteUnknown)
      }
      defaults.set(try JSONEncoder().encode(config.destinations), forKey: "Org2Workspace.aiChat.destinations.v1")
      defaults.set("off", forKey: "Org2Workspace.aiChat.messageSound.v1")
      defaults.set(config.chatRepairIntervalSeconds ?? AIChatTranscriptRepair.defaultIntervalSeconds,
        forKey: "Org2Workspace.aiChat.repairIntervalSeconds.v1")
      let filesystemAccess = config.localAgentFilesystemAccess
        .flatMap(CodexSandboxAccess.init(rawValue:)) ?? .workspaceWrite
      defaults.set(
        filesystemAccess != .readOnly,
        forKey: "Org2Workspace.openClawLocalEditsEnabled.v1"
      )
      WorkspaceStore.configureAIChatTranscriptWriter(defaults: defaults, label: config.name)
      let cli = Org2CLI(repoRoot: URL(fileURLWithPath: config.repoRoot), nodePath: config.nodePath)
      // Shared thread links listen only on the Tailscale address, like the relay,
      // and persist beside the private configuration so URLs survive restarts.
      let bindHost = config.bindHost
      let publicationHost = LocalDocumentPublicationHost(
        bindHost: bindHost,
        advertisedHost: bindHost,
        preferredAdvertisedHost: { bindHost },
        storageDirectory: stateDirectory.appendingPathComponent(
          "publications-\(config.hostRef)",
          isDirectory: true
        )
      )
      let store = WorkspaceStore(
        cli: cli,
        defaults: defaults,
        legacyDefaultsDomains: [],
        localDocumentPublicationHost: publicationHost,
        openClawDeviceIdentityFileURL: stateDirectory.appendingPathComponent(
          "openclaw-device-identity.key"
        )
      )
      // A paired Mac signs in to sources and sends their credentials here;
      // they stay in this private state directory, never in the corpus.
      store.sourceCredentialStore = SourceCredentialsFileStore(
        fileURL: stateDirectory.appendingPathComponent("source-credentials-\(config.hostRef).json")
      )
      // Headless hosts have a separate preferences domain from the desktop app.
      // Carry this policy in their machine-local configuration so iOS turns do
      // not silently fall back to the workspace-write default.
      store.codexSandboxAccess = filesystemAccess
      // Explicitly disable built-ins that were not selected in the server config.
      let enabledIDs = Set(config.destinations.filter(\.isEnabled).map(\.id))
      for var destination in store.aiChatDestinations where !enabledIDs.contains(destination.id) {
        destination.isEnabled = false
        store.updateAIChatDestination(destination)
      }
      await store.bootstrapHeadless(
        corpusRoot: URL(fileURLWithPath: config.corpusRoot),
        hostRef: config.hostRef,
        hostName: config.name,
        destinations: config.destinations
      )
      // Resume thread links shared before a restart; each keeps its URL.
      await store.restoreLocalDocumentPublications()
      let remote = MobileRemoteCoordinator(
        defaults: defaults, credentialNamespace: namespace,
        credentialFile: stateDirectory.appendingPathComponent("paired-devices-\(config.hostRef).json"),
        pushCredentialFile: stateDirectory.appendingPathComponent("apns-private-key-\(config.hostRef).pem"),
        serverName: config.name,
        hostRef: config.hostRef, port: config.port
      )
      remote.attach(to: store)
      remote.setBindHost(config.bindHost)
      remote.setEnabled(true)
      for _ in 0..<100 where !remote.isListening {
        try await Task.sleep(for: .milliseconds(100))
      }
      guard remote.isListening else {
        throw NSError(domain: "OpenOrgServer", code: 1, userInfo: [NSLocalizedDescriptionKey: remote.statusText])
      }
      store.setAutomationSchedulerActive(config.schedulesEnabled)
      store.setSourceAutoSyncActive(config.schedulesEnabled)
      emit(["event": "ready", "hostRef": config.hostRef, "endpoint": remote.endpoint ?? ""])

      for try await line in HeadlessControlInput.lines(descriptor: STDIN_FILENO) {
        guard let data = line.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = request["id"] as? String,
              let command = request["command"] as? String else { continue }
        var result: [String: Any]
        switch command {
        case "status":
          result = ["hostRef": config.hostRef, "name": config.name, "endpoint": remote.endpoint ?? "",
                    "listening": remote.isListening, "corpusRoot": config.corpusRoot,
                    "scheduler": store.automationSchedulerStatusText,
                    "schedulerError": store.automationSchedulerErrorText ?? "",
                    "chatRepairIntervalSeconds": store.aiChatRepairIntervalSeconds,
                    "chatRepairError": store.aiChatRepairError ?? "",
                    "filesystemAccess": store.codexSandboxAccess.rawValue,
                    "threads": store.aiChatThreads.count,
                    "runningThreads": store.aiChatRunningTurnCountOnCurrentHost,
                    "draining": store.isAIChatDraining,
                    "peerHosts": store.aiChatRemoteLiveHosts.map {
                      ["hostRef": $0.hostRef, "name": $0.hostName, "kind": $0.hostKind.rawValue,
                       "online": $0.isFresh(within: 150), "updatedAt": ISO8601DateFormatter().string(from: $0.updatedAt),
                       "runningThreads": $0.turns.count] as [String: Any]
                    },
                    "sharedThreads": store.localDocumentPublications.filter { $0.chatThreadID != nil }.count,
                    "pushConfigured": remote.pushProviderConfigured,
                    "sourceCredentials": store.storedSourceCredentialProfileIDs(),
                    "devices": remote.pairedDevices.map { ["id": $0.id.uuidString, "name": $0.name] }]
        case "pair":
          remote.generatePairingCode()
          result = ["endpoint": remote.endpoint ?? "", "code": remote.pairingCode ?? "",
                    "pairingURL": remote.pairingPayload ?? "", "expiresInSeconds": 600]
        case "revoke":
          if let deviceID = request["deviceID"] as? String,
             let device = remote.pairedDevices.first(where: { $0.id.uuidString.lowercased() == deviceID.lowercased() }) {
            remote.revoke(device)
            result = ["revoked": !remote.pairedDevices.contains(where: { $0.id == device.id })]
          } else { result = ["error": "Paired device not found"] }
        case "push-config":
          if let teamID = request["teamID"] as? String, let keyID = request["keyID"] as? String,
             let privateKey = request["privateKey"] as? String {
            if remote.importPushPrivateKey(Data(privateKey.utf8)) {
              remote.setPushTeamID(teamID)
              remote.setPushKeyID(keyID)
              result = remote.pushProviderConfigured ? ["configured": true] : ["error": remote.pushStatusText]
            } else { result = ["error": remote.pushStatusText] }
          } else { result = ["error": "Missing APNs configuration"] }
        case "stop-thread":
          if let rawID = request["threadID"] as? String,
             let threadID = UUID(uuidString: rawID) {
            result = ["stopped": await store.stopAIChatRemoteRun(threadID: threadID)]
          } else { result = ["error": "Missing or invalid thread ID"] }
        case "retry-message":
          if let rawID = request["messageID"] as? String,
             let messageID = UUID(uuidString: rawID),
             store.aiChatThreads.contains(where: { thread in
               thread.messages.contains(where: {
                 $0.id == messageID && $0.role == .user && $0.sendFailure != nil
               })
             }) {
            Task { await store.retryAIChatMessage(messageID) }
            result = ["retryRequested": true]
          } else { result = ["error": "Choose an existing failed user message"] }
        case "drain":
          // Finish running turns before a restart or update: accept no new
          // turns or hand-offs (clients route them to another online host)
          // and start no scheduled automations.
          store.setAutomationSchedulerActive(false)
          store.setSourceAutoSyncActive(false)
          store.beginAIChatDrain()
          result = ["draining": true, "runningThreads": store.aiChatRunningTurnCountOnCurrentHost]
        case "resume":
          store.endAIChatDrain()
          store.setAutomationSchedulerActive(config.schedulesEnabled)
          store.setSourceAutoSyncActive(config.schedulesEnabled)
          result = ["draining": false, "runningThreads": store.aiChatRunningTurnCountOnCurrentHost]
        case "stop":
          store.setAutomationSchedulerActive(false)
          store.setSourceAutoSyncActive(false)
          remote.setEnabled(false)
          store.setWorkspaceRealtimeRefreshActive(false)
          let saved = await store.prepareForTermination()
          emit(["id": id, "result": ["stopped": saved]])
          Foundation.exit(saved ? 0 : 1)
        default:
          result = ["error": "Unknown server control command"]
        }
        emit(["id": id, "result": result])
      }
      // Losing the supervisor closes stdin. Persist interruption state before exit.
      store.setAutomationSchedulerActive(false)
      store.setSourceAutoSyncActive(false)
      remote.setEnabled(false)
      _ = await store.prepareForTermination()
    } catch {
      FileHandle.standardError.write(Data("Celorga server: \(error.localizedDescription)\n".utf8))
      Foundation.exit(1)
    }
  }

  private static func repairTranscript() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.count >= 2 else { throw CocoaError(.fileReadInvalidFileName) }
    let root = URL(fileURLWithPath: arguments[1]).standardizedFileURL
    var apply = false
    var interval: Double?
    var revision: String?
    var index = 2
    while index < arguments.count {
      switch arguments[index] {
      case "--apply": apply = true
      case "--interval", "--if-revision":
        guard index + 1 < arguments.count else { throw CocoaError(.fileReadInvalidFileName) }
        if arguments[index] == "--interval" {
          guard let seconds = Double(arguments[index + 1]), seconds.isFinite,
                seconds >= 10, seconds <= 86_400 else { throw CocoaError(.fileReadInvalidFileName) }
          interval = seconds
        } else { revision = arguments[index + 1] }
        index += 1
      default: throw CocoaError(.fileReadInvalidFileName)
      }
      index += 1
    }
    guard interval == nil || revision == nil else { throw CocoaError(.fileReadInvalidFileName) }
    let shouldApply = apply
    let expectedRevision = revision
    let watch = interval != nil
    repeat {
      do {
        let report = try await Task.detached(priority: .utility) {
          try AIChatTranscriptRepair.run(corpusRoot: root, apply: shouldApply,
            expectedRevision: expectedRevision, onlyIfChanged: watch && shouldApply)
        }.value
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report) + Data([10]))
      } catch {
        guard interval != nil else { throw error }
        emit(["schema": "org2:ai-chat-repair:v1", "applied": false, "error": error.localizedDescription])
      }
      if let interval { try await Task.sleep(for: .seconds(interval)) }
    } while interval != nil
  }

  private static func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data + Data([10]))
  }
}
