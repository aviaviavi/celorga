import Foundation
import SwiftUI
import WebKit

// MARK: - Models

/// One optional workspace app from `celorga apps list`.
public struct WorkspaceAppInfo: Decodable, Identifiable, Equatable, Sendable {
  public struct Surface: Decodable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
  }
  public struct Suggestion: Decodable, Equatable, Sendable {
    public let reason: String
  }
  public let id: String
  public let title: String
  public let description: String
  public let symbol: String
  public let source: String
  public let pluginId: String?
  public let trusted: Bool?
  public let defaultEnabled: Bool
  public let enabled: Bool
  public let surfaces: [Surface]
  public let suggestion: Suggestion?

  public var isPlugin: Bool { source == "plugin" }
}

struct WorkspaceAppListPayload: Decodable {
  let apps: [WorkspaceAppInfo]
}

/// A page contributed by an enabled plugin app.
public struct WorkspacePluginSurfaceRef: Identifiable, Hashable, Sendable {
  public let pluginId: String
  public let surfaceId: String
  public let title: String
  public let symbol: String
  public let appTitle: String
  public var id: String { "\(pluginId):\(surfaceId)" }
}

struct WorkspacePluginSurfaceRender: Decodable, Sendable {
  let title: String
  let html: String
  let css: String?
  let script: String?
}

/// Per-corpus record of app suggestions a person dismissed on this Mac.
enum WorkspaceAppSuggestionDismissals {
  static let defaultsKey = "Org2Workspace.appSuggestionsDismissed.v1"

  static func key(root: String, appID: String) -> String { "\(root)|\(appID)" }

  static func isDismissed(root: String, appID: String, defaults: UserDefaults = .standard) -> Bool {
    (defaults.stringArray(forKey: defaultsKey) ?? []).contains(key(root: root, appID: appID))
  }

  static func dismiss(root: String, appID: String, defaults: UserDefaults = .standard) {
    var values = defaults.stringArray(forKey: defaultsKey) ?? []
    let entry = key(root: root, appID: appID)
    guard !values.contains(entry) else { return }
    values.append(entry)
    defaults.set(Array(values.suffix(200)), forKey: defaultsKey)
  }
}

// MARK: - Store

extension WorkspaceStore {
  /// IDs of the apps turned on for the active corpus.
  public var enabledWorkspaceAppIDs: Set<String> {
    Set(workspaceApps.filter(\.enabled).map(\.id))
  }

  public func isWorkspaceAppEnabled(_ id: String) -> Bool {
    workspaceApps.contains { $0.id == id && $0.enabled }
  }

  /// Pages from enabled plugin apps, in app order.
  public var enabledPluginSurfaces: [WorkspacePluginSurfaceRef] {
    workspaceApps.filter { $0.isPlugin && $0.enabled }.flatMap { app in
      app.surfaces.map { surface in
        WorkspacePluginSurfaceRef(
          pluginId: app.pluginId ?? String(app.id.dropFirst("plugin:".count)),
          surfaceId: surface.id,
          title: surface.title,
          symbol: surface.symbol,
          appTitle: app.title
        )
      }
    }
  }

  /// The first app with an undismissed data-based suggestion, if any.
  public var suggestedWorkspaceApp: WorkspaceAppInfo? {
    guard let root = corpusRoot?.standardizedFileURL.path else { return nil }
    return workspaceApps.first { app in
      !app.enabled && app.suggestion != nil
        && !WorkspaceAppSuggestionDismissals.isDismissed(root: root, appID: app.id)
    }
  }

  public func dismissWorkspaceAppSuggestion(_ app: WorkspaceAppInfo) {
    guard let root = corpusRoot?.standardizedFileURL.path else { return }
    WorkspaceAppSuggestionDismissals.dismiss(root: root, appID: app.id)
    // Re-publish so views drop the dismissed suggestion.
    workspaceApps = workspaceApps
  }

