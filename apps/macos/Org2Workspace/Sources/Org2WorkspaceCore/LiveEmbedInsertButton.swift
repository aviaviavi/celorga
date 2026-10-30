import SwiftUI

struct LiveEmbedResolution: Decodable, Sendable {
  let ok: Bool
  let directive: String?
  let file: String?
  let line: Int?
  let title: String?
  let message: String?
}

enum LiveEmbedPresentation {
  static func fileTarget(file: String, sourceFile: String) -> String {
    let source = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().standardizedFileURL.pathComponents
    let target = URL(fileURLWithPath: file).standardizedFileURL.pathComponents
    var common = 0
    while common < min(source.count, target.count), source[common] == target[common] { common += 1 }
    return "file:" + (Array(repeating: "..", count: source.count - common) + target.dropFirst(common)).joined(separator: "/")
  }

  static func containsEmbeds(_ html: String?) -> Bool {
    // Corpus file events check every cached rendered page; a byte scan keeps
    // that cheap on the main actor.
    html?.containsUTF8Bytes("data-org2-live-embed=\"true\"") == true
  }
}

struct LiveEmbedInsertButton: View {
  @Environment(WorkspaceStore.self) private var store

  var body: some View {
    Button { store.isLiveEmbedInsertPresented = true } label: {
      Label("Live Embed…", systemImage: "doc.on.doc")
    }
    .disabled(store.selectedEntrySource == nil || store.selectedFileIsCSV || store.selectedFileIsNativePreview)
  }
}

struct LiveEmbedInsertSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var target = ""
  @State private var search = ""
  @State private var error: String?
  @State private var isResolving = false
  @State private var resolutionTask: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Insert Live Embed").font(.title2.bold())
      Text("Choose a note or enter a stable note or heading ID. The source stays in its own file. Save the inserted directive to keep the reference.")
        .foregroundStyle(.secondary)
      TextField("Search notes", text: $search)
        .disabled(isResolving)
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(store.corpusFiles.filter {
            ["org", "org2"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) &&
              (search.isEmpty || $0.relativePath.localizedCaseInsensitiveContains(search))
          }.prefix(100)) { file in
            Button {
              guard let source = store.selectedEntrySource else { return }
              target = LiveEmbedPresentation.fileTarget(file: file.path, sourceFile: source.file)
            } label: {
              Label(file.relativePath, systemImage: "doc.text").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 3)
          }
        }
      }
      .frame(height: 180)
      .disabled(isResolving)
      TextField("file:notes/example.org or id:stable-heading-id", text: $target)
        .textFieldStyle(.roundedBorder)
        .accessibilityLabel("Embed target")
        .disabled(isResolving)
      if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      HStack {
        Spacer()
        Button("Cancel") {
          resolutionTask?.cancel()
          dismiss()
        }.keyboardShortcut(.cancelAction)
        Button(isResolving ? "Resolving…" : "Insert Embed") {
          guard let source = store.selectedEntrySource else { return }
          let submittedTarget = target
          let submittedRoot = store.corpusRoot?.standardizedFileURL.path
          isResolving = true
          error = nil
          resolutionTask = Task { @MainActor in
            defer {
              isResolving = false
              resolutionTask = nil
            }
            guard !Task.isCancelled, store.isLiveEmbedInsertPresented else { return }
            do {
              var arguments = ["embed", "resolve", "--target", submittedTarget, "--file", source.file, "--json"]
              if let submittedRoot { arguments += ["--dir", submittedRoot] }
              let result: LiveEmbedResolution = try await store.cli.runJSON(arguments)
              guard !Task.isCancelled, store.isLiveEmbedInsertPresented else { return }
              guard result.ok, let directive = result.directive else {
                error = result.message ?? "The embed target could not be resolved."
                return
              }
              guard store.selectedEntrySource?.id == source.id,
                    store.corpusRoot?.standardizedFileURL.path == submittedRoot else {
                error = "The selected document changed. Choose the destination again."
                return
              }
              store.insertLiveEmbedDirective(directive)
              dismiss()
            } catch {
              guard !Task.isCancelled, store.isLiveEmbedInsertPresented else { return }
              self.error = error.localizedDescription
            }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isResolving)
      }
    }
    .padding(24)
    .frame(width: 540)
    .interactiveDismissDisabled(isResolving)
    .onDisappear { resolutionTask?.cancel() }
  }
}
