import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DocumentPublishSheet: View {
  @Environment(WorkspaceStore.self) private var store
  @Environment(\.dismiss) private var dismiss

  @State private var destination: DocumentPublishDestination = .localLink
  @State private var host: ChatThreadShareLocation?
  @State private var format: DocumentPublishFormat = .html
  @State private var scope: DocumentPublishScope = .document
  @State private var googleFolderID = ""
  @State private var googleOAuthClientID = ""
  @State private var googleOAuthClientSecret = ""
  @State private var showCustomGoogleOAuthClient = false
  @State private var googleAccounts: [GoogleDriveOAuthCredential] = []
  @State private var selectedGoogleAccountID: String?
  @State private var preview: DocumentPublishCLIResult?
  @State private var previewedRequest: DocumentPublishRequest?
  @State private var outcome: DocumentPublishOutcome?
  @State private var isWorking = false
  @State private var errorText: String?
  @State private var restoredLinkedSlides = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 16)

      Divider()

      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          if let outcome {
            outcomeView(outcome)
          } else {
            configuration
          }

          if let errorText {
            Label(errorText, systemImage: "exclamationmark.triangle.fill")
              .font(.callout)
              .foregroundStyle(.red)
              .textSelection(.enabled)
          }
        }
        .padding(24)
      }

      Divider()
      footer
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }
    .frame(
      minWidth: 620,
      idealWidth: 620,
      maxWidth: 620,
      minHeight: 540,
      idealHeight: 650,
      maxHeight: 760
    )
    .task {
      restoreGoogleCredential()
      restoreLinkedGoogleDestination()
      selectPreferredGoogleAccount()
      await previewPublication()
      await identifyUnlabeledGoogleAccounts()
      await store.openOrgServer.refreshDocumentPublications()
    }
    .onChange(of: destination) { _, newDestination in
      if !newDestination.formats(showingSlides: showsSlideFormats).contains(format) {
        format = newDestination.defaultFormat
      }
      invalidatePreview()
    }
    .onChange(of: format) { _, _ in invalidatePreview() }
    .onChange(of: host) { _, _ in invalidatePreview() }
    .onChange(of: scope) { _, _ in invalidatePreview() }
    .onChange(of: googleFolderID) { _, _ in invalidatePreview() }
    .onChange(of: existingGooglePublication?.fileID) { _, fileID in
      if let fileID,
         let linked = GoogleDriveAccountPreferences.accountID(forFileID: fileID),
         googleAccounts.contains(where: { $0.accountID == linked }) {
        selectedGoogleAccountID = linked
      }
    }
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: "square.and.arrow.up")
        .font(.system(size: 28, weight: .medium))
        .foregroundStyle(Color.accentColor)
        .frame(width: 36)
      VStack(alignment: .leading, spacing: 4) {
        Text("Publish Document")
          .font(.title2.weight(.semibold))
        Text(store.currentDocumentPublishDisplayName)
          .font(.callout)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
    }
  }

  private var configuration: some View {
    VStack(alignment: .leading, spacing: 20) {
      LabeledContent("Destination") {
        Picker("Destination", selection: $destination) {
          ForEach(DocumentPublishDestination.allCases) { destination in
            Text(destination.title).tag(destination)
          }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 300)
      }

      LabeledContent("Content") {
        Picker("Content", selection: $scope) {
          Text(DocumentPublishScope.document.title).tag(DocumentPublishScope.document)
          if store.currentDocumentPublishSubtreeLine != nil {
            Text(DocumentPublishScope.subtree.title).tag(DocumentPublishScope.subtree)
          }
        }
        .labelsHidden()
        .pickerStyle(.radioGroup)
        .frame(width: 300, alignment: .leading)
      }

      LabeledContent("Format") {
        Picker("Format", selection: $format) {
          ForEach(destination.formats(showingSlides: showsSlideFormats)) { availableFormat in
            Label(availableFormat.title, systemImage: availableFormat.systemImage)
              .tag(availableFormat)
          }
        }
        .labelsHidden()
        .pickerStyle(.radioGroup)
        .frame(width: 300, alignment: .leading)
      }

      destinationConfiguration

      disclosurePreview

    }
  }

  @ViewBuilder
  private var destinationConfiguration: some View {
    switch destination {
    case .localLink:
      VStack(alignment: .leading, spacing: 8) {
        Picker("Host", selection: Binding(
          get: { selectedHost }, set: { host = $0 }
        )) {
          Text("This Mac").tag(ChatThreadShareLocation.thisMac)
          Text(store.openOrgServer.isPaired ? store.openOrgServer.serverName : "Celorga Server")
            .tag(ChatThreadShareLocation.server)
            .selectionDisabled(!store.openOrgServer.isPaired)
        }
        Label("Secret local-network link · \(format.title)", systemImage: "network")
          .font(.headline)
        Text(localFormatDescription)
          .font(.callout)
          .foregroundStyle(.secondary)
        Text("Celorga serves the sealed output from \(selectedHostName). Anyone on a network that can reach that host and receives the unguessable link can open it.")
          .font(.callout)
          .foregroundStyle(.secondary)
        Label("Celorga must be running for links to be reachable. Active links resume automatically after relaunch. The first version uses unencrypted HTTP, so use it only on a trusted local or private network.", systemImage: "lock.open.trianglebadge.exclamationmark")
          .font(.caption)
          .foregroundStyle(.orange)
        SettingsLink {
          Label("Manage Active Local Links…", systemImage: "gearshape")
        }
        .controlSize(.small)

        if !hostedPublications.isEmpty {
          Divider()
          Text("Hosted now")
            .font(.subheadline.weight(.semibold))
          ForEach(hostedPublications) { publication in
            HStack(spacing: 8) {
              VStack(alignment: .leading, spacing: 2) {
                Text(publication.title)
                  .font(.caption.weight(.medium))
                  .lineLimit(1)
                Text(publication.url.absoluteString)
                  .font(.caption2.monospaced())
                  .foregroundStyle(.secondary)
                  .lineLimit(1)
              }
              Spacer()
              Button {
                NSWorkspace.shared.open(publication.openURL)
              } label: {
                Image(systemName: "arrow.up.right.square")
              }
              .buttonStyle(.borderless)
              .help("Open shareable link")
              Button {
                copy(publication.url.absoluteString)
              } label: {
                Image(systemName: "doc.on.doc")
              }
              .buttonStyle(.borderless)
              .help("Copy link")
              Button(role: .destructive) {
                if selectedHost == .server {
                  Task {
                    do { try await store.revokeServerDocumentPublication(publication.id) }
                    catch { errorText = error.localizedDescription }
                  }
                } else {
                  store.revokeLocalDocumentPublication(publication.id)
                }
              } label: {
                Image(systemName: "stop.circle")
              }
              .buttonStyle(.borderless)
              .help("Stop hosting")
            }
          }
        }
      }
      .padding(14)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

    case .googleDrive:
      VStack(alignment: .leading, spacing: 12) {
        Label("Google Drive · \(format.title)", systemImage: format.systemImage)
          .font(.headline)

        Text(googleFormatDescription)
          .font(.callout)
          .foregroundStyle(.secondary)

        if let linkedPublication = existingGooglePublication {
          VStack(alignment: .leading, spacing: 8) {
            Label("Linked \(linkedPublication.format.title)", systemImage: "link.circle.fill")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.green)
            Text("Publishing again replaces this same Google Drive file after checking its type, edit access, comments, and current ETag. Its link and latest observed Drive version are saved in the \(linkedPublication.scopeLabel.lowercased()) properties.")
              .font(.caption)
              .foregroundStyle(.secondary)
            HStack {
              Button("Open Linked Artifact") {
                NSWorkspace.shared.open(linkedPublication.url)
              }
              Button("Copy Link") {
                copy(linkedPublication.url.absoluteString)
              }
            }
          }
          .padding(10)
          .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        } else {
          TextField("Destination folder ID (optional)", text: $googleFolderID)
            .textFieldStyle(.roundedBorder)
        }

        if let googleCredential {
          LabeledContent("Account") {
            Picker("Account", selection: $selectedGoogleAccountID) {
              ForEach(googleAccounts, id: \.accountID) { account in
                Text(account.accountLabel).tag(Optional(account.accountID))
              }
            }
            .labelsHidden()
            .frame(width: 340, alignment: .leading)
          }
          HStack(spacing: 8) {
            Button("Add Another Google Account…") {
              Task { await connectGoogleDrive(usingCustomClient: !GoogleDriveOAuthConfiguration.hasManagedClient) }
            }
            .disabled(isWorking)
            Spacer()
            Button("Disconnect This Account") {
              disconnectGoogleDrive()
            }
          }
          if let linked = existingGooglePublication,
             let owner = GoogleDriveAccountPreferences.accountID(forFileID: linked.fileID),
             owner != googleCredential.accountID {
            Label("This file was last published from \(googleAccounts.first { $0.accountID == owner }?.accountLabel ?? owner). The selected account can update it only if it has edit access.", systemImage: "person.crop.circle.badge.exclamationmark")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          if let managedClientID = GoogleDriveOAuthConfiguration.managedClientID(),
             googleCredential.clientID != managedClientID {
            Label("This account is connected through an older Google OAuth client. Choose Add Another Google Account… and sign in to the same account to move it to Celorga's current client.", systemImage: "arrow.triangle.2.circlepath")
              .font(.caption)
              .foregroundStyle(.orange)
          }
          Text("Celorga stores each account's refresh credential in macOS Keychain and requests only Google Drive’s per-file drive.file scope.")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text("OAuth client: \(abbreviatedClientID(googleCredential.clientID))")
            .font(.caption2.monospaced())
            .foregroundStyle(.tertiary)
        } else if GoogleDriveOAuthConfiguration.hasManagedClient {
          Button("Connect Google Drive") {
            Task { await connectGoogleDrive(usingCustomClient: false) }
          }
          .disabled(isWorking)

          Text("Celorga uses its registered Google OAuth client. Authorization opens in your default browser; your Google password and tokens are never entered into Celorga.")
            .font(.caption)
            .foregroundStyle(.secondary)

          DisclosureGroup(
            "Use a custom OAuth client",
            isExpanded: $showCustomGoogleOAuthClient
          ) {
            customGoogleOAuthClientConfiguration
              .padding(.top, 8)
          }
          .font(.caption)
        } else {
          customGoogleOAuthClientConfiguration
        }
      }
      .padding(14)
      .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private var customGoogleOAuthClientConfiguration: some View {
    VStack(alignment: .leading, spacing: 8) {
      TextField("Google OAuth Desktop client ID", text: $googleOAuthClientID)
        .textFieldStyle(.roundedBorder)
      SecureField("Google OAuth Desktop client secret", text: $googleOAuthClientSecret)
        .textFieldStyle(.roundedBorder)
      HStack {
        Button("Import Client JSON…") {
          importGoogleOAuthClientJSON()
        }
        Button("Connect with Custom Client") {
          Task { await connectGoogleDrive(usingCustomClient: true) }
        }
        .disabled(
          isWorking
            || GoogleDriveOAuthConfiguration.normalizedClientID(googleOAuthClientID) == nil
        )
        Button("Create OAuth client…") {
          if let url = URL(string: "https://console.cloud.google.com/apis/credentials") {
            NSWorkspace.shared.open(url)
          }
        }
      }
      Text("Advanced: import the JSON for a Google OAuth client of type Desktop app, or paste its paired client ID and client secret. The secret is masked here and saved only with the resulting OAuth credential in macOS Keychain.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private var localFormatDescription: String {
    switch format {
    case .html:
      "A polished read-only web page with embedded safe images."
    case .pdf:
      "A fixed-layout document PDF rendered from the disclosure-safe web page."
    case .beamerSlides:
      "A presentation PDF compiled from the selected content’s slide headings using a safe Beamer profile."
    case .googleDocs, .googleSlides, .googleSheets:
      "Choose a local publication format."
    }
  }

  private var googleFormatDescription: String {
    switch format {
    case .googleDocs:
      "Creates an editable Google Doc for prose, comments, and team collaboration."
    case .googleSlides:
      "Creates an editable Google Slides deck from the selected slide headings."
    case .googleSheets:
      "Creates an editable Google Sheet with one tab for each Org table in the selection."
    case .pdf:
      "Uploads a fixed-layout PDF to Google Drive for portable read-only sharing."
    case .html, .beamerSlides:
      "Choose a Google Drive publication format."
    }
  }

  private var disclosurePreview: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Label("Disclosure preview", systemImage: "eye")
          .font(.headline)
        Spacer()
        Button("Refresh Preview") {
          Task { await previewPublication() }
        }
        .disabled(isWorking)
      }

      if isWorking && preview == nil {
        HStack(spacing: 10) {
          ProgressView()
            .controlSize(.small)
          Text("Building the safe publication projection…")
            .font(.callout)
            .foregroundStyle(.secondary)
        }
      } else if let preview {
        VStack(alignment: .leading, spacing: 7) {
          Text(preview.artifact.title)
            .font(.body.weight(.medium))
          Text("\(byteCount(preview.artifact.bytes)) · \(preview.artifact.assets.count) embedded image\(preview.artifact.assets.count == 1 ? "" : "s") · \(preview.redactionCount) private or unsafe element\(preview.redactionCount == 1 ? "" : "s") removed")
            .font(.callout)
            .foregroundStyle(.secondary)

          let redactions = preview.disclosure.redactions
            .filter { $0.value > 0 }
            .sorted { $0.key < $1.key }
          if !redactions.isEmpty {
            ForEach(redactions, id: \.key) { key, count in
              Label("\(redactionLabel(key)): \(count)", systemImage: "minus.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          ForEach(Array(preview.disclosure.warnings.enumerated()), id: \.offset) { _, warning in
            Label(warning, systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
          }
        }
      } else {
        Text("Preview the exact disclosure boundary before publishing.")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
    .padding(14)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  @ViewBuilder
  private func outcomeView(_ outcome: DocumentPublishOutcome) -> some View {
    switch outcome {
    case .localLink(let publication, let result), .serverLink(let publication, let result):
      let isServer: Bool = { if case .serverLink = outcome { return true }; return false }()
      let hostName = isServer ? store.openOrgServer.serverName : "this Mac"
      VStack(alignment: .leading, spacing: 18) {
        resultHeader(
          title: "Published on \(hostName)",
          detail: isServer ? "Available while the server is running, even when this Mac sleeps" : "Available while Celorga is running",
          systemImage: "checkmark.circle.fill"
        )
        publicationLink(publication.url)
        Text("Anyone on a network that can reach \(hostName) and has this secret link can view the sealed \(result.artifact.selection). The source corpus remains inaccessible.")
          .font(.callout)
          .foregroundStyle(.secondary)
        Text("You can reopen, copy, or stop this link later in Settings → Sharing.")
          .font(.caption)
          .foregroundStyle(.secondary)
        HStack {
          Button("Open Shared Link") {
            NSWorkspace.shared.open(publication.openURL)
          }
          Button("Copy Link") {
            copy(publication.url.absoluteString)
          }
          Button("Stop Hosting", role: .destructive) {
            Task {
              do {
                if isServer {
                  try await store.revokeServerDocumentPublication(publication.id)
                } else {
                  store.revokeLocalDocumentPublication(publication.id)
                }
                dismiss()
              } catch { errorText = error.localizedDescription }
            }
          }
        }
      }

    case .googleDrive(let format, let url, let fileID, let version, _):
      VStack(alignment: .leading, spacing: 18) {
        resultHeader(
          title: "Published to \(format.title)",
          detail: version.map { "Drive version \($0)" } ?? "Google Drive permissions apply",
          systemImage: "checkmark.circle.fill"
        )
        publicationLink(url)
        Text("Document ID: \(fileID)")
          .font(.caption.monospaced())
          .foregroundStyle(.secondary)
          .textSelection(.enabled)
        Text("Celorga saved this link and Drive version in the Org source. Publishing the same scope and format again updates this file instead of creating a duplicate.")
          .font(.callout)
          .foregroundStyle(.secondary)
        HStack {
          Button(format == .pdf ? "Open in Google Drive" : "Open in \(format.title)") {
            NSWorkspace.shared.open(url)
          }
          Button("Copy Link") {
            copy(url.absoluteString)
          }
        }
      }
    }
  }

  private func resultHeader(title: String, detail: String, systemImage: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: systemImage)
        .font(.system(size: 28))
        .foregroundStyle(.green)
      VStack(alignment: .leading, spacing: 4) {
        Text(title)
          .font(.title3.weight(.semibold))
        Text(detail)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func publicationLink(_ url: URL) -> some View {
    Text(url.absoluteString)
      .font(.callout.monospaced())
      .textSelection(.enabled)
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
  }

  private var footer: some View {
    HStack {
      Button(outcome == nil ? "Cancel" : "Done") {
        dismiss()
      }
      .keyboardShortcut(.cancelAction)

      Spacer()

      if outcome == nil {
        if isWorking {
          ProgressView()
            .controlSize(.small)
        }
        Button(publishButtonTitle) {
          Task { await publish() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!canPublish)
      }
    }
  }

  private var request: DocumentPublishRequest {
    DocumentPublishRequest(
      destination: destination,
      format: format,
      line: scope == .subtree ? store.currentDocumentPublishSubtreeLine : nil,
      googleFolderID: destination == .googleDrive ? googleFolderID : nil,
      host: destination == .localLink ? selectedHost : nil
    )
  }

  private var hostedPublications: [LocalDocumentPublication] {
    selectedHost == .server
      ? store.openOrgServer.documentPublications.map(\.publication)
      : store.localDocumentPublications
  }

  private var selectedHost: ChatThreadShareLocation {
    host ?? store.openOrgServer.effectiveDefaultShareLocation
  }

  private var selectedHostName: String {
    selectedHost == .server ? store.openOrgServer.serverName : "this Mac"
  }

  private var googleCredential: GoogleDriveOAuthCredential? {
    googleAccounts.first { $0.accountID == selectedGoogleAccountID } ?? googleAccounts.first
  }

  private var canPublish: Bool {
    !isWorking
      && preview != nil
      && previewedRequest == request
      && (destination != .googleDrive || googleCredential != nil)
  }

  private var existingGooglePublication: GoogleDrivePublicationBinding? {
    store.googleDrivePublication(for: request)
  }

  private var publishButtonTitle: String {
    if destination == .localLink {
      return "Publish Local \(format.title)"
    }
    return existingGooglePublication == nil
      ? "Publish to \(format.title)"
      : "Update Linked \(format.title)"
  }

  private func invalidatePreview() {
    preview = nil
    previewedRequest = nil
    errorText = nil
  }

  @MainActor
  private func previewPublication() async {
    guard !isWorking else { return }
    isWorking = true
    errorText = nil
    defer { isWorking = false }
    let currentRequest = request
    do {
      preview = try await store.previewDocumentPublication(currentRequest)
      previewedRequest = currentRequest
    } catch {
      preview = nil
      previewedRequest = nil
      errorText = error.localizedDescription
    }
  }

  @MainActor
  private func publish() async {
    guard canPublish else { return }
    isWorking = true
    errorText = nil
    defer { isWorking = false }
    do {
      var googleAccessToken: String?
      if destination == .googleDrive {
        guard let credential = googleCredential else {
          throw DocumentPublishingError.missingGoogleCredential
        }
        let currentCredential = try await GoogleDriveOAuthClient().refreshingIfNeeded(credential)
        googleAccounts = try GoogleDriveOAuthCredentialKeychain.saveCredential(currentCredential)
        selectedGoogleAccountID = currentCredential.accountID
        googleAccessToken = currentCredential.accessToken
      }
      let published = try await store.publishDocument(
        request,
        googleAccessToken: googleAccessToken
      )
      if case .googleDrive(_, _, let fileID, _, _) = published, let account = googleCredential {
        GoogleDriveAccountPreferences.recordPublication(fileID: fileID, accountID: account.accountID)
      }
      outcome = published
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func restoreGoogleCredential() {
    if googleAccounts.isEmpty {
      googleAccounts = GoogleDriveOAuthCredentialKeychain.readCredentials()
    }
    if let credential = googleAccounts.first(where: {
      $0.clientID != GoogleDriveOAuthConfiguration.managedClientID()
    }) ?? googleAccounts.first {
      if credential.clientID != GoogleDriveOAuthConfiguration.managedClientID() {
        googleOAuthClientID = credential.clientID
        googleOAuthClientSecret = credential.clientSecret ?? ""
      }
      return
    }

    if GoogleDriveOAuthConfiguration.hasManagedClient {
      let savedClientID = GoogleDriveOAuthConfiguration.savedClientID()
      googleOAuthClientID = savedClientID == GoogleDriveOAuthConfiguration.managedClientID()
        ? ""
        : savedClientID ?? ""
      googleOAuthClientSecret = ""
    } else {
      showCustomGoogleOAuthClient = true
      googleOAuthClientID = GoogleDriveOAuthConfiguration.configuredClientID() ?? ""
      googleOAuthClientSecret = GoogleDriveOAuthConfiguration.configuredClientSecret() ?? ""
    }
  }

  private func restoreLinkedGoogleDestination() {
    let linked = store.currentDocumentGoogleDrivePublications
      .filter { $0.scopeLine == nil }
      .max { left, right in
        (left.publishedAt ?? .distantPast) < (right.publishedAt ?? .distantPast)
      }
    guard let linked else { return }
    destination = .googleDrive
    restoredLinkedSlides = linked.format.isSlides
    format = linked.format
  }

  private func selectPreferredGoogleAccount() {
    selectedGoogleAccountID = GoogleDriveAccountPreferences.preferredAccountID(
      among: googleAccounts,
      linkedFileID: existingGooglePublication?.fileID
    )
  }

  /// Accounts saved before multi-account support have no email. Label them
  /// once so the picker can tell them apart; failures leave them unlabeled.
  @MainActor
  private func identifyUnlabeledGoogleAccounts() async {
    for account in googleAccounts where account.accountEmail == nil {
      let client = GoogleDriveOAuthClient()
      guard let current = try? await client.refreshingIfNeeded(account),
            let identity = await client.accountIdentity(accessToken: current.accessToken, scope: current.scope)
      else { continue }
      let wasSelected = selectedGoogleAccountID == account.accountID
      let labeled = current.withAccount(identity)
      var remaining = googleAccounts.filter { $0.accountID != account.accountID }
      remaining = GoogleDriveOAuthCredentialKeychain.upserting(labeled, into: remaining)
      do {
        try GoogleDriveOAuthCredentialKeychain.saveCredentials(remaining)
        googleAccounts = remaining
        if wasSelected { selectedGoogleAccountID = labeled.accountID }
      } catch {
        continue
      }
    }
  }

  /// Slide formats are offered while the document is shown as slides, or
  /// when this document is already linked to a Google Slides deck to update.
  private var showsSlideFormats: Bool {
    store.showsSlideActions || restoredLinkedSlides
  }

  @MainActor
  private func connectGoogleDrive(usingCustomClient: Bool) async {
    guard !isWorking else { return }
    isWorking = true
    errorText = nil
    defer { isWorking = false }
    do {
      let client: GoogleDriveOAuthDesktopClient
      if usingCustomClient {
        client = try GoogleDriveOAuthDesktopClient(
          clientID: googleOAuthClientID,
          clientSecret: googleOAuthClientSecret
        )
      } else {
        guard let managedClient = GoogleDriveOAuthConfiguration.managedClientPair() else {
          throw GoogleDriveOAuthError.invalidClientID
        }
        guard managedClient.clientSecret != nil else {
          throw GoogleDriveOAuthError.missingClientSecret
        }
        client = managedClient
      }
      let credential = try await GoogleDriveOAuthClient().authorize(
        clientID: client.clientID,
        clientSecret: client.clientSecret,
        openAuthorizationURL: { url in
          await MainActor.run {
            NSWorkspace.shared.open(url)
          }
        }
      )
      if usingCustomClient {
        GoogleDriveOAuthConfiguration.saveClientID(credential.clientID)
        googleOAuthClientID = credential.clientID
        googleOAuthClientSecret = credential.clientSecret ?? ""
      }
      googleAccounts = try GoogleDriveOAuthCredentialKeychain.saveCredential(credential)
      selectedGoogleAccountID = credential.accountID
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func disconnectGoogleDrive() {
    do {
      guard let disconnectedCredential = googleCredential else { return }
      googleAccounts = try GoogleDriveOAuthCredentialKeychain.deleteCredential(
        accountID: disconnectedCredential.accountID
      )
      selectedGoogleAccountID = googleAccounts.first?.accountID
      if googleAccounts.isEmpty,
         disconnectedCredential.clientID != GoogleDriveOAuthConfiguration.managedClientID() {
        googleOAuthClientID = disconnectedCredential.clientID
        googleOAuthClientSecret = disconnectedCredential.clientSecret ?? ""
        showCustomGoogleOAuthClient = true
      }
    } catch {
      errorText = error.localizedDescription
    }
  }

  @MainActor
  private func importGoogleOAuthClientJSON() {
    let panel = NSOpenPanel()
    panel.title = "Import Google OAuth Desktop Client"
    panel.prompt = "Import Client"
    panel.message = "Choose the JSON file downloaded for a Google OAuth client of type Desktop app."
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowsMultipleSelection = false
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let client = try GoogleDriveOAuthDesktopClient.decodeGoogleClientJSON(Data(contentsOf: url))
      googleOAuthClientID = client.clientID
      googleOAuthClientSecret = client.clientSecret ?? ""
      errorText = client.clientSecret == nil
        ? "This Desktop client JSON has no client secret. You can still try connecting; Google may require a client that includes one."
        : nil
    } catch {
      errorText = error.localizedDescription
    }
  }

  private func abbreviatedClientID(_ clientID: String) -> String {
    guard clientID.count > 28 else { return clientID }
    return "\(clientID.prefix(16))…\(clientID.suffix(10))"
  }

  private func copy(_ value: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(value, forType: .string)
  }

  private func byteCount(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
  }

  private func redactionLabel(_ key: String) -> String {
    switch key {
    case "commentedSubtrees": "Commented subtrees"
    case "internalLinks": "Internal links"
    case "localFiles": "Local files"
    case "rawHtml": "Raw HTML"
    case "runtimeData": "Runtime data"
    case "unsafeLinks": "Unsafe links"
    default: key.prefix(1).uppercased() + key.dropFirst()
    }
  }
}
