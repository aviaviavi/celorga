import AppKit
import SwiftUI

/// Header chip for the files a chat thread edited or linked. Stays visible
/// however long the thread gets; clicking it opens the Outputs popover.
struct AIChatThreadOutputsChip: View {
  let outputs: AIChatThreadOutputs
  let onJumpToMessage: (UUID) -> Void
  @State private var isPresented = false

  var body: some View {
    Button {
      isPresented.toggle()
    } label: {
      HStack(spacing: 5) {
        Image(systemName: outputs.folder == nil ? "doc.on.doc" : "folder")
        if let folder = outputs.folder {
          Text((folder as NSString).lastPathComponent)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 180, alignment: .leading)
          Text("·").foregroundStyle(.secondary)
        }
        Text(countText)
          .foregroundStyle(outputs.folder == nil ? .primary : .secondary)
          .lineLimit(1)
        if outputs.staleCount > 0 {
          Label("\(outputs.staleCount) stale", systemImage: "exclamationmark.triangle.fill")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.orange)
            .lineLimit(1)
        }
      }
      .font(.caption.weight(.medium))
      .fixedSize(horizontal: true, vertical: false)
    }
    .help(helpText)
    .accessibilityIdentifier("ai-chat-thread-outputs-chip")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      AIChatThreadOutputsPanel(
        outputs: outputs,
        onOpen: { isPresented = false },
        onJumpToMessage: { id in
          isPresented = false
          onJumpToMessage(id)
        }
      )
    }
  }

  private var countText: String {
    let count = outputs.groupsInFolder.count
    return "\(count)\(outputs.isTruncated ? "+" : "") output\(count == 1 && !outputs.isTruncated ? "" : "s")"
  }

  private var helpText: String {
    if let folder = outputs.folder {
      return "Files this thread edited or linked, mostly in \(outputs.displayPath(folder))"
    }
    return "Files this thread edited or linked"
  }
}

struct AIChatThreadOutputsPanel: View {
  @Environment(WorkspaceStore.self) private var store
  let outputs: AIChatThreadOutputs
  let onOpen: () -> Void
  let onJumpToMessage: (UUID) -> Void
  @State private var showsElsewhere = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Outputs").font(.headline)
        Spacer()
        Text(
          outputs.isTruncated
            ? "\(AIChatThreadOutputs.maxGroups) most recent in this thread"
            : "Edited or linked in this thread"
        )
          .font(.caption)
          .foregroundStyle(.secondary)
          .help(
            outputs.isTruncated
              ? "Long threads show only the most recently edited or linked files"
              : ""
          )
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 10)
      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          if let folder = outputs.folder {
            section("Folder") {
              AIChatOutputsFolderRow(
                path: folder,
                displayPath: outputs.displayPath(folder),
                touchedPaths: outputs.touchedPaths,
                onOpen: onOpen
              )
            }
          }

          section(outputs.folder == nil ? "Files" : "In this folder") {
            ForEach(outputs.groupsInFolder) { group in
              groupRow(group, relativeTo: outputs.folder)
            }
          }

          let elsewhere = outputs.groupsOutsideFolder
          if !elsewhere.isEmpty {
            DisclosureGroup(isExpanded: $showsElsewhere) {
              VStack(alignment: .leading, spacing: 2) {
                ForEach(elsewhere) { group in
                  groupRow(group, relativeTo: nil)
                }
              }
              .padding(.top, 4)
            } label: {
              Text("Also touched (\(elsewhere.count))")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(14)
      }
    }
    .frame(width: 460)
    .frame(minHeight: 200, maxHeight: 560)
    .accessibilityIdentifier("ai-chat-thread-outputs-panel")
  }

  @ViewBuilder
  private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title.uppercased())
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
      content()
    }
  }

  private func groupRow(_ group: AIChatThreadOutputGroup, relativeTo folder: String?) -> some View {
    let primary = group.primary
    return HStack(alignment: .firstTextBaseline, spacing: 8) {
      Image(systemName: primary.wasCreated ? "plus.circle" : (group.editCount > 0 ? "pencil" : "link"))
        .font(.caption)
        .foregroundStyle(primary.wasCreated ? Color.green : Color.secondary)
        .frame(width: 14)
      VStack(alignment: .leading, spacing: 2) {
        Button {
          open(primary.path)
        } label: {
          Text(rowTitle(group, relativeTo: folder))
            .font(.callout.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(group.exists ? .primary : .secondary)
            .strikethrough(!group.exists)
        }
        .buttonStyle(.plain)
        .help(outputs.displayPath(primary.path))

        HStack(spacing: 6) {
          Text(activityText(group))
          if !group.staleFormats.isEmpty {
            Label("\(group.staleFormats.joined(separator: ", ")) stale", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
              .help("The source changed after this format was last built")
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer(minLength: 6)
      HStack(spacing: 3) {
        ForEach(group.files) { file in
          Button(file.fileExtension.isEmpty ? "file" : file.fileExtension) {
            open(file.path)
          }
          .buttonStyle(.bordered)
          .controlSize(.mini)
          .foregroundStyle(group.staleFormats.contains(file.fileExtension.uppercased()) ? Color.orange : Color.primary)
          .disabled(!file.exists)
          .help(file.isSibling ? "Published alongside \(primary.fileName)" : outputs.displayPath(file.path))
        }
      }
      if let messageID = group.lastMessageID {
        Button {
          onJumpToMessage(messageID)
        } label: {
          Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help("Jump to the last reply that touched this file")
      }
    }
    .padding(.vertical, 3)
    .contextMenu {
      Button("Open") { open(primary.path) }
      Button("Reveal in Finder") { store.revealFile(path: primary.path) }
      Button("Copy Path") { store.copyFileReference(path: primary.path) }
    }
  }

  private func rowTitle(_ group: AIChatThreadOutputGroup, relativeTo folder: String?) -> String {
    outputs.rowTitle(group, relativeTo: folder)
  }

  private func activityText(_ group: AIChatThreadOutputGroup) -> String {
    group.activitySummary
  }

  private func open(_ path: String) {
    store.openChatFileReference(AIChatFileReference(path: path, line: nil))
    onOpen()
  }
}

/// The working folder with a lazily loaded, browsable tree. Files the thread
/// touched are emphasized; everything else is still one click away.
private struct AIChatOutputsFolderRow: View {
  @Environment(WorkspaceStore.self) private var store
  let path: String
  let displayPath: String
  let touchedPaths: Set<String>
  let onOpen: () -> Void
  /// Collapsed so the outputs list stays in view; one click browses the folder.
  @State private var isExpanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        Button {
          isExpanded.toggle()
        } label: {
          HStack(spacing: 6) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
              .font(.caption2.weight(.semibold))
              .frame(width: 10)
            Image(systemName: "folder.fill").foregroundStyle(.tint)
            Text(displayPath)
              .font(.callout.monospaced().weight(.medium))
              .lineLimit(1)
              .truncationMode(.head)
          }
        }
        .buttonStyle(.plain)
        Spacer(minLength: 6)
        Button {
          store.revealFile(path: path)
        } label: {
          Image(systemName: "arrow.up.forward.app")
        }
        .buttonStyle(.borderless)
        .help("Reveal in Finder")
      }
      if isExpanded {
        AIChatOutputsFolderChildren(path: path, depth: 1, touchedPaths: touchedPaths, onOpen: onOpen)
      }
    }
    .contextMenu {
      Button("Reveal in Finder") { store.revealFile(path: path) }
      Button("Copy Path") { store.copyFileReference(path: path) }
    }
  }
}

private struct AIChatOutputsFolderChildren: View {
  let path: String
  let depth: Int
  let touchedPaths: Set<String>
  let onOpen: () -> Void
  @State private var entries: [AIChatOutputsFolderEntry]?

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      if let entries {
        if entries.isEmpty {
          Text("Empty folder")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, CGFloat(depth) * 14 + 16)
        }
        ForEach(entries) { entry in
          AIChatOutputsFolderEntryRow(entry: entry, depth: depth, touchedPaths: touchedPaths, onOpen: onOpen)
        }
      }
    }
    .task(id: path) {
      let path = path
      entries = await Task.detached(priority: .userInitiated) {
        AIChatOutputsFolderEntry.list(path)
      }.value
    }
  }
}

