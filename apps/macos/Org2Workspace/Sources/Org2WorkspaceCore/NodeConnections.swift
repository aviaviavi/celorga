import Foundation
import SwiftUI

public struct NodeConnectionsPayload: Decodable, Sendable {
  public let root: String
  public let scannedFiles: Int
  public let neighborhood: NodeConnectionNeighborhood?
  public let mentions: [NodeUnlinkedMention]
  public let mentionsTruncated: Bool
}

public struct NodeConnectionNeighborhood: Decodable, Sendable {
  public let focus: NodeConnectionNode
  public let depth: Int
  public let truncated: Bool
  public let nodes: [NodeConnectionNode]
  public let edges: [NodeConnectionEdge]
}

public struct NodeConnectionNode: Decodable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let file: String
  public let line: Int
  public let degreeIn: Int
  public let degreeOut: Int

  public var location: WorkspaceLocation {
    connectionLocation(file: file, line: line, title: label, id: id)
  }
}

public struct NodeConnectionEdge: Decodable, Sendable {
  public let source: String
  public let target: String
  public let count: Int
}

public struct NodeMentionCandidate: Decodable, Identifiable, Sendable {
  public let id: String
  public let label: String
  public let file: String
}

public struct NodeUnlinkedMention: Decodable, Identifiable, Sendable {
  public let id: String
  public let file: String
  public let line: Int
  public let start: Int
  public let end: Int
  public let text: String
  public let context: String
  public let revision: String
  public let candidates: [NodeMentionCandidate]
  public let ambiguous: Bool

  public var location: WorkspaceLocation {
    connectionLocation(file: file, line: line, title: text, id: nil)
  }
}

public struct NodeMentionLinkPayload: Decodable, Sendable {
  public let file: String
  public let applied: Bool
  public let replacement: String
}

private func connectionLocation(file: String, line: Int, title: String, id: String?) -> WorkspaceLocation {
  .search(SearchResult(
    file: file, line: max(1, line), lineEnd: nil, heading: title, headingLine: line,
    headingLevel: nil, headingAncestry: nil, idValue: id, todo: nil, tags: [],
    snippet: title, sourceRange: nil, matchedLines: nil, date: nil
  ))
}

