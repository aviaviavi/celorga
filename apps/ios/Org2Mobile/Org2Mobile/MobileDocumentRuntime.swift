import Foundation
import JavaScriptCore

// Confined to the background operation that creates it; JSContext never crosses tasks.
final class MobileDocumentRuntime {
  private let context: JSContext

  init() throws {
    guard let context = JSContext(),
          let url = Bundle.main.url(forResource: "Org2MobileDocument", withExtension: "js")
    else { throw RuntimeError("The local document renderer is unavailable.") }
    self.context = context
    context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
    if let exception = context.exception { throw RuntimeError(exception.toString()) }
  }

  func index(source: String, path: String, sequences: [String]) throws -> [MobileSearchEntry] {
    try call("indexDocument", arguments: [source, path, sequences])
  }

  func resolveEntry(source: String, path: String, selector: String, sequences: [String]) throws -> MobileSearchEntry? {
    struct Resolution: Decodable { let entry: MobileSearchEntry? }
    let result: Resolution = try call("resolveEntry", arguments: [source, path, selector, sequences])
    return result.entry
  }

  func render(source: String, path: String, entry: MobileSearchEntry?, sequences: [String]) throws -> MobileRenderedDocument {
    try call("renderDocument", arguments: [source, path, entry?.line ?? 0, entry?.nodeID ?? "", sequences, entry?.title ?? ""])
  }

  private func call<T: Decodable>(_ name: String, arguments: [Any]) throws -> T {
    context.exception = nil
    guard let value = context.objectForKeyedSubscript("Org2MobileDocument")?.invokeMethod(name, withArguments: arguments),
          context.exception == nil, let object = value.toObject()
    else { throw RuntimeError(context.exception?.toString() ?? "Could not read this Org document.") }
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
  }

  private struct RuntimeError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
  }
}

struct MobileRenderedDocument: Decodable, Sendable {
  let title: String
  let html: String
  /// "slides" for a whole presentation file, otherwise "document".
  var kind: String? = nil
  /// Local images the reader cannot load itself; the view fetches them from
  /// the host and inlines them.
  var images: [MobileDocumentImage]? = nil

  var isSlides: Bool { kind == "slides" }

  /// Replaces each fetched image's `src` with a data URL, which the reader's
  /// content security policy allows.
  func inliningImages(_ data: [String: Data]) -> MobileRenderedDocument {
    var html = html
    for image in images ?? [] {
      guard let bytes = data[image.src] else { continue }
      let url = "data:\(image.mimeType);base64,\(bytes.base64EncodedString())"
      html = html.replacingOccurrences(of: "src=\"\(image.src)\"", with: "src=\"\(url)\"")
    }
    return MobileRenderedDocument(title: title, html: html, kind: kind, images: nil)
  }
}

struct MobileDocumentImage: Decodable, Hashable, Sendable {
  /// The attribute value as written in the rendered HTML.
  let src: String
  /// Corpus-relative (or absolute) path for the host's image endpoint.
  let path: String

  var mimeType: String {
    switch URL(fileURLWithPath: path).pathExtension.lowercased() {
    case "jpg", "jpeg": "image/jpeg"
    case "gif": "image/gif"
    case "webp": "image/webp"
    case "heic": "image/heic"
    case "svg": "image/svg+xml"
    default: "image/png"
    }
  }
}

/// A single serial executor owns JavaScriptCore. Warming does not read any notes.
/// Keep at most one small rendered result and release everything after a minute
/// idle, on memory pressure, or when the app leaves the foreground.
final class MobileDocumentRenderer: @unchecked Sendable {
  private let queue = DispatchQueue(label: "org.org2.mobile.document-renderer", qos: .userInitiated)
  private var runtime: MobileDocumentRuntime?
  private var cached: (request: Request, document: MobileRenderedDocument)?
  private var idleRelease: DispatchWorkItem?
  private var initializationCount = 0
  private let idleSeconds: Double
  private let cacheByteLimit = 2 * 1024 * 1024

  private struct Request: Equatable, Sendable {
    let source: String
    let path: String
    let entry: MobileSearchEntry?
    let sequences: [String]
    let corpusID: String
  }

  init(idleSeconds: Double = 60) {
    self.idleSeconds = idleSeconds
  }

  func prewarm() {
    queue.async { [self] in
      if runtime == nil {
        runtime = try? MobileDocumentRuntime()
        if runtime != nil { initializationCount += 1 }
      }
      scheduleIdleRelease()
    }
  }

  func releaseResources() {
    queue.async { [self] in
      idleRelease?.cancel()
      idleRelease = nil
      cached = nil
      runtime = nil
    }
  }

  func render(source: String, path: String, entry: MobileSearchEntry?, sequences: [String], corpusID: String) async throws -> MobileRenderedDocument {
    let request = Request(source: source, path: path, entry: entry, sequences: sequences, corpusID: corpusID)
    let cancellation = RenderCancellation()
    return try await withTaskCancellationHandler {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        queue.async { [self] in
          do {
            try cancellation.check()
            defer { scheduleIdleRelease() }
            let document: MobileRenderedDocument
            if let cached, cached.request == request {
              document = cached.document
            } else {
              if runtime == nil {
                runtime = try MobileDocumentRuntime()
                initializationCount += 1
              }
              document = try runtime!.render(source: source, path: path, entry: entry, sequences: sequences)
              // Do not retain a large note or the previous note after a miss.
              cached = nil
              if source.utf8.count + document.html.utf8.count + (entry?.body.utf8.count ?? 0) <= cacheByteLimit {
                cached = (request, document)
              }
            }
            try cancellation.check()
            continuation.resume(returning: document)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    } onCancel: {
      cancellation.cancel()
    }
  }

  func stateForTesting() async -> (initializations: Int, hasRuntime: Bool, hasCachedDocument: Bool) {
    await withCheckedContinuation { continuation in
      queue.async { [self] in
        continuation.resume(returning: (initializationCount, runtime != nil, cached != nil))
      }
    }
  }

  private func scheduleIdleRelease() {
    idleRelease?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.cached = nil
      self?.runtime = nil
      self?.idleRelease = nil
    }
    idleRelease = work
    queue.asyncAfter(deadline: .now() + idleSeconds, execute: work)
  }
}

private final class RenderCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false

  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }

  func check() throws {
    lock.lock()
    let value = cancelled
    lock.unlock()
    if value { throw CancellationError() }
  }
}
