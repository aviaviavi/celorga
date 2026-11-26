import Foundation

/// One shared-room agent's model and reasoning choices for a paired phone.
public struct AIChatRemoteRoomDestinationConfiguration: Sendable, Equatable {
  public let destinationID: String
  public let name: String
  public let model: String?
  public let models: [AIChatModelOption]
  public let reasoningEffort: String?
  public let reasoningOptions: [AIChatReasoningOption]
  public let defaultReasoningEffort: String?
  public let error: String?
}

/// Model control for every agent in a shared room, by thread ID, so the Mac
/// composer and a paired phone change the same per-destination choices.
extension WorkspaceStore {
  /// How long one room agent may take to list its models before the room's
  /// answer reports it as still loading. Its listing keeps running and fills
  /// the catalog cache for the next request.
  nonisolated static let aiChatRoomModelListingTimeout: Duration = .seconds(12)

  public func aiChatRemoteRoomConfiguration(
    for threadID: UUID
  ) async throws -> [AIChatRemoteRoomDestinationConfiguration] {
    guard let thread = aiChatThread(withID: threadID), thread.isSharedRoom else {
      throw AIChatRemoteConfigurationError.threadNotFound
    }
    let destinationIDs = thread.roomDestinationIDs
    var listings: [String: Result<[AIChatModelOption], Error>] = [:]
    await withTaskGroup(of: (String, Result<[AIChatModelOption], Error>).self) { group in
      for destinationID in destinationIDs {
        group.addTask { [weak self] in
          guard let self else {
            return (destinationID, .failure(AIChatRemoteConfigurationError.threadNotFound))
          }
          do {
            let models = try await Self.withAIChatRoomTimeout(Self.aiChatRoomModelListingTimeout) {
              try await self.remoteModelsForAIChatDestination(destinationID)
            }
            return (destinationID, .success(models))
          } catch {
            return (destinationID, .failure(error))
          }
        }
      }
      for await (destinationID, result) in group {
        listings[destinationID] = result
      }
    }
    let current = aiChatThread(withID: threadID) ?? thread
    return destinationIDs.map { destinationID in
      let models: [AIChatModelOption]
      let error: String?
      switch listings[destinationID] {
      case .success(let listed):
        models = listed
        error = nil
      case .failure(let failure):
        models = aiChatConfigurationCatalogCache[destinationID]?.models ?? []
        error = failure is AIChatRoomTimeoutError
          ? "\(aiChatDestinationTitle(destinationID)) is still loading its models."
          : failure.localizedDescription
      case nil:
        models = []
        error = nil
      }
      return roomDestinationConfiguration(
        destinationID: destinationID,
        thread: current,
        models: models,
        error: error
      )
    }
  }

  func roomDestinationConfiguration(
    destinationID: String,
    thread: AIChatThread,
    models: [AIChatModelOption],
    error: String? = nil
  ) -> AIChatRemoteRoomDestinationConfiguration {
    let destination = aiChatDestination(id: destinationID)
    let model = thread.model(forDestinationID: destinationID)
    let reasoningOptions = destination.map {
      Self.aiChatRoomReasoningOptions(
        adapter: $0.adapter,
        selectedModel: model,
        models: models,
        preset: $0.providerPreset
      )
    } ?? []
    let selectedOption = model.flatMap { selected in models.first(where: { $0.id == selected }) }
      ?? models.first(where: \.isDefault)
    return AIChatRemoteRoomDestinationConfiguration(
      destinationID: destinationID,
      name: aiChatDestinationTitle(destinationID),
      model: model,
      models: models,
      reasoningEffort: thread.roomReasoningEffortsByDestination[destinationID],
      reasoningOptions: reasoningOptions,
      defaultReasoningEffort: destination?.providerPreset?.defaultReasoningEffort
        ?? selectedOption?.defaultReasoningEffort,
      error: error
    )
  }

  /// Chooses the model one room agent uses. A model missing from the cached
  /// catalog is confirmed against a live listing before it is refused.
  public func setAIChatRemoteRoomModel(
    _ model: String?,
    destinationID: String,
    threadID: UUID
  ) async throws {
    guard let thread = aiChatThread(withID: threadID), thread.isSharedRoom,
          thread.roomDestinationIDs.contains(destinationID)
    else {
      throw AIChatRemoteConfigurationError.unknownDestination(destinationID)
    }
    if let model {
      var options = aiChatConfigurationCatalogCache[destinationID]?.models ?? []
      if !options.contains(where: { $0.id == model }) {
        options = try await modelsForAIChatDestination(destinationID)
        cacheAIChatModelCatalog(destinationID: destinationID, models: options)
        guard options.contains(where: { $0.id == model }) else {
          throw AIChatRemoteConfigurationError.unknownModel(model)
        }
      }
    }
    setAIChatRoomModel(model, forDestinationID: destinationID, threadID: threadID)
  }

