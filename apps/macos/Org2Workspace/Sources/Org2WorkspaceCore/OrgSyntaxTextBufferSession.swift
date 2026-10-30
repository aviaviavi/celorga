import Foundation

/// A revisioned piece-tree mirror for large native editor buffers.
///
/// AppKit owns `NSTextStorage` on the main thread. Reading `NSTextView.string`
/// at a click, window, or navigation boundary can therefore couple a
/// multi-megabyte copy to event dispatch. This mirror accepts the same UTF-16
/// edits in O(log(number-of-uncheckpointed-edits)) time and materializes
/// immutable snapshots on a background executor. Successful snapshots rebase
/// the tree when no newer edit arrived, keeping ordinary typing costs bounded.
final class OrgSyntaxTextBufferSession: @unchecked Sendable {
  struct Snapshot: Sendable {
    let text: String
    let revision: Int
  }

  /// An immutable, O(1) point-in-time view of the piece tree. Capturing this
  /// value is deliberately synchronous so callers can establish an exact save
  /// or navigation boundary before yielding to another task. Materializing the
  /// captured text may then happen off the main actor.
  struct Capture: @unchecked Sendable {
    fileprivate let base: NSString
    fileprivate let additions: [NSString]
    fileprivate let root: Node?
    let utf16Length: Int
    let revision: Int
  }

  fileprivate struct Piece: Sendable {
    /// `nil` addresses the immutable base; otherwise this indexes additions.
    let additionIndex: Int?
    let range: NSRange
  }

  /// An immutable AVL rope. Persistent path-copying lets a snapshot retain its
  /// root after releasing the lock while later edits safely create a new root.
  fileprivate final class Node: @unchecked Sendable {
    let piece: Piece
    let left: Node?
    let right: Node?
    let height: Int
    let utf16Length: Int

    init(piece: Piece, left: Node? = nil, right: Node? = nil) {
      self.piece = piece
      self.left = left
      self.right = right
      height = max(left?.height ?? 0, right?.height ?? 0) + 1
      utf16Length = (left?.utf16Length ?? 0) + piece.range.length + (right?.utf16Length ?? 0)
    }
  }

  private struct State {
    var base: NSString
    var additions: [NSString]
    var root: Node?
    var utf16Length: Int
    var revision: Int
  }

  private let lock = NSLock()
  private var state: State

  init(text: String) {
    let base = text as NSString
    state = State(
      base: base,
      additions: [],
      root: Self.baseNode(length: base.length),
      utf16Length: base.length,
      revision: 0
    )
  }

  var revision: Int {
    lock.withLock { state.revision }
  }

  var utf16Length: Int {
    lock.withLock { state.utf16Length }
  }

  func reset(to text: String) {
    let base = text as NSString
    lock.withLock {
      state.base = base
      state.additions = []
      state.root = Self.baseNode(length: base.length)
      state.utf16Length = base.length
      state.revision &+= 1
    }
  }

  @discardableResult
  func replaceCharacters(in requestedRange: NSRange, with replacement: String) -> Int {
    let replacementSource = replacement as NSString
    return lock.withLock {
      let location = min(max(0, requestedRange.location), state.utf16Length)
      let range = NSRange(
        location: location,
        length: min(max(0, requestedRange.length), state.utf16Length - location)
      )

      let (prefix, afterPrefix) = Self.split(state.root, at: range.location)
      let (_, suffix) = Self.split(afterPrefix, at: range.length)

      let replacementNode: Node?
      if replacementSource.length > 0 {
        let additionIndex = state.additions.count
        state.additions.append(replacementSource)
        replacementNode = Node(
          piece: Piece(
            additionIndex: additionIndex,
            range: NSRange(location: 0, length: replacementSource.length)
          )
        )
      } else {
        replacementNode = nil
      }

      state.root = Self.concatenate(Self.concatenate(prefix, replacementNode), suffix)
      state.utf16Length += replacementSource.length - range.length
      state.revision &+= 1
      return state.revision
    }
  }

  func snapshot() -> Snapshot {
    snapshot(from: capture())
  }

  func capture() -> Capture {
    lock.withLock {
      Capture(
        base: state.base,
        additions: state.additions,
        root: state.root,
        utf16Length: state.utf16Length,
        revision: state.revision
      )
    }
  }

  func snapshot(from captured: Capture) -> Snapshot {
    let materialized = NSMutableString(capacity: captured.utf16Length)
    Self.forEachPiece(in: captured.root) { piece in
      let source = piece.additionIndex.map { captured.additions[$0] } ?? captured.base
      materialized.append(source.substring(with: piece.range))
    }
    // Keep the piece table on an immutable UTF-16 base, but hand callers a
    // native UTF-8 String. A lazily bridged NSString makes every later
    // `utf8.count`, comparison, and hash on the main actor transcode the
    // whole document; doing it once here keeps that work on the snapshot's
    // thread (off-main for large documents).
    let base = materialized.copy() as! NSString
    var text = String(base)
    text.makeContiguousUTF8()
    rebase(base: base, ifCurrentRevisionIs: captured.revision)
    return Snapshot(text: text, revision: captured.revision)
  }

  func snapshotAsync(priority: TaskPriority = .utility) async -> Snapshot {
    let captured = capture()
    return await snapshotAsync(from: captured, priority: priority)
  }

