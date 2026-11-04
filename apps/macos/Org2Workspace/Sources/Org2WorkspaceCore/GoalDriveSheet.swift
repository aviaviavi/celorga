import SwiftUI

/// How often the driver may start a pass. Passes never overlap, and Celorga
/// skips a pass when the goal is waiting on a person, stalled, or over budget.
enum GoalDriveCadence: String, CaseIterable, Identifiable {
  case fifteenMinutes = "every 15m"
  case thirtyMinutes = "every 30m"
  case hourly = "every 1h"
  case fourHours = "every 4h"
  case daily = "every 1d"

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fifteenMinutes: return "Every 15 minutes"
    case .thirtyMinutes: return "Every 30 minutes"
    case .hourly: return "Every hour"
    case .fourHours: return "Every 4 hours"
    case .daily: return "Once a day"
    }
  }
}

/// Sheet behind Drive Goal: starts or reconfigures `celorga goal drive`.
struct GoalDriveSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  let goal: AgentGoalItem

  @State private var schedule = GoalDriveCadence.fifteenMinutes.rawValue
  @State private var stallAfter = 3
  @State private var dailyBudget = ""
  @State private var permissions = ""
  @State private var agentRef = ""
  @State private var destinationID = ""
  @State private var isSaving = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text(goal.drive == nil ? "Drive Goal" : "Drive Settings")
          .font(.title3.weight(.semibold))
        Text(goal.title)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Text("An agent works the goal's plan one pass at a time. Each pass takes the top agent item, updates the plan, and checkpoints. Celorga pauses the drive when only your items are left, when the budget is spent, or when passes stop making progress.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      Form {
        Picker("Passes", selection: $schedule) {
          ForEach(GoalDriveCadence.allCases) { cadence in
            Text(cadence.title).tag(cadence.rawValue)
          }
          if GoalDriveCadence(rawValue: schedule) == nil {
            Text(schedule).tag(schedule)
          }
        }
        .help("How often a new pass may start. A pass never starts while the previous one is open.")

        Stepper(value: $stallAfter, in: 1...10) {
          Text("Stall after \(stallAfter) pass\(stallAfter == 1 ? "" : "es") without progress")
        }
        .help("Progress means a plan item changed state, a new item was added, or a checkbox was ticked.")

        TextField("Daily budget (USD)", text: $dailyBudget, prompt: Text("No limit"))
          .help("Rolling 24-hour cost limit across driver passes, from recorded run usage.")

        Picker("Agent", selection: $agentRef) {
          Text("Default assistant").tag("")
          if !store.agentProfiles.isEmpty { Divider() }
          ForEach(store.agentProfiles) { profile in
            Text(profile.name).tag(profile.id)
          }
          if !agentRef.isEmpty, !store.agentProfiles.contains(where: { $0.id == agentRef }) {
            Text(agentRef).tag(agentRef)
          }
        }

        Picker("Harness", selection: $destinationID) {
          ForEach(store.enabledAIChatDestinations) { destination in
            Label(destination.title, systemImage: destination.systemImage)
              .tag(destination.id)
          }
        }
        .help("Where driver passes run.")

        VStack(alignment: .leading, spacing: 6) {
          Text("Standing permissions")
          TextEditor(text: $permissions)
            .font(.callout)
            .frame(minHeight: 72)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(WorkspaceDesign.hairline))
          Text("One per line, for example “Open pull requests, never merge.” Anything else becomes an item for you in the plan instead of an action.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .formStyle(.grouped)

      HStack {
        if isSaving { WorkspaceActivityIndicator(size: .small) }
        Spacer()
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button(goal.drive == nil ? "Start Driving" : "Save") {
          Task { await save() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isSaving || destinationID.isEmpty || !budgetIsValid)
      }
    }
    .padding(20)
    .frame(width: 480)
    .onAppear(perform: loadDefaults)
  }

  private var parsedBudget: Double? {
    let trimmed = dailyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "$"))
    return trimmed.isEmpty ? nil : Double(trimmed)
  }

  private var budgetIsValid: Bool {
    let trimmed = dailyBudget.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    guard let value = parsedBudget else { return false }
    return value > 0
  }

  private func loadDefaults() {
    let workflow = goal.drive.flatMap { drive in store.agentWorkflows.first(where: { $0.id == drive.workflowRef }) }
    if let drive = goal.drive {
      stallAfter = drive.stallAfter
      dailyBudget = drive.dailyCostLimitUsd.map { String(format: "%g", $0) } ?? ""
      permissions = drive.permissions.joined(separator: "\n")
    }
    if let existing = workflow?.triggers.first(where: { $0.type == "schedule" })?.schedule {
      schedule = existing
    }
    agentRef = workflow?.agentRef ?? goal.ownerAgentRef ?? ""
    let enabled = store.enabledAIChatDestinations
    let candidates = [workflow?.destinationRef, store.defaultRunDestinationID, store.defaultRunDestination?.id]
    destinationID = candidates.compactMap { $0 }.first(where: { id in enabled.contains(where: { $0.id == id }) })
      ?? enabled.first?.id ?? ""
  }

  private func save() async {
    isSaving = true
    defer { isSaving = false }
    let options = AgentGoalDriveOptions(
      schedule: schedule,
      stallAfter: stallAfter,
      dailyCostLimitUsd: parsedBudget,
      permissions: permissions.components(separatedBy: .newlines),
      agentRef: agentRef,
      destinationID: destinationID
    )
    if await store.startAgentGoalDrive(goal, options: options) { dismiss() }
  }
}
