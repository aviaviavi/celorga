import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
  private var host: UIHostingController<ShareCaptureView>?

  override func viewDidLoad() {
    super.viewDidLoad()
    embed(title: "", body: "", isLoading: true, errorMessage: nil)
    loadSharedContent()
  }

  private func embed(title: String, body: String, isLoading: Bool, errorMessage: String?) {
    let view = ShareCaptureView(
      initialTitle: title,
      initialBody: body,
      isLoading: isLoading,
      initialErrorMessage: errorMessage,
      onCancel: { [weak self] in
        self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
      },
      onSave: { [weak self] title, body, scheduledDate in
        self?.save(title: title, body: body, scheduledDate: scheduledDate)
      }
    )

    let host = UIHostingController(rootView: view)
    addChild(host)
    self.view.addSubview(host.view)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      host.view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
      host.view.topAnchor.constraint(equalTo: self.view.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor),
    ])
    host.didMove(toParent: self)

    self.host?.willMove(toParent: nil)
    self.host?.view.removeFromSuperview()
    self.host?.removeFromParent()
    self.host = host
  }

  private func loadSharedContent() {
    let attachments = extensionContext?.inputItems
      .compactMap { $0 as? NSExtensionItem }
      .flatMap { $0.attachments ?? [] } ?? []

    guard !attachments.isEmpty else {
      embed(title: "", body: "", isLoading: false, errorMessage: nil)
      return
    }

    let group = DispatchGroup()
    let accumulator = ShareLoadAccumulator()

    for provider in attachments {
      if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
          if let url = Self.url(from: item) {
            accumulator.append(url: url)
          }
          group.leave()
        }
      }

      if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
        group.enter()
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
          if let text = Self.text(from: item) {
            accumulator.append(text: text)
          }
          group.leave()
        }
      }
    }

    group.notify(queue: .main) {
      let texts = accumulator.texts
      let urls = accumulator.urls
      let title = Self.defaultTitle(texts: texts, urls: urls)
      let body = Self.defaultBody(texts: texts, urls: urls)
      self.embed(title: title, body: body, isLoading: false, errorMessage: nil)
    }
  }

  /// Queues the item in the app group. Celorga sends the queue to the
  /// paired host the next time it runs; the phone holds no corpus to write to.
  private func save(title: String, body: String, scheduledDate: Date?) {
    do {
      let capture = MobileCaptureWriter.noteCapture(
        title: title,
        body: body,
        scheduledDate: scheduledDate
      )
      try MobileCaptureOutbox.enqueue(capture)
      extensionContext?.completeRequest(returningItems: nil)
    } catch {
      embed(
        title: title,
        body: body,
        isLoading: false,
        errorMessage: "Could not save this item for Celorga. Try again."
      )
    }
  }

  nonisolated private static func url(from item: Any?) -> URL? {
    if let url = item as? URL { return url }
    if let url = item as? NSURL { return url as URL }
    if let string = item as? String { return URL(string: string) }
    return nil
  }

  nonisolated private static func text(from item: Any?) -> String? {
    if let text = item as? String { return text }
    if let data = item as? Data { return String(data: data, encoding: .utf8) }
    if let url = item as? URL { return url.absoluteString }
    return nil
  }

  private static func defaultTitle(texts: [String], urls: [URL]) -> String {
    if let firstLine = texts
      .flatMap({ $0.components(separatedBy: .newlines) })
      .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
      .first(where: { !$0.isEmpty }) {
      return String(firstLine.prefix(90))
    }
    if let url = urls.first {
      return url.host(percentEncoded: false) ?? url.absoluteString
    }
    return "Shared item"
  }

  private static func defaultBody(texts: [String], urls: [URL]) -> String {
    var parts = texts
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
    parts.append(contentsOf: urls.map(\.absoluteString))
    let uniqueParts = Array(NSOrderedSet(array: parts)) as? [String] ?? parts
    return uniqueParts.joined(separator: "\n\n")
  }
}

private final class ShareLoadAccumulator: @unchecked Sendable {
  private let lock = NSLock()
  private var loadedTexts: [String] = []
  private var loadedURLs: [URL] = []

  var texts: [String] {
    lock.lock()
    defer { lock.unlock() }
    return loadedTexts
  }

