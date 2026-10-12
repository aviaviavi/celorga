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

/// Card header: a tinted symbol, a title, and an optional trailing summary.
struct RunCardHeader: View {
  let title: String
  let symbol: String
  var tint: Color = WorkspaceDesign.structuralAccent
  var trailing: String?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 22, height: 22)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
      Text(title).font(.headline)
      Spacer(minLength: 8)
      if let trailing {
        Text(trailing)
          .font(.caption.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
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

/// One fact in the run's at-a-glance strip.
struct RunGlanceTile<Accessory: View>: View {
  let label: String
  let symbol: String
  let value: String
  let detail: String?
  var valueTint: Color = WorkspaceDesign.primaryText
  @ViewBuilder var accessory: Accessory

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(label, systemImage: symbol)
        .font(.caption2.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text(value)
        .font(.callout.weight(.semibold))
        .foregroundStyle(valueTint)
        .lineLimit(1)
      accessory
      if let detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 9)
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .background(WorkspaceDesign.panelFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(WorkspaceDesign.hairline, lineWidth: 0.75)
    }
    .accessibilityElement(children: .combine)
  }
}

extension RunGlanceTile where Accessory == EmptyView {
  init(label: String, symbol: String, value: String, detail: String?, valueTint: Color = WorkspaceDesign.primaryText) {
    self.init(label: label, symbol: symbol, value: value, detail: detail, valueTint: valueTint) { EmptyView() }
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
          Text(state.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(state == .upcoming ? WorkspaceDesign.tertiaryText : state.color)
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
    let size: CGFloat = 26
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
          if !compact, let badge = RunDetailPresentation.reviewBadge(artifact.reviewStatus, runFinished: runFinished) {
            RunToneBadge(badge: badge).padding(.top, 2)
          }
        }
        Spacer(minLength: 4)
        if compact, let badge = RunDetailPresentation.reviewBadge(artifact.reviewStatus, runFinished: runFinished) {
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

/// A validation result as a compact chip; failing checks show their detail.
struct RunCheckChip: View {
  let validation: AgentRunValidationItem

  var body: some View {
    let badge = RunDetailPresentation.checkBadge(validation.status)
    HStack(spacing: 6) {
      Image(systemName: badge.symbol)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(badge.tone.color)
      Text(validation.displayName)
        .font(.caption.weight(.medium))
        .foregroundStyle(WorkspaceDesign.primaryText)
        .lineLimit(1)
    }
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(badge.tone.color.opacity(0.09), in: Capsule())
    .overlay(Capsule().stroke(badge.tone.color.opacity(0.22), lineWidth: 0.75))
    .help(validation.detail.map { "\(badge.text): \($0)" } ?? badge.text)
    .accessibilityElement(children: .combine)
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
        HStack(spacing: 6) {
          Text(comment.author).font(.caption.weight(.semibold))
          Text(AgentRunTimestampPresentation.displayText(for: comment.createdAt))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
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

/// A clickable source the run cited.
struct RunSourceChip: View {
  let context: AgentRunContextItem
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      Label(context.displayTitle, systemImage: context.isMeetingReference ? "waveform" : "doc.text")
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(WorkspaceDesign.controlFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(context.fileReference == nil)
    .help(context.citation ?? context.ref)
  }
}

/// Wraps chips onto as many rows as needed. Measures each subview once.
struct RunChipFlowLayout: Layout {
  var spacing: CGFloat = 6

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews).size
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let arrangement = arrange(maxWidth: bounds.width, subviews: subviews)
    for (index, origin) in arrangement.origins.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
        proposal: ProposedViewSize(arrangement.sizes[index])
      )
    }
  }

  private func arrange(maxWidth: CGFloat, subviews: Subviews) -> (origins: [CGPoint], sizes: [CGSize], size: CGSize) {
    var origins: [CGPoint] = []
    var sizes: [CGSize] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var rowHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      var size = subview.sizeThatFits(.unspecified)
      size.width = min(size.width, maxWidth)
      if x > 0, x + size.width > maxWidth {
        x = 0
        y += rowHeight + spacing
        rowHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      sizes.append(size)
      x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return (origins, sizes, CGSize(width: widest, height: y + rowHeight))
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