struct NodeConnectionsView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var payload: NodeConnectionsPayload?
  @State private var error: String?
  @State private var loading = false
  @State private var linking = false
  @State private var depth = 1
  @State private var focusID: String?
  @State private var refreshID = 0
  @State private var query = ""

  private var selectionKey: String {
    "\(store.corpusRoot?.path ?? "")|\(store.selectedLocation?.file ?? "")|\(store.selectedLocation?.lineForEditor ?? 1)"
  }

  private var requestKey: String {
    "\(selectionKey)|\(focusID ?? "")|\(depth)|\(refreshID)|\(store.selectedEntrySource?.text.hashValue ?? 0)"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("Local graph").font(.headline)
        Spacer()
        Button {
          refreshID += 1
        } label: { Label("Refresh connections", systemImage: "arrow.clockwise") }
          .labelStyle(.iconOnly)
          .disabled(loading || linking)
          .help("Scan the active corpus again")
      }
      Picker("Neighborhood depth", selection: $depth) {
        Text("1 hop").tag(1)
        Text("2 hops").tag(2)
      }.pickerStyle(.segmented)
      if loading { ProgressView("Loading connections…").font(.caption) }
      if let error {
        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
      }
      if let graph = payload?.neighborhood {
        graphContent(graph)
      } else if !loading {
        Text("Open a note or heading with a stable ID to discover its connections. Add a stable ID in the source, then refresh.")
          .font(.callout).foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .task(id: requestKey) { await refresh() }
    .onChange(of: selectionKey) { _, _ in focusID = nil; query = "" }
  }

  @ViewBuilder private func graphContent(_ graph: NodeConnectionNeighborhood) -> some View {
    Text(graph.focus.label).font(.title3.weight(.semibold)).textSelection(.enabled)
    HStack {
      Button("Open source", systemImage: "doc.text") { store.select(graph.focus.location) }
      Spacer()
      if focusID != nil {
        Button("Current note") { focusID = nil }
      }
    }
    .font(.caption)
    Text("Click a node to explore it. Drag nodes to arrange the graph. Arrows point to linked targets.")
      .font(.caption).foregroundStyle(.secondary)
    NodeNeighborhoodDrawing(graph: graph, select: { focusID = $0 })
      .frame(height: 300)
      .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    if graph.truncated {
      Text("Showing at most 60 nodes. Explore a neighbor to continue.").font(.caption).foregroundStyle(.secondary)
    }
    TextField("Find a visible node", text: $query)
      .textFieldStyle(.roundedBorder)
    ForEach(graph.nodes.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }) { node in
      HStack(alignment: .top) {
        Button {
          focusID = node.id
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(node.label).lineLimit(2)
            Text("\(node.degreeIn) incoming · \(node.degreeOut) outgoing").font(.caption2).foregroundStyle(.secondary)
          }
        }.buttonStyle(.plain)
        Spacer()
        Button { store.select(node.location) } label: { Image(systemName: "arrow.up.right.square") }
          .help("Open \(node.label) at line \(node.line)")
          .accessibilityLabel("Open \(node.label)")
      }
    }
    Divider()
    Text("Unlinked mentions").font(.headline)
    Text("Exact titles and aliases in other files. Each action links only the occurrence shown.")
      .font(.caption).foregroundStyle(.secondary)
    if let payload {
      if payload.mentions.isEmpty {
        Text("No unlinked mentions found.").font(.callout).foregroundStyle(.secondary)
      }
      ForEach(payload.mentions) { mention in
        mentionRow(mention)
      }
      if payload.mentionsTruncated {
        Text("Showing the first 200 mentions. Link and refresh to continue.").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func mentionRow(_ mention: NodeUnlinkedMention) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(mention.context).font(.callout).textSelection(.enabled)
      Button { store.select(mention.location) } label: {
        Label("\(store.relativePath(mention.file)):\(mention.line)", systemImage: "doc.text")
          .font(.caption).lineLimit(2)
      }.buttonStyle(.plain)
      if mention.ambiguous {
        Menu("Choose target for ‘\(mention.text)’…") {
          ForEach(mention.candidates) { candidate in
            Button("\(candidate.label) — \(store.relativePath(candidate.file)) [\(candidate.id)]") {
              link(mention, target: candidate.id)
            }
          }
        }
        .help("This title or alias has multiple targets; choose the intended note")
        .disabled(linking || loading)
      } else if let candidate = mention.candidates.first {
        Button("Link ‘\(mention.text)’", systemImage: "link") { link(mention, target: candidate.id) }
          .disabled(linking || loading)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
  }

  @MainActor private func refresh() async {
    guard let root = store.corpusRoot, let location = store.selectedLocation else {
      payload = nil
      return
    }
    let key = requestKey
    loading = true
    error = nil
    defer { if key == requestKey { loading = false } }
    var args = ["roam", "connections", "--dir", root.path, "--depth", "\(depth)", "--format", "json"]
    if let focusID { args += ["--id", focusID] }
    else { args += ["--file", location.file, "--line", "\(location.lineForEditor)"] }
    do {
      let result: NodeConnectionsPayload = try await store.cli.runJSON(args)
      guard !Task.isCancelled, key == requestKey else { return }
      payload = result
    } catch {
      guard !Task.isCancelled, key == requestKey else { return }
      self.error = error.localizedDescription
      payload = nil
    }
  }

  private func link(_ mention: NodeUnlinkedMention, target: String) {
    guard let root = store.corpusRoot?.path else { return }
    linking = true
    error = nil
    Task { @MainActor in
      defer { linking = false }
      do {
        try await store.linkConnectionMention(mention, target: target, root: root)
        refreshID += 1
      } catch {
        self.error = error.localizedDescription
      }
    }
  }
}

struct NodeNeighborhoodDrawing: View {
  let graph: NodeConnectionNeighborhood
  let select: (String) -> Void
  @State private var moved: [String: CGPoint] = [:]

  var body: some View {
    GeometryReader { geometry in
      let points = positions(size: geometry.size)
      ZStack {
        Canvas { context, _ in
          for edge in graph.edges {
            guard let start = points[edge.source], let end = points[edge.target] else { continue }
            let angle = atan2(end.y - start.y, end.x - start.x)
            let tip = CGPoint(x: end.x - cos(angle) * 26, y: end.y - sin(angle) * 26)
            var path = Path()
            path.move(to: start); path.addLine(to: tip)
            path.move(to: CGPoint(x: tip.x - cos(angle - 0.5) * 9, y: tip.y - sin(angle - 0.5) * 9))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: tip.x - cos(angle + 0.5) * 9, y: tip.y - sin(angle + 0.5) * 9))
            context.stroke(path, with: .color(.secondary.opacity(0.45)), lineWidth: 1.3)
          }
        }.allowsHitTesting(false)
        ForEach(graph.nodes) { node in
          if let point = points[node.id] {
            Button { select(node.id) } label: {
              VStack(spacing: 3) {
                Circle().fill(node.id == graph.focus.id ? Color.accentColor : Color.secondary)
                  .frame(width: node.id == graph.focus.id ? 20 : 13, height: node.id == graph.focus.id ? 20 : 13)
                Text(node.label).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                  .padding(2).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
              }.frame(width: 86)
            }
            .buttonStyle(.plain)
            .help("Explore \(node.label)")
            .accessibilityLabel("Explore \(node.label)")
            .position(point)
            .simultaneousGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named("neighborhood")).onChanged { drag in
              moved[node.id] = CGPoint(x: min(max(44, drag.location.x), geometry.size.width - 44), y: min(max(28, drag.location.y), geometry.size.height - 28))
            })
          }
        }
      }
      .coordinateSpace(name: "neighborhood")
    }
    .onChange(of: graph.focus.id) { _, _ in moved = [:] }
  }

  private func positions(size: CGSize) -> [String: CGPoint] {
    var positions = moved
    let neighbors = graph.nodes.filter { $0.id != graph.focus.id }
    let centerX: CGFloat = size.width / 2
    let centerY: CGFloat = size.height / 2
    if positions[graph.focus.id] == nil { positions[graph.focus.id] = CGPoint(x: centerX, y: centerY) }
    let radiusX: CGFloat = max(20, centerX - 48)
    let radiusY: CGFloat = centerY - 35
    let count = Double(max(neighbors.count, 1))
    for (index, node) in neighbors.enumerated() where positions[node.id] == nil {
      let angle: Double = Double(index) / count * Double.pi * 2 - Double.pi / 2
      let x: CGFloat = centerX + CGFloat(cos(angle)) * radiusX
      let y: CGFloat = centerY + CGFloat(sin(angle)) * radiusY
      positions[node.id] = CGPoint(x: x, y: y)
    }
    return positions
  }
}
