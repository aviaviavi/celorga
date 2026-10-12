import SwiftUI

// Visual building blocks for the Agent Work run detail. They are static
// shapes and SF Symbols only: no timers, blurs, or GeometryReader, so the
// pane costs about the same to render as the text layout it replaces.

extension RunDetailTone {
  var color: Color {
    switch self {
    case .positive: WorkspaceDesign.themed(.done)
    case .neutral: WorkspaceDesign.secondaryText
    case .caution: .orange
    case .critical: .red
    }
  }
}

extension RunStepVisualState {
  var color: Color {
    switch self {
    case .done: WorkspaceDesign.themed(.done)
    case .current: WorkspaceDesign.structuralAccent
    case .waitingOnYou: .orange
    case .failed: .red
    case .blocked: .orange
    case .skipped, .upcoming: WorkspaceDesign.tertiaryText
    }
  }
}

/// Small capsule label with a symbol, tinted by tone.
struct RunToneBadge: View {
  let badge: RunBadgePresentation

  var body: some View {
    Label(badge.text, systemImage: badge.symbol)
      .font(.caption2.weight(.semibold))
      .labelStyle(.titleAndIcon)
      .foregroundStyle(badge.tone.color)
      .padding(.horizontal, 7)
      .padding(.vertical, 2)
      .background(badge.tone.color.opacity(0.12), in: Capsule())
      .fixedSize()
  }
}

/// A run's progress as one segment per step, or a continuous bar for long plans.
struct RunSegmentedProgress: View {
  let plan: [AgentRunStepItem]
  let hasPendingApproval: Bool
  var height: CGFloat = 5

  var body: some View {
    if plan.count <= RunDetailPresentation.maxProgressSegments {
      HStack(spacing: 3) {
        ForEach(plan) { step in
          Capsule()
            .fill(segmentColor(RunDetailPresentation.stepState(step, hasPendingApproval: hasPendingApproval)))
            .frame(height: height)
        }
      }
    } else {
      Capsule()
        .fill(WorkspaceDesign.controlFill)
        .frame(height: height)
        .overlay(alignment: .leading) {
          Capsule()
            .fill(WorkspaceDesign.themed(.done))
            .frame(height: height)
            .scaleEffect(x: max(0.001, RunDetailPresentation.progressFraction(plan)), y: 1, anchor: .leading)
        }
    }
  }

  private func segmentColor(_ state: RunStepVisualState) -> Color {
    switch state {
    case .upcoming: WorkspaceDesign.controlFill
    case .skipped: WorkspaceDesign.tertiaryText.opacity(0.35)
    default: state.color
    }
  }
}

/// Horizontal pipeline of plan steps with connectors. Used for short plans.
struct RunStepTrack: View {
  let plan: [AgentRunStepItem]
  let hasPendingApproval: Bool

  var body: some View {
    let states = plan.map { RunDetailPresentation.stepState($0, hasPendingApproval: hasPendingApproval) }
    HStack(alignment: .top, spacing: 0) {
      ForEach(Array(plan.enumerated()), id: \.element.id) { index, step in
        let state = states[index]
        VStack(spacing: 7) {
          HStack(spacing: 0) {
            connector(color: index > 0 && states[index - 1] == .done ? WorkspaceDesign.themed(.done) : WorkspaceDesign.hairline)
              .opacity(index == 0 ? 0 : 1)
            node(state)
            connector(color: state == .done ? WorkspaceDesign.themed(.done) : WorkspaceDesign.hairline)
              .opacity(index == plan.count - 1 ? 0 : 1)
          }
          Text(step.title)
            .font(.caption.weight(isFocus(state) ? .semibold : .regular))
            .foregroundStyle(state == .upcoming ? WorkspaceDesign.secondaryText : WorkspaceDesign.primaryText)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
          if isFocus(state) {
            Text(state.label)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(state.color)
          }
        }
        .frame(maxWidth: .infinity)
        .help("\(step.title) · \(AgentRunItem.humanizedLabel(step.kind)) · \(state.label)")
        .accessibilityElement(children: .combine)
      }
    }
  }

  private func isFocus(_ state: RunStepVisualState) -> Bool {
    state == .current || state == .waitingOnYou || state == .failed || state == .blocked
  }

  private func connector(color: Color) -> some View {
    Rectangle().fill(color).frame(height: 2)
  }

