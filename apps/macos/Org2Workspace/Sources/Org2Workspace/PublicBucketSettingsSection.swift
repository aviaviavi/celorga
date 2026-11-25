import AppKit
import Org2WorkspaceCore
import SwiftUI

/// Settings → Sharing → Public Links: the user's own S3-compatible bucket
/// (Cloudflare R2, Amazon S3, …) and the public links stored in it.
struct PublicBucketSettingsSection: View {
  @Environment(WorkspaceStore.self) private var store
  @State private var endpoint = ""
  @State private var bucket = ""
  @State private var publicBaseURL = ""
  @State private var region = PublicBucketConfiguration.defaultRegion
  @State private var keyPrefix = PublicBucketConfiguration.defaultKeyPrefix
  @State private var accessKeyID = ""
  @State private var secretAccessKey = ""
  @State private var hasSavedSecret = false
  @State private var isWorking = false
  @State private var statusMessage: String?
  @State private var statusIsError = false
  @State private var linkError: String?
  @State private var isConfirmingRemove = false

  var body: some View {
    Section {
      TextField("S3 API endpoint", text: $endpoint, prompt: Text("https://ACCOUNT_ID.r2.cloudflarestorage.com/BUCKET"))
      TextField("Bucket", text: $bucket, prompt: Text("Optional when the endpoint ends in the bucket"))
      TextField("Public URL", text: $publicBaseURL, prompt: Text("https://pub-….r2.dev or your custom domain"))
      TextField("Region", text: $region, prompt: Text("auto for R2; for example us-east-1 for S3"))
      TextField("Access key ID", text: $accessKeyID)
      SecureField(
        "Secret access key",
        text: $secretAccessKey,
        prompt: Text(hasSavedSecret ? "Saved in Keychain" : "Required")
      )

      HStack {
        Button("Save and Test") {
          Task { await saveAndTest() }
        }
        .disabled(isWorking || endpoint.trimmingCharacters(in: .whitespaces).isEmpty || publicBaseURL.trimmingCharacters(in: .whitespaces).isEmpty)
        if isWorking {
          ProgressView().controlSize(.small)
        }
        Spacer()
        if store.publicBucketConfiguration != nil || hasSavedSecret {
          Button("Remove Bucket…", role: .destructive) {
            isConfirmingRemove = true
          }
          .disabled(isWorking)
        }
      }

      if let statusMessage {
        Label(statusMessage, systemImage: statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
          .foregroundStyle(statusIsError ? .red : .green)
          .textSelection(.enabled)
      }
    } header: {
      Label("Public Links", systemImage: "globe")
    } footer: {
      SettingsFooterText("Public links upload sealed documents to a bucket you own, so anyone with a link can open it from anywhere, even while this Mac is offline. Nothing connects back to this Mac, and Celorga runs no server for them. For Cloudflare R2: create a bucket, turn on its public r2.dev URL or connect a custom domain, and create an API token with Object Read & Write access to that bucket. The secret key is stored in Keychain on this Mac.")
    }
    .task { restore() }
    .confirmationDialog("Remove the public bucket?", isPresented: $isConfirmingRemove) {
      Button("Remove Bucket", role: .destructive) { removeBucket() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("Celorga forgets the bucket settings and deletes the access key from Keychain. Links already published stay online; stop them first if they should go away.")
    }

    Section {
      if store.publicBucketPublications.isEmpty {
        Text("No public links yet. Choose Public Link when publishing a document.")
          .foregroundStyle(.secondary)
      } else {
        ForEach(store.publicBucketPublications) { publication in
          publicationRow(publication)
        }
      }
      if let linkError {
        Text(linkError).foregroundStyle(.red).textSelection(.enabled)
      }
    } header: {
      Label("Active Public Links", systemImage: "link")
    } footer: {
      SettingsFooterText("Stopping a link deletes its file from the bucket. Pages are uploaded with caching disabled, so a stopped link stops working right away.")
    }
  }

  private func publicationRow(_ publication: PublicBucketPublication) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: publication.format?.systemImage ?? "globe")
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 24)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 7) {
          Text(publication.title)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
          Text(publication.format?.title ?? publication.mediaType)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
        }
        Text(publication.url.absoluteString)
          .font(.caption2.monospaced())
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .textSelection(.enabled)
        Text("In \(publication.bucketName) · updated \(publication.updatedAt.formatted(date: .abbreviated, time: .shortened))")
          .font(.caption2)
          .foregroundStyle(.tertiary)
      }
      Spacer(minLength: 8)
      HStack(spacing: 8) {
        Button {
          NSWorkspace.shared.open(publication.url)
        } label: {
          Image(systemName: "arrow.up.right.square")
        }
        .buttonStyle(.borderless)
        .help("Open public link")
        Button {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(publication.url.absoluteString, forType: .string)
        } label: {
          Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless)
        .help("Copy link")
        Button(role: .destructive) {
          Task { await stop(publication) }
        } label: {
          Image(systemName: "stop.circle")
        }
        .buttonStyle(.borderless)
        .disabled(isWorking)
        .help("Stop sharing and delete the file from the bucket")
      }
    }
    .padding(.vertical, 5)
    .contextMenu {
      Button("Forget Without Deleting") {
        store.forgetPublicBucketPublication(publication.id)
      }
    }
  }

  private var editedConfiguration: PublicBucketConfiguration {
    PublicBucketConfiguration(
      endpoint: endpoint,
      bucket: bucket,
      region: region,
      publicBaseURL: publicBaseURL,
      keyPrefix: keyPrefix
    ).normalized
  }

  private func restore() {
    store.reloadPublicBucketPublications()
    if let configuration = store.publicBucketConfiguration {
      endpoint = configuration.endpoint
      bucket = configuration.bucket
      publicBaseURL = configuration.publicBaseURL
      region = configuration.region
      keyPrefix = configuration.keyPrefix
    }
    if let credentials = PublicBucketCredentialKeychain.read() {
      accessKeyID = credentials.accessKeyID
      hasSavedSecret = credentials.isComplete
    }
  }

  @MainActor
  private func saveAndTest() async {
    isWorking = true
    statusMessage = nil
    defer { isWorking = false }
    let saved = PublicBucketCredentialKeychain.read()
    let secret = secretAccessKey.isEmpty ? saved?.secretAccessKey ?? "" : secretAccessKey
    let credentials = PublicBucketCredentials(accessKeyID: accessKeyID, secretAccessKey: secret)
    guard credentials.isComplete else {
      statusIsError = true
      statusMessage = PublicBucketError.missingCredentials.localizedDescription
      return
    }
    let configuration = editedConfiguration
    do {
      let result = try await store.checkPublicBucket(configuration, credentials: credentials)
      try PublicBucketCredentialKeychain.save(credentials)
      store.savePublicBucketConfiguration(configuration)
      secretAccessKey = ""
      hasSavedSecret = true
      if result.publiclyReadable {
        statusIsError = false
        statusMessage = "Saved. Celorga uploaded, opened, and deleted a test page in \(configuration.displayName)."
      } else {
        statusIsError = true
        statusMessage = "Saved, but the public URL did not serve the test page. \(result.detail ?? "")"
      }
    } catch {
      statusIsError = true
      statusMessage = error.localizedDescription
    }
  }

  private func removeBucket() {
    do {
      try PublicBucketCredentialKeychain.delete()
      store.savePublicBucketConfiguration(nil)
      endpoint = ""
      bucket = ""
      publicBaseURL = ""
      region = PublicBucketConfiguration.defaultRegion
      keyPrefix = PublicBucketConfiguration.defaultKeyPrefix
      accessKeyID = ""
      secretAccessKey = ""
      hasSavedSecret = false
      statusIsError = false
      statusMessage = "Bucket removed."
    } catch {
      statusIsError = true
      statusMessage = error.localizedDescription
    }
  }

  @MainActor
  private func stop(_ publication: PublicBucketPublication) async {
    isWorking = true
    linkError = nil
    defer { isWorking = false }
    do {
      try await store.revokePublicBucketPublication(publication.id)
    } catch {
      linkError = error.localizedDescription
    }
  }
}