  /// Loads apps once per corpus. The sidebar calls this when it shows a
  /// corpus, so headless opens and tests do not pay for an extra CLI call.
  public func loadWorkspaceAppsIfNeeded() async {
    guard let root = corpusRoot?.standardizedFileURL.path, workspaceAppsRootPath != root else { return }
    await refreshWorkspaceApps()
  }

  public func refreshWorkspaceApps() async {
    guard let corpusRoot else {
      workspaceApps = []
      workspaceAppsRootPath = nil
      return
    }
    let root = corpusRoot.standardizedFileURL.path
    do {
      let payload: WorkspaceAppListPayload = try await cli.runJSON(["apps", "list", "--dir", root])
      guard self.corpusRoot?.standardizedFileURL.path == root else { return }
      workspaceApps = payload.apps
      workspaceAppsRootPath = root
      workspaceAppsError = nil
    } catch {
      guard self.corpusRoot?.standardizedFileURL.path == root else { return }
      workspaceAppsError = error.localizedDescription
      return
    }
    // Load People & Companies ahead of time so opening it is instant.
    if isWorkspaceAppEnabled("crm"), crm.index == nil, !crm.isLoading {
      let cli = self.cli
      Task { @MainActor [weak self] in await self?.crm.load(cli: cli, root: root) }
    }
    if !isWorkspaceAppEnabled("crm"), searchFilter == .people { searchFilter = .all }
    // Leave a surface whose app was turned off (possibly on another Mac).
    if let appID = selectedSurface.workspaceAppID, !isWorkspaceAppEnabled(appID) {
      makeSurfacePrimary(.home)
    } else if selectedSurface == .pluginApp,
              selectedPluginSurface.map({ enabledPluginSurfaces.contains($0) }) != true {
      selectedPluginSurface = nil
      makeSurfacePrimary(.home)
    }
  }

  /// Turns an app on or off in the corpus's celorga.json.
  @discardableResult
  public func setWorkspaceApp(_ id: String, enabled: Bool) async -> Bool {
    guard let corpusRoot else { return false }
    do {
      _ = try await cli.run(["apps", enabled ? "enable" : "disable", id, "--dir", corpusRoot.path, "--apply"])
      workspaceAppsError = nil
      await refreshWorkspaceApps()
      statusText = enabled ? "Turned on \(workspaceApps.first { $0.id == id }?.title ?? id)" : "Turned off \(workspaceApps.first { $0.id == id }?.title ?? id)"
      return true
    } catch {
      workspaceAppsError = error.localizedDescription
      return false
    }
  }

  public func openPluginSurface(_ surface: WorkspacePluginSurfaceRef) {
    selectedPluginSurface = surface
    makeSurfacePrimary(.pluginApp)
  }

  func renderPluginSurface(_ surface: WorkspacePluginSurfaceRef) async throws -> WorkspacePluginSurfaceRender {
    guard let corpusRoot else { throw CocoaError(.fileNoSuchFile) }
    return try await cli.runJSON(["apps", "render", surface.id, "--dir", corpusRoot.path])
  }
}

// MARK: - Sidebar