  @ViewBuilder
  private func node(_ state: RunStepVisualState) -> some View {
    let size: CGFloat = 22
    switch state {
    case .upcoming:
      Circle()
        .strokeBorder(WorkspaceDesign.hairline, lineWidth: 1.5)
        .frame(width: size, height: size)
    case .current:
      Circle()
        .strokeBorder(state.color, lineWidth: 2)
        .background(Circle().fill(state.color.opacity(0.12)))
        .overlay(Circle().fill(state.color).frame(width: 8, height: 8))
        .frame(width: size, height: size)
    case .skipped:
      Circle()
        .fill(WorkspaceDesign.controlFill)
        .overlay(Image(systemName: state.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary))
        .frame(width: size, height: size)
    default:
      Circle()
        .fill(state.color)
        .overlay(Image(systemName: state.symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
        .frame(width: size, height: size)
        .background(
          Circle()
            .fill(state.color.opacity(state == .waitingOnYou ? 0.18 : 0))
            .frame(width: size + 8, height: size + 8)
        )
    }
  }
}

/// A run output as a clickable document tile.
struct RunOutputTile: View {
  let artifact: AgentRunArtifactItem
  let runFinished: Bool
  var compact = false
  var showsReviewBadge = true
  let open: () -> Void
  @State private var isHovering = false

  var body: some View {
    Button(action: open) {
      HStack(alignment: compact ? .center : .top, spacing: 10) {
        Image(systemName: RunDetailPresentation.artifactSymbol(
          role: artifact.role,
          mediaType: artifact.mediaType,
          path: artifact.path
        ))
        .font(.system(size: compact ? 13 : 16, weight: .medium))
        .foregroundStyle(WorkspaceDesign.structuralAccent)
        .frame(width: compact ? 28 : 36, height: compact ? 28 : 36)
        .background(
          WorkspaceDesign.structuralAccent.opacity(0.1),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        VStack(alignment: .leading, spacing: 3) {
          Text(artifact.displayTitle)
            .font(.callout.weight(.semibold))
            .foregroundStyle(WorkspaceDesign.primaryText)
            .lineLimit(compact ? 1 : 2)
          if !compact {
            Text("\(artifact.roleDisplayText) · \(RunDetailPresentation.fileName(artifact.path))")
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          if !compact, showsReviewBadge, let badge = RunDetailPresentation.reviewBadge(artifact.reviewStatus, runFinished: runFinished) {
            RunToneBadge(badge: badge).padding(.top, 2)
          }
        }
        Spacer(minLength: 4)
        if compact, showsReviewBadge, let badge = RunDetailPresentation.reviewBadge(artifact.reviewStatus, runFinished: runFinished) {
          RunToneBadge(badge: badge)
        }
        Image(systemName: "arrow.up.right")
          .font(.caption.weight(.semibold))
          .foregroundStyle(isHovering ? WorkspaceDesign.structuralAccent : WorkspaceDesign.tertiaryText)
      }
      .padding(compact ? 7 : 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        isHovering ? WorkspaceDesign.controlHoverFill : WorkspaceDesign.surfaceBackground,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(WorkspaceDesign.hairline, lineWidth: 0.75)
      }
      .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help("Open \(artifact.path) in Celorga")
  }
}

/// The agent's latest handoff note, styled as a message.
struct RunHandoffBubble: View {
  let comment: AgentRunCommentItem

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Text(RunDetailPresentation.initials(comment.author))
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .frame(width: 26, height: 26)
        .background(WorkspaceDesign.structuralAccent, in: Circle())
      VStack(alignment: .leading, spacing: 4) {
        Text(AgentRunTimestampPresentation.displayText(for: comment.createdAt))
          .font(.caption)
          .foregroundStyle(.tertiary)
        Text(comment.body)
          .font(.callout)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 11)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        WorkspaceDesign.subtleFill,
        in: UnevenRoundedRectangle(
          topLeadingRadius: 3,
          bottomLeadingRadius: 10,
          bottomTrailingRadius: 10,
          topTrailingRadius: 10,
          style: .continuous
        )
      )
    }
  }
}

/// Filled call-to-action for the one decision a person is being asked to make.
struct RunPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  var tint: Color = WorkspaceDesign.structuralAccent

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.semibold))
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, 12)
      .padding(.vertical, 5)
      .frame(minHeight: 28)
      .background(
        tint.opacity(configuration.isPressed ? 0.8 : 1),
        in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
      )
      .opacity(isEnabled ? 1 : 0.45)
      .contentShape(RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous))
  }
}

/// Outlined secondary action that still reads as a button at rest.
struct RunSecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  var tint: Color = WorkspaceDesign.primaryText

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.callout.weight(.medium))
      .foregroundStyle(tint)
      .lineLimit(1)
      .padding(.horizontal, 11)
      .padding(.vertical, 5)
      .frame(minHeight: 28)
      .background(
        configuration.isPressed ? WorkspaceDesign.controlPressedFill : WorkspaceDesign.surfaceBackground,
        in: RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous)
          .stroke(WorkspaceDesign.hairline, lineWidth: 1)
      }
      .opacity(isEnabled ? 1 : 0.5)
      .contentShape(RoundedRectangle(cornerRadius: WorkspaceDesign.controlRadius, style: .continuous))
  }
}