  public func setAIChatRemoteRoomReasoningEffort(
    _ reasoningEffort: String?,
    destinationID: String,
    threadID: UUID
  ) async throws {
    guard let thread = aiChatThread(withID: threadID), thread.isSharedRoom,
          thread.roomDestinationIDs.contains(destinationID)
    else {
      throw AIChatRemoteConfigurationError.unknownDestination(destinationID)
    }
    if let reasoningEffort {
      let configuration = roomDestinationConfiguration(
        destinationID: destinationID,
        thread: thread,
        models: aiChatConfigurationCatalogCache[destinationID]?.models ?? []
      )
      guard configuration.reasoningOptions.contains(where: { $0.id == reasoningEffort }) else {
        throw AIChatRemoteConfigurationError.unknownReasoningEffort(reasoningEffort)
      }
    }
    setAIChatRoomReasoningEffort(reasoningEffort, forDestinationID: destinationID, threadID: threadID)
  }

  /// Records a room agent's model. A different model may not support the
  /// previous effort, so the agent returns to its default effort.
  @discardableResult
  func setAIChatRoomModel(
    _ model: String?,
    forDestinationID destinationID: String,
    threadID: UUID
  ) -> Bool {
    guard let index = aiChatThreads.firstIndex(where: { $0.id == threadID }),
          aiChatThreads[index].isSharedRoom,
          aiChatThreads[index].model(forDestinationID: destinationID) != model
    else {
      return false
    }
    var nextModels = aiChatThreads[index].roomModelsByDestination
    nextModels[destinationID] = model
    if model == nil { nextModels.removeValue(forKey: destinationID) }
    var nextEfforts = aiChatThreads[index].roomReasoningEffortsByDestination
    nextEfforts.removeValue(forKey: destinationID)
    let runtime = aiChatDestinationRuntime(destinationID)
    let legacyModels = aiChatThreads[index].roomModels.replacingModel(model, for: runtime)
    aiChatThreads[index] = aiChatThreads[index]
      .replacingAIChatMetadata(
        roomModels: legacyModels,
        roomModelsByDestination: nextModels,
        roomReasoningEffortsByDestination: nextEfforts
      )
    persistAIChatTranscript()
    return true
  }

  @discardableResult
  func setAIChatRoomReasoningEffort(
    _ reasoningEffort: String?,
    forDestinationID destinationID: String,
    threadID: UUID
  ) -> Bool {
    guard let index = aiChatThreads.firstIndex(where: { $0.id == threadID }),
          aiChatThreads[index].isSharedRoom,
          aiChatThreads[index].roomDestinationIDs.contains(destinationID),
          aiChatThreads[index].roomReasoningEffortsByDestination[destinationID] != reasoningEffort
    else {
      return false
    }
    var nextEfforts = aiChatThreads[index].roomReasoningEffortsByDestination
    nextEfforts[destinationID] = reasoningEffort
    aiChatThreads[index] = aiChatThreads[index]
      .replacingAIChatMetadata(roomReasoningEffortsByDestination: nextEfforts)
    persistAIChatTranscript()
    return true
  }

  /// Returns the operation's result, or throws `AIChatRoomTimeoutError` once
  /// `timeout` passes. The operation is not awaited past the deadline.
  nonisolated static func withAIChatRoomTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let gate = AIChatRoomTimeoutGate<T>()
    return try await withCheckedThrowingContinuation { continuation in
      gate.install(continuation)
      Task {
        do {
          gate.resume(with: .success(try await operation()))
        } catch {
          gate.resume(with: .failure(error))
        }
      }
      Task {
        try? await Task.sleep(for: timeout)
        gate.resume(with: .failure(AIChatRoomTimeoutError()))
      }
    }
  }
}

struct AIChatRoomTimeoutError: LocalizedError {
  var errorDescription: String? { "The agent did not list its models in time." }
}

/// Resumes a continuation once, from whichever of the work and the deadline
/// finishes first.
private final class AIChatRoomTimeoutGate<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?
  private var pending: Result<T, Error>?
  private var finished = false

  func install(_ continuation: CheckedContinuation<T, Error>) {
    lock.lock()
    if let pending {
      finished = true
      lock.unlock()
      continuation.resume(with: pending)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func resume(with result: Result<T, Error>) {
    lock.lock()
    guard !finished else {
      lock.unlock()
      return
    }
    guard let continuation else {
      if pending == nil { pending = result }
      lock.unlock()
      return
    }
    finished = true
    self.continuation = nil
    lock.unlock()
    continuation.resume(with: result)
  }
}