/// The bottom of the Workspace section: a data-based app suggestion and an
/// entry point to the Apps settings, so optional apps stay discoverable.
struct WorkspaceAppsSidebarFooter: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.openSettings) private var openSettings
  @AppStorage(WorkspaceSettingsNavigation.selectionKey) private var settingsSelection = WorkspaceSettingsNavigation.workspace
  @State private var isEnabling = false

  var body: some View {
    if let app = store.suggestedWorkspaceApp {
      VStack(alignment: .leading, spacing: 6) {
        Label("Try \(app.title)", systemImage: app.symbol)
          .font(.callout.weight(.semibold))
        if let reason = app.suggestion?.reason {
          Text(reason)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 8) {
          Button(isEnabling ? "Turning On…" : "Turn On") {
            isEnabling = true
            Task {
              await store.setWorkspaceApp(app.id, enabled: true)
              isEnabling = false
            }
          }
          .controlSize(.small)
          .buttonStyle(.borderedProminent)
          .disabled(isEnabling)
          Button("Not Now") { store.dismissWorkspaceAppSuggestion(app) }
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
      }
      .padding(10)
      .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
      .listRowBackground(Color.clear)
      .accessibilityIdentifier("sidebar-app-suggestion-\(app.id)")
    }
    Button {
      settingsSelection = WorkspaceSettingsNavigation.apps
      openSettings()
    } label: {
      Label("Apps…", systemImage: "square.grid.2x2")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.vertical, 3)
    .listRowBackground(Color.clear)
    .help("Turn optional apps such as People & Companies on or off")
    .accessibilityIdentifier("sidebar-apps-settings")
  }
}

// MARK: - Settings

/// Settings › Apps: every optional app for the active corpus, with a toggle.
public struct WorkspaceAppsSettingsView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var pending: Set<String> = []

  public init() {}

  public var body: some View {
    Form {
      if store.corpusRoot == nil {
        ContentUnavailableView(
          "No Workspace Open",
          systemImage: "folder.badge.questionmark",
          description: Text("Open a corpus to choose its apps.")
        )
      } else {
        Section {
          if store.workspaceApps.isEmpty {
            HStack(spacing: 8) {
              ProgressView().controlSize(.small)
              Text("Loading apps…").foregroundStyle(.secondary)
            }
          }
          ForEach(store.workspaceApps.filter { !$0.isPlugin }) { app in appRow(app) }
        } header: {
          Label("Built-in Apps", systemImage: "square.grid.2x2")
        } footer: {
          SettingsFooterText("Optional apps add pages to the sidebar. They read the notes already in your corpus and change nothing until you turn them on. This choice is saved in the corpus's celorga.json, so it follows the corpus to every Mac.")
        }
        Section {
          let plugins = store.workspaceApps.filter(\.isPlugin)
          if plugins.isEmpty {
            Text("No installed plugin adds an app yet.")
              .foregroundStyle(.secondary)
          }
          ForEach(plugins) { app in appRow(app) }
        } header: {
          Label("Plugin Apps", systemImage: "puzzlepiece.extension")
        } footer: {
          SettingsFooterText("Plugins can contribute app pages with contributes.surfaces in their manifest. Install them with celorga plugin add, then trust the exact version with celorga plugin trust. Plugin pages run in a sandbox without network or corpus write access.")
        }
        if let error = store.workspaceAppsError {
          Section {
            Text(error)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }
      }
    }
    .formStyle(.grouped)
    .padding(8)
    .frame(width: 620)
    .frame(minHeight: 460)
    .task(id: store.corpusRoot?.path) { await store.refreshWorkspaceApps() }
  }

  private func appRow(_ app: WorkspaceAppInfo) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: app.symbol)
        .font(.title2)
        .foregroundStyle(Color.accentColor)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 3) {
        HStack(spacing: 6) {
          Text(app.title).font(.headline)
          if app.isPlugin, app.trusted == false {
            Text("Not trusted")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.orange)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(Color.orange.opacity(0.12), in: Capsule())
          }
        }
        Text(app.description)
          .font(.callout)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Text("Adds: " + app.surfaces.map(\.title).joined(separator: ", "))
          .font(.caption)
          .foregroundStyle(.tertiary)
        if let reason = app.suggestion?.reason, !app.enabled {
          Label(reason, systemImage: "lightbulb")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 8)
      if pending.contains(app.id) {
        ProgressView().controlSize(.small)
      }
      Toggle("", isOn: Binding(
        get: { app.enabled },
        set: { value in
          pending.insert(app.id)
          Task {
            await store.setWorkspaceApp(app.id, enabled: value)
            pending.remove(app.id)
          }
        }
      ))
      .labelsHidden()
      .toggleStyle(.switch)
      .disabled(pending.contains(app.id))
      .accessibilityIdentifier("app-toggle-\(app.id)")
    }
    .padding(.vertical, 4)
  }
}