  func snapshotAsync(
    from captured: Capture,
    priority: TaskPriority = .utility
  ) async -> Snapshot {
    await Task.detached(priority: priority) { [self] in
      snapshot(from: captured)
    }.value
  }

  private func rebase(base: NSString, ifCurrentRevisionIs revision: Int) {
    lock.withLock {
      guard state.revision == revision else { return }
      state.base = base
      state.additions = []
      state.root = Self.baseNode(length: base.length)
      state.utf16Length = base.length
    }
  }

  private static func baseNode(length: Int) -> Node? {
    guard length > 0 else { return nil }
    return Node(
      piece: Piece(additionIndex: nil, range: NSRange(location: 0, length: length))
    )
  }

  /// Splits a tree at a document-relative UTF-16 offset. Both returned roots
  /// remain balanced, including when the offset bisects a piece.
  private static func split(_ node: Node?, at offset: Int) -> (Node?, Node?) {
    guard let node else { return (nil, nil) }

    let leftLength = node.left?.utf16Length ?? 0
    let pieceEnd = leftLength + node.piece.range.length

    if offset < leftLength {
      let (prefix, leftRemainder) = split(node.left, at: offset)
      return (prefix, join(leftRemainder, node.piece, node.right))
    }

    if offset > pieceEnd {
      let (rightPrefix, suffix) = split(node.right, at: offset - pieceEnd)
      return (join(node.left, node.piece, rightPrefix), suffix)
    }

    if offset == leftLength {
      return (node.left, join(nil, node.piece, node.right))
    }

    if offset == pieceEnd {
      return (join(node.left, node.piece, nil), node.right)
    }

    let prefixLength = offset - leftLength
    let suffixLength = node.piece.range.length - prefixLength
    let prefixPiece = Piece(
      additionIndex: node.piece.additionIndex,
      range: NSRange(location: node.piece.range.location, length: prefixLength)
    )
    let suffixPiece = Piece(
      additionIndex: node.piece.additionIndex,
      range: NSRange(
        location: node.piece.range.location + prefixLength,
        length: suffixLength
      )
    )
    return (
      join(node.left, prefixPiece, nil),
      join(nil, suffixPiece, node.right)
    )
  }

  /// Joins two ordered trees around one piece while preserving AVL balance.
  private static func join(_ left: Node?, _ piece: Piece, _ right: Node?) -> Node {
    let leftHeight = left?.height ?? 0
    let rightHeight = right?.height ?? 0

    if leftHeight > rightHeight + 1, let left {
      let joinedRight = join(left.right, piece, right)
      return balance(Node(piece: left.piece, left: left.left, right: joinedRight))
    }

    if rightHeight > leftHeight + 1, let right {
      let joinedLeft = join(left, piece, right.left)
      return balance(Node(piece: right.piece, left: joinedLeft, right: right.right))
    }

    return Node(piece: piece, left: left, right: right)
  }

  private static func concatenate(_ left: Node?, _ right: Node?) -> Node? {
    guard let left else { return right }
    guard let right else { return left }
    let (firstPiece, remainingRight) = removingFirst(from: right)
    return join(left, firstPiece, remainingRight)
  }

  private static func removingFirst(from node: Node) -> (Piece, Node?) {
    guard let left = node.left else {
      return (node.piece, node.right)
    }
    let (piece, remainingLeft) = removingFirst(from: left)
    return (
      piece,
      balance(Node(piece: node.piece, left: remainingLeft, right: node.right))
    )
  }

  private static func balance(_ node: Node) -> Node {
    let balanceFactor = (node.left?.height ?? 0) - (node.right?.height ?? 0)

    if balanceFactor > 1, let left = node.left {
      if (left.left?.height ?? 0) < (left.right?.height ?? 0) {
        let rotatedLeft = rotateLeft(left)
        return rotateRight(Node(piece: node.piece, left: rotatedLeft, right: node.right))
      }
      return rotateRight(node)
    }

    if balanceFactor < -1, let right = node.right {
      if (right.right?.height ?? 0) < (right.left?.height ?? 0) {
        let rotatedRight = rotateRight(right)
        return rotateLeft(Node(piece: node.piece, left: node.left, right: rotatedRight))
      }
      return rotateLeft(node)
    }

    return node
  }

  private static func rotateLeft(_ node: Node) -> Node {
    guard let pivot = node.right else { return node }
    let moved = Node(piece: node.piece, left: node.left, right: pivot.left)
    return Node(piece: pivot.piece, left: moved, right: pivot.right)
  }

  private static func rotateRight(_ node: Node) -> Node {
    guard let pivot = node.left else { return node }
    let moved = Node(piece: node.piece, left: pivot.right, right: node.right)
    return Node(piece: pivot.piece, left: pivot.left, right: moved)
  }

  private static func forEachPiece(in root: Node?, _ body: (Piece) -> Void) {
    var stack: [Node] = []
    var current = root
    while current != nil || !stack.isEmpty {
      while let node = current {
        stack.append(node)
        current = node.left
      }
      let node = stack.removeLast()
      body(node.piece)
      current = node.right
    }
  }
}

private extension NSLock {
  func withLock<T>(_ body: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try body()
  }
}
