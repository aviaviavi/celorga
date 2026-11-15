import CryptoKit
import Foundation

/// Only the disclosure-safe output crosses the paired connection, never Org source.
public struct MobileRemoteDocumentPublishRequest: Codable, Sendable {
  public let stableKey: String
  public let title: String
  public let format: String
  public let sourcePath: String
  public let data: Data

  static let maximumArtifactBytes = 8_000_000 // Base64 plus metadata fits the relay's 12 MB limit.

  var publishFormat: DocumentPublishFormat? {
    DocumentPublishFormat(rawValue: format).flatMap {
      DocumentPublishDestination.localLink.formats.contains($0) ? $0 : nil
    }
  }
}

public struct MobileRemoteDocumentPublication: Codable, Identifiable, Sendable {
  public let id: String
  public let title: String
  public let url: URL
  public let mediaType: String
  public let sourcePath: String?
  public let format: String?
  public let createdAt: Date

  init(_ publication: LocalDocumentPublication) {
    id = publication.id
    title = publication.title
    url = publication.url
    mediaType = publication.mediaType
    sourcePath = publication.sourcePath
    format = publication.format?.rawValue
    createdAt = publication.createdAt
  }

  public var publication: LocalDocumentPublication {
    LocalDocumentPublication(
      id: id, title: title, url: url, localURL: url, mediaType: mediaType,
      sourcePath: sourcePath, format: format.flatMap(DocumentPublishFormat.init(rawValue:)),
      createdAt: createdAt
    )
  }
}

extension MobileRemoteCoordinator {
  /// Called only after the relay's bearer-token authentication.
  func handleDocumentPublication(
    _ request: MobileRemoteHTTPRequest,
    path: String,
    store: WorkspaceStore
  ) async -> MobileRemoteHTTPResponse {
    if request.method == "GET", path == "/v1/document-publications" {
      await store.restoreLocalDocumentPublications()
      return .json(store.localDocumentPublications.filter { $0.chatThreadID == nil }
        .map(MobileRemoteDocumentPublication.init))
    }
    if request.method == "POST", path == "/v1/document-publications" {
      guard let payload = try? request.decode(MobileRemoteDocumentPublishRequest.self),
            let format = payload.publishFormat,
            !payload.stableKey.isEmpty, payload.stableKey.utf8.count <= 4096,
            !payload.title.isEmpty, payload.title.utf8.count <= 4096,
            payload.sourcePath.utf8.count <= 4096,
            !payload.data.isEmpty,
            payload.data.count <= MobileRemoteDocumentPublishRequest.maximumArtifactBytes
      else { return .error("Invalid or oversized sealed document (maximum 8 MB).", statusCode: 400) }
      do {
        let mediaType = format == .html ? "text/html" : "application/pdf"
        let data = format == .html ? payload.data : try Org2PDFExporter.validated(payload.data)
        // Separate document keys from live thread keys supplied by other clients.
        let key = "openorg-remote-document:" + SHA256.hash(data: Data(payload.stableKey.utf8))
          .map { String(format: "%02x", $0) }.joined()
        let publication = try await store.localDocumentPublicationHost.publish(
          data: data, title: payload.title, mediaType: mediaType,
          sourcePath: payload.sourcePath, format: format, stableKey: key
        )
        store.localDocumentPublications.removeAll { $0.id == publication.id }
        store.localDocumentPublications.insert(publication, at: 0)
        return .json(MobileRemoteDocumentPublication(publication), statusCode: 201)
      } catch {
        return .error(error.localizedDescription, statusCode: 503)
      }
    }
    let components = path.split(separator: "/").map(String.init)
    if request.method == "DELETE", components.count == 3,
       components[0] == "v1", components[1] == "document-publications" {
      await store.restoreLocalDocumentPublications()
      guard let publication = store.localDocumentPublications.first(where: {
        $0.id == components[2] && $0.chatThreadID == nil
      }) else { return .error("Document link not found.", statusCode: 404) }
      do {
        try store.localDocumentPublicationHost.revoke(publication.id)
        store.localDocumentPublications.removeAll { $0.id == publication.id }
        return .json(MobileRemoteMutationResponse(accepted: true))
      } catch {
        return .error(error.localizedDescription, statusCode: 503)
      }
    }
    return .error("Remote action not found.", statusCode: 404)
  }
}