// MARK: - Plugin app pages

/// Shows the selected plugin app page as a sandboxed, network-free web page.
struct PluginAppSurfaceView: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var render: WorkspacePluginSurfaceRender?
  @State private var error: String?
  @State private var isLoading = false

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 10) {
        Label(render?.title ?? store.selectedPluginSurface?.title ?? "App", systemImage: store.selectedPluginSurface?.symbol ?? "puzzlepiece.extension")
          .font(.title2.weight(.semibold))
        if let surface = store.selectedPluginSurface {
          Text("from \(surface.appTitle)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if isLoading { ProgressView().controlSize(.small) }
        Button { Task { await load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
          .labelStyle(.iconOnly)
          .disabled(isLoading || store.selectedPluginSurface == nil)
          .help("Render this page again")
      }
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
      Divider()
      if let error {
        ContentUnavailableView {
          Label("This app page could not load", systemImage: "exclamationmark.triangle")
        } description: {
          Text(error).textSelection(.enabled)
        }
      } else if let render {
        PluginSurfaceWebView(document: PluginSurfaceDocument.html(for: render))
      } else if store.selectedPluginSurface == nil {
        ContentUnavailableView("Choose an app page in the sidebar", systemImage: "puzzlepiece.extension")
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .task(id: store.selectedPluginSurface?.id) { await load() }
  }

  private func load() async {
    guard let surface = store.selectedPluginSurface else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let result = try await store.renderPluginSurface(surface)
      guard store.selectedPluginSurface == surface else { return }
      render = result
      error = nil
    } catch {
      guard store.selectedPluginSurface == surface else { return }
      self.error = error.localizedDescription
      render = nil
    }
  }
}

enum PluginSurfaceDocument {
  /// No network, no frames, no forms; inline script and style only.
  static let contentSecurityPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src data: blob:; base-uri 'none'; form-action 'none'; frame-src 'none'; object-src 'none'"

  static func html(for render: WorkspacePluginSurfaceRender) -> String {
    let escape: (String) -> String = { value in
      value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
    // Keep a plugin's markup from closing our style or script elements early.
    let css = (render.css ?? "").replacingOccurrences(of: "</", with: "<\\/")
    let script = (render.script ?? "").replacingOccurrences(of: "</", with: "<\\/")
    return """
    <!doctype html>
    <html><head><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
    <meta name="color-scheme" content="light dark">
    <title>\(escape(render.title))</title>
    <style>:root{color-scheme:light dark;font:13px -apple-system,BlinkMacSystemFont,sans-serif}body{margin:16px}\(css)</style>
    </head><body>\(render.html)\(script.isEmpty ? "" : "<script>\(script)</script>")</body></html>
    """
  }
}

struct PluginSurfaceWebView: NSViewRepresentable {
  let document: String

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = true
    let view = WKWebView(frame: .zero, configuration: configuration)
    view.navigationDelegate = context.coordinator
    view.setValue(false, forKey: "drawsBackground")
    view.loadHTMLString(document, baseURL: nil)
    context.coordinator.loaded = document
    return view
  }

  func updateNSView(_ view: WKWebView, context: Context) {
    guard context.coordinator.loaded != document else { return }
    context.coordinator.loaded = document
    view.loadHTMLString(document, baseURL: nil)
  }

  final class Coordinator: NSObject, WKNavigationDelegate {
    var loaded = ""

    func webView(
      _ webView: WKWebView,
      decidePolicyFor navigationAction: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      // Only the page itself may load; links and form posts go nowhere.
      let url = navigationAction.request.url
      decisionHandler(url == nil || url?.absoluteString == "about:blank" ? .allow : .cancel)
    }
  }
}