  var urls: [URL] {
    lock.lock()
    defer { lock.unlock() }
    return loadedURLs
  }

  func append(text: String) {
    lock.lock()
    loadedTexts.append(text)
    lock.unlock()
  }

  func append(url: URL) {
    lock.lock()
    loadedURLs.append(url)
    lock.unlock()
  }
}

private struct ShareCaptureView: View {
  @State private var title: String
  @State private var bodyText: String
  @State private var schedule: MobileNoteSchedule = .none
  @State private var customScheduledDate = Date()
  @State private var isSaving = false
  @State private var errorMessage: String?
  let isLoading: Bool
  let onCancel: () -> Void
  let onSave: (String, String, Date?) -> Void

  init(
    initialTitle: String,
    initialBody: String,
    isLoading: Bool,
    initialErrorMessage: String?,
    onCancel: @escaping () -> Void,
    onSave: @escaping (String, String, Date?) -> Void
  ) {
    _title = State(initialValue: initialTitle)
    _bodyText = State(initialValue: initialBody)
    _errorMessage = State(initialValue: initialErrorMessage)
    self.isLoading = isLoading
    self.onCancel = onCancel
    self.onSave = onSave
  }

  var body: some View {
    NavigationStack {
      List {
        if isLoading {
          Section {
            HStack(spacing: 10) {
              ShareActivityGlyph(style: .incoming, label: "Loading shared item")
              Text("Loading shared item")
            }
          }
        } else {
          if let errorMessage {
            Section {
              Text(errorMessage)
                .foregroundStyle(.red)
            }
          }

          Section("Capture") {
            TextField("Title", text: $title)
            TextEditor(text: $bodyText)
              .frame(minHeight: 120)
          }

          Section("Schedule TODO") {
            ForEach(MobileNoteSchedule.allCases) { option in
              Button {
                schedule = option
              } label: {
                Label(option.title, systemImage: schedule == option ? "checkmark.circle.fill" : option.systemImage)
              }
            }

            if schedule == .custom {
              DatePicker("Date", selection: $customScheduledDate, displayedComponents: .date)
            } else if let scheduledDate {
              Label(MobileCaptureWriter.orgDayTimestamp(scheduledDate), systemImage: "calendar")
                .foregroundStyle(.secondary)
            }
          }
        }
      }
      .navigationTitle("Capture to Celorga")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel", action: onCancel)
            .disabled(isSaving)
        }
        ToolbarItem(placement: .confirmationAction) {
          Button {
            isSaving = true
            onSave(title, bodyText, scheduledDate)
          } label: {
            if isSaving {
              ShareActivityGlyph(style: .saving, label: "Saving")
            } else {
              Text("Save")
            }
          }
          .disabled(isLoading || isSaving || !canSave)
        }
      }
    }
  }

  private var scheduledDate: Date? {
    schedule.scheduledDate(customDate: customScheduledDate)
  }

  private var canSave: Bool {
    !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      || !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

private enum ShareActivityStyle: Equatable {
  case incoming
  case saving
}

private struct ShareActivityGlyph: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let style: ShareActivityStyle
  let label: String

  var body: some View {
    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
      let phase = reduceMotion
        ? 0.2
        : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2

      if style == .incoming {
        VStack(alignment: .leading, spacing: 2.5) {
          ForEach(0..<3, id: \.self) { index in
            Capsule()
              .fill(Color.accentColor.opacity(0.28 + Double(wave(phase, index: index)) * 0.72))
              .frame(width: CGFloat(16 - index * 3), height: 2.5)
          }
        }
      } else {
        HStack(spacing: 2.5) {
          ForEach(0..<3, id: \.self) { index in
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
              .fill(Color.accentColor.opacity(0.32 + Double(wave(phase, index: index)) * 0.68))
              .frame(width: 3.5, height: 3.5)
              .rotationEffect(.degrees(45))
              .offset(y: -wave(phase, index: index) * 2.5)
          }
        }
      }
    }
    .frame(width: 20, height: 16)
    .accessibilityLabel(label)
  }

  private func wave(_ phase: Double, index: Int) -> CGFloat {
    let angle = phase * 2 * Double.pi - Double(index) * 0.9
    return CGFloat((sin(angle) + 1) / 2)
  }
}