private struct AIChatOutputsFolderEntryRow: View {
  @Environment(WorkspaceStore.self) private var store
  let entry: AIChatOutputsFolderEntry
  let depth: Int
  let touchedPaths: Set<String>
  let onOpen: () -> Void
  @State private var isExpanded = false

  var body: some View {
    let touchedCount = entry.isDirectory
      ? touchedPaths.filter { $0.hasPrefix(entry.path + "/") }.count
      : (touchedPaths.contains(entry.path) ? 1 : 0)
    VStack(alignment: .leading, spacing: 1) {
      Button {
        if entry.isDirectory {
          isExpanded.toggle()
        } else {
          store.openChatFileReference(AIChatFileReference(path: entry.path, line: nil))
          onOpen()
        }
      } label: {
        HStack(spacing: 6) {
          Group {
            if entry.isDirectory {
              Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
            } else {
              Color.clear
            }
          }
          .frame(width: 10, height: 10)
          Image(systemName: entry.isDirectory ? "folder" : "doc")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(entry.name)
            .font(.callout)
            .fontWeight(touchedCount > 0 ? .semibold : .regular)
            .foregroundStyle(touchedCount > 0 ? .primary : .secondary)
            .lineLimit(1)
            .truncationMode(.middle)
          if entry.isDirectory, touchedCount > 0 {
            Text("●\(touchedCount)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.tint)
          } else if touchedCount > 0 {
            Circle().fill(.tint).frame(width: 5, height: 5)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.leading, CGFloat(depth) * 14)
      .padding(.vertical, 1)
      .contextMenu {
        Button("Reveal in Finder") { store.revealFile(path: entry.path) }
        Button("Copy Path") { store.copyFileReference(path: entry.path) }
      }

      if entry.isDirectory, isExpanded {
        AIChatOutputsFolderChildren(path: entry.path, depth: depth + 1, touchedPaths: touchedPaths, onOpen: onOpen)
      }
    }
  }
}

struct AIChatOutputsFolderEntry: Identifiable, Hashable, Sendable {
  let path: String
  let name: String
  let isDirectory: Bool
  var id: String { path }

  /// Folders first, then files; hidden files and editor backups are skipped.
  nonisolated static func list(_ directory: String, fileManager: FileManager = .default) -> [AIChatOutputsFolderEntry] {
    let url = URL(fileURLWithPath: directory)
    guard let urls = try? fileManager.contentsOfDirectory(
      at: url,
      includingPropertiesForKeys: [.isDirectoryKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }
    return urls.compactMap { url -> AIChatOutputsFolderEntry? in
      let name = url.lastPathComponent
      guard !name.hasSuffix("~") else { return nil }
      let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      return AIChatOutputsFolderEntry(path: url.standardizedFileURL.path, name: name, isDirectory: isDirectory)
    }
    .sorted { lhs, rhs in
      if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
      return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
  }
}
