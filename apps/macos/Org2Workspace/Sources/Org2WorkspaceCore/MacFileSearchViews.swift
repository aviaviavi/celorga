import AppKit
import SwiftUI

/// One Search › This Mac result: the file's icon, name, folder, size, age,
/// and how many older copies it has.
struct MacFileSearchRow: View {
  let result: MacFileSearchResult
  let query: String
  let isSelected: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(nsImage: MacFileSearchDisplay.icon(for: result))
        .resizable()
        .interpolation(.high)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .center, spacing: 6) {
          Text(highlighted(result.name))
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
          Spacer(minLength: 4)
          if result.copyCount > 0 {
            Text(MacFileSearchDisplay.copiesLabel(result.copyCount))
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 6)
              .padding(.vertical, 1)
              .background(WorkspaceDesign.subtleFill, in: Capsule())
              .help(copiesHelp)
          }
        }
        .frame(minHeight: 24)

        Text(MacFileSearchDisplay.metadata(result))
          .font(.caption)
          .foregroundStyle(.tertiary)
          .lineLimit(1)
          .truncationMode(.head)
      }
    }
    .padding(.vertical, 7)
    .workspaceSelectableRow(
      isSelected: isSelected,
      showsSelectionMarker: false,
      leadingPadding: 8,
      trailingPadding: 10
    )
  }

  private var copiesHelp: String {
    let lines = result.copies.prefix(8).map { copy in
      "\(MacFileSearchDisplay.abbreviated(copy.path)) · \(MacFileSearchDisplay.relativeDate(copy.modifiedAt))"
    }
    let more = result.copyCount > lines.count ? ["…and \(result.copyCount - lines.count) more"] : []
    return (["Newest shown. Older copies:"] + lines + more).joined(separator: "\n")
  }

  private func highlighted(_ text: String) -> AttributedString {
    var attributed = AttributedString(text)
    for range in WorkspaceSearchHighlight.ranges(in: text, query: query) {
      guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed)
      else { continue }
      attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
    }
    return attributed
  }
}

struct MacFileSearchContextMenu: View {
  @Environment(WorkspaceStore.self) private var store
  let result: MacFileSearchResult

  var body: some View {
    Button {
      store.openMacFileSearchResult(result)
    } label: {
      Label("Open", systemImage: result.isFolder ? "folder" : "arrow.up.forward.app")
    }

    Button {
      store.revealMacFileInFinder(result.path)
    } label: {
      Label("Show in Finder", systemImage: "folder")
    }

    Divider()

    Button {
      copy(result.path)
    } label: {
      Label("Copy Path", systemImage: "doc.on.doc")
    }

    Button {
      copy(MacFileSearchDisplay.orgLink(result.path, name: result.name))
    } label: {
      Label("Copy Org Link", systemImage: "link")
    }

    if !result.copies.isEmpty {
      Divider()
      Menu("Older Copies (\(result.copyCount))") {
        ForEach(result.copies) { copy in
          Button(copyTitle(copy)) {
            store.revealMacFileInFinder(copy.path)
          }
        }
      }
    }
  }

  private func copyTitle(_ copy: MacFileSearchCopy) -> String {
    var title = "\(MacFileSearchDisplay.abbreviated(copy.path)) · \(MacFileSearchDisplay.relativeDate(copy.modifiedAt))"
    if copy.identical == true { title += " · identical" }
    return title
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
}

/// Which folders Search › This Mac covers, with add, remove, and rebuild.
struct MacFileSearchFoldersMenu: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    Menu {
      if let config = store.macFileSearchConfig {
        Section("Searched Folders") {
          ForEach(config.roots, id: \.self) { root in
            Menu(root) {
              Button("Show in Finder") {
                store.revealMacFileInFinder(NSString(string: root).expandingTildeInPath)
              }
              Button("Stop Searching This Folder", role: .destructive) {
                Task { await store.updateMacFileSearchConfig(["--remove-root", root]) }
              }
            }
          }
        }
        if !config.exclude.isEmpty {
          Section("Skipped") {
            ForEach(config.exclude, id: \.self) { entry in
              Button("Search \(entry) Again") {
                Task { await store.updateMacFileSearchConfig(["--include", entry]) }
              }
            }
          }
        }
      } else {
        Text("Loading folders…")
      }
      Divider()
      Button("Add Folder…") {
        store.addMacFileSearchFolder()
      }
      Button("Use Default Folders") {
        Task { await store.updateMacFileSearchConfig(["--reset"]) }
      }
      Divider()
      Button("Rebuild Index") {
        store.rebuildMacFileSearchIndex()
      }
    } label: {
      Label("Folders", systemImage: "folder.badge.gearshape")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .help("Choose which folders Search › This Mac covers")
    .task {
      if store.macFileSearchConfig == nil {
        await store.loadMacFileSearchConfig()
      }
    }
  }
}
